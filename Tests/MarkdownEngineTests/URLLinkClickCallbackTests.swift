//
//  URLLinkClickCallbackTests.swift
//  MarkdownEngineTests
//
//  `onLinkClick` already lets embedders route `[[Name]]` clicks through their
//  own model. Regular `[label](href)` clicks used to fall straight through to
//  AppKit's `NSWorkspace.open`, with no seam for an embedder that wanted to
//  route them itself (open the target with the right app, navigate inside its
//  own app, resolve a relative href against a base directory). These tests pin
//  the new `onURLLinkClick` hook: it fires with the URL the styler attached
//  and the label's range, its return value decides whether the click is
//  consumed here or handed back to AppKit, and a wiki-link click still goes
//  through `onLinkClick` — the URL hook is only for Markdown URL links.
//

import AppKit
import SwiftUI
import Testing
@testable import MarkdownEngine

@MainActor
@Suite("onURLLinkClick fires for `[label](href)` clicks")
struct URLLinkClickCallbackTests {

    private func makeEditor(_ text: String) -> (NativeTextViewCoordinator, NativeTextView) {
        _ = NSApplication.shared
        let coordinator = NativeTextViewCoordinator(
            text: .constant(text), fontName: "SF Pro", fontSize: 16,
            isWikiLinkActive: .constant(false),
            onLinkClick: nil,
            onURLLinkClick: nil,
            onInlineSelectionChange: nil
        )
        let tv = NativeTextView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        tv.isEditable = false     // read-only so the click delegate's edit-zone branch stays out of the way
        tv.delegate = coordinator
        coordinator.textView = tv
        coordinator.rebuildTextStorageAndStyle(tv, from: text)
        coordinator.lastSyncedText = text
        return (coordinator, tv)
    }

    /// The range of the `.link` attribute at `location`, or `NSNotFound` when
    /// nothing is styled as a link there.
    private func linkRange(in tv: NSTextView, at location: Int) -> NSRange {
        guard let storage = tv.textStorage else { return NSRange(location: NSNotFound, length: 0) }
        var range = NSRange(location: NSNotFound, length: 0)
        _ = storage.attribute(
            .link, at: location, longestEffectiveRange: &range,
            in: NSRange(location: 0, length: storage.length)
        )
        return range
    }

    @Test("returning true consumes the click and skips AppKit's default handler")
    func handlerReturningTrueConsumesClick() {
        let text = "[docs](https://example.com/docs)"
        let (coordinator, tv) = makeEditor(text)
        var received: (URL, NSRange)?
        coordinator.onURLLinkClick = { url, range in
            received = (url, range)
            return true
        }
        let clickIndex = 1        // inside "docs"
        let label = linkRange(in: tv, at: clickIndex)
        let handled = coordinator.textView(
            tv, clickedOnLink: URL(string: "https://example.com/docs")!, at: clickIndex
        )
        #expect(handled == true)
        #expect(received?.0.absoluteString == "https://example.com/docs")
        #expect(received?.1 == label)
    }

    @Test("returning false hands the click back to AppKit")
    func handlerReturningFalseFallsThrough() {
        let text = "[docs](https://example.com/docs)"
        let (coordinator, tv) = makeEditor(text)
        var fired = false
        coordinator.onURLLinkClick = { _, _ in
            fired = true
            return false
        }
        let handled = coordinator.textView(
            tv, clickedOnLink: URL(string: "https://example.com/docs")!, at: 1
        )
        #expect(fired == true)
        #expect(handled == false)   // AppKit takes it from here
    }

    @Test("no handler leaves the historical AppKit-open behavior intact")
    func noHandlerFallsThrough() {
        let text = "[docs](https://example.com/docs)"
        let (coordinator, tv) = makeEditor(text)
        let handled = coordinator.textView(
            tv, clickedOnLink: URL(string: "https://example.com/docs")!, at: 1
        )
        #expect(handled == false)
    }

    @Test("a wiki-link click ignores onURLLinkClick and goes through onLinkClick")
    func wikiLinkClickBypassesURLHook() async {
        let text = "[[Note]]"
        let (coordinator, tv) = makeEditor(text)
        var urlHookFired = false
        var wikiTarget: String?
        coordinator.onURLLinkClick = { _, _ in urlHookFired = true; return true }
        coordinator.onLinkClick = { wikiTarget = $0 }
        // WikiLinkService.resolveIdentifier trusts the storage's .wikiLink attribute,
        // which the styler wrote to the label range.
        let handled = coordinator.textView(
            tv, clickedOnLink: NSString(string: "Note"), at: 2
        )
        // Wiki-link clicks resolve to true (the coordinator handles them itself).
        #expect(handled == true)
        // Wait one tick for the async dispatch inside the wiki-link branch.
        try? await Task.sleep(nanoseconds: 20_000_000)
        #expect(urlHookFired == false)
        #expect(wikiTarget == "Note")
    }
}
