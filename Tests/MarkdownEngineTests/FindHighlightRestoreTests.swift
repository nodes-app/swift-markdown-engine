//
//  FindHighlightRestoreTests.swift
//  MarkdownEngineTests
//
//  Created by Luca Chen on 31.07.26.
//
//  Find paints with `.backgroundColor`, and so do extension spans, code fences
//  and table cells. Clearing find's highlights used to remove the attribute
//  document-wide, which erased their block until something else restyled.
//

import AppKit
import SwiftUI
import Testing
@testable import MarkdownEngine

/// `==text==` painted as an inverted block, like the Nodes app registers.
private struct InvertingHighlight: MarkdownExtension {
    var id: String { HighlightExtension.identifier }
    var inline: InlineSyntax? { InlineSyntax(open: "==", close: "==") }
    func contentAttributes(theme: MarkdownEditorTheme) -> [NSAttributedString.Key: Any] {
        [.backgroundColor: NSColor.white, .foregroundColor: NSColor.black]
    }
    func html(childrenHTML: String) -> String { "<mark>\(childrenHTML)</mark>" }
}

@MainActor
@Suite("Find highlights give the block back when they clear")
struct FindHighlightRestoreTests {

    // "plain ==marked== tail": content `marked` is {8, 6}, `tail` is {17, 4}.
    private static let text = "plain ==marked== tail"
    private static let blockContent = NSRange(location: 8, length: 6)

    /// The window is returned, not just built: find ignores an editor that is in no
    /// window (a torn-down one must not answer for the visible document), and
    /// nothing else here would keep the window alive.
    private func makeEditor(_ text: String) -> (NativeTextViewCoordinator, NativeTextView, NSWindow) {
        _ = NSApplication.shared
        let coordinator = NativeTextViewCoordinator(
            text: .constant(text), fontName: "SF Pro", fontSize: 16,
            isWikiLinkActive: .constant(false), onLinkClick: nil, onInlineSelectionChange: nil
        )
        coordinator.configuration.extensions = [InvertingHighlight()]
        let tv = NativeTextView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        tv.isEditable = true
        tv.delegate = coordinator
        // The find path scrolls the current match into view; give it a real
        // scroll view so it takes the TextKit 2 route instead of the TextKit 1
        // fallback, which has no layout manager to route through here.
        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        scrollView.documentView = tv
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
            styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.contentView = scrollView
        coordinator.textView = tv
        coordinator.rebuildTextStorageAndStyle(tv, from: text)
        coordinator.lastSyncedText = text
        coordinator.lastComputedStorage = text
        coordinator.previousDisplayLength = (text as NSString).length
        return (coordinator, tv, window)
    }

    private func background(_ tv: NativeTextView, at location: Int) -> NSColor? {
        tv.textStorage?.attribute(.backgroundColor, at: location, effectiveRange: nil) as? NSColor
    }

    private func find(_ query: String, _ coordinator: NativeTextViewCoordinator) {
        coordinator.handleFindQuery(Notification(
            name: Notification.Name("findQuery"),
            object: nil,
            userInfo: ["query": query, "currentIndex": 0]
        ))
    }

    private func done(_ coordinator: NativeTextViewCoordinator) {
        coordinator.handleFindClearHighlights(
            Notification(name: Notification.Name("findClearHighlights"), object: nil)
        )
    }

    @Test("searching the highlighted word and dismissing leaves the block painted")
    func blockReturnsAfterClearingItsOwnMatch() {
        let (coordinator, tv, window) = makeEditor(Self.text)
        defer { window.contentView = nil }
        #expect(background(tv, at: Self.blockContent.location) == NSColor.white)

        find("marked", coordinator)
        #expect(background(tv, at: Self.blockContent.location) != NSColor.white)

        done(coordinator)
        // No click, no selection change: the block is back on its own.
        #expect(background(tv, at: Self.blockContent.location) == NSColor.white)
    }

    @Test("a match somewhere else never touches the block")
    func blockSurvivesAMatchElsewhere() {
        let (coordinator, tv, window) = makeEditor(Self.text)
        defer { window.contentView = nil }

        find("tail", coordinator)
        #expect(background(tv, at: Self.blockContent.location) == NSColor.white)

        done(coordinator)
        #expect(background(tv, at: Self.blockContent.location) == NSColor.white)
        #expect(background(tv, at: 17) == nil)
    }

    /// The query is broadcast to every live coordinator, and an editor the host has
    /// routed away from can outlive its view. It answers for a document nobody is
    /// looking at — with an empty buffer, so it reports zero matches and the host
    /// resets its match index. Measured in the app: 24 coordinators replying to one
    /// ⌘F, 22 of them windowless, and next/previous stuck bouncing between the first
    /// two matches.
    @Test("an editor that is in no window stays out of the search")
    func windowlessEditorIgnoresTheQuery() {
        let (coordinator, tv, window) = makeEditor(Self.text)
        window.contentView = nil

        find("tail", coordinator)

        #expect(background(tv, at: 17) == nil)
    }

    @Test("re-running the query drops the previous highlight instead of stacking")
    func repeatedQueriesLeaveNoResidue() {
        let (coordinator, tv, window) = makeEditor(Self.text)
        defer { window.contentView = nil }

        find("marked", coordinator)
        find("tail", coordinator)

        #expect(background(tv, at: Self.blockContent.location) == NSColor.white)
        #expect(background(tv, at: 17) != nil)
    }
}
