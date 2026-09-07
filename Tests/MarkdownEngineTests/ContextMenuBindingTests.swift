#if os(macOS)
//
//  ContextMenuBindingTests.swift
//  MarkdownEngineTests
//
//  Created by Luca Chen on 25.07.26.
//
//  A formatting action must leave the binding in STORAGE form — `[[Name|UUID]]`
//  and `[[Name]]` render identically, so the loss was only ever visible in the
//  file afterwards.
//
//  These assert on what SETTLES after draining the main queue, not on the first
//  write: the bug was one async write landing after another, so a synchronous
//  assertion passes against the broken code too.
//

import AppKit
import SwiftUI
import Testing
@testable import MarkdownEngine

private extension NSMenuItem {
    /// `didMarkdownHeading` reads the level off the sender's tag.
    static func headingLevel(_ level: Int) -> NSMenuItem {
        let item = NSMenuItem()
        item.tag = level
        return item
    }
}

@MainActor
struct ContextMenuBindingTests {

    private static let storage = "Intro [[Target Note|ABC-123]] and more text.\n"

    /// Let every `DispatchQueue.main.async` enqueued during the action run.
    private func drainMainQueue() async {
        for _ in 0..<4 {
            await withCheckedContinuation { continuation in
                DispatchQueue.main.async { continuation.resume() }
            }
        }
    }

    private func makeEditor(text: Binding<String>) -> (NativeTextViewCoordinator, NativeTextView) {
        // `textViewDidChangeSelection` reads `NSApp.currentEvent`, and `NSApp` is
        // an implicitly-unwrapped global that stays nil until the shared
        // application exists. In a hosted app it always does; in a test process
        // it does not until touched, and the selection change these actions cause
        // would trap. Not a product concern — a harness one.
        _ = NSApplication.shared

        let coordinator = NativeTextViewCoordinator(
            text: text, fontName: "SF Pro", fontSize: 16,
            isWikiLinkActive: .constant(false), onLinkClick: nil, onInlineSelectionChange: nil
        )
        let textView = NativeTextView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        textView.delegate = coordinator
        coordinator.textView = textView
        coordinator.rebuildTextStorageAndStyle(textView, from: Self.storage)
        return (coordinator, textView)
    }

    /// Runs `action` against a fresh editor and returns the settled binding.
    private func settledText(after action: (NativeTextViewCoordinator) -> Void) async -> String {
        var published = Self.storage
        let binding = Binding<String>(get: { published }, set: { published = $0 })
        let (coordinator, textView) = makeEditor(text: binding)

        // Caret inside the prose, clear of the link, so the action takes the
        // caret-only path — the one that was broken.
        textView.setSelectedRange(NSRange(location: 2, length: 0))
        action(coordinator)
        await drainMainQueue()
        return published
    }

    @Test("Blockquote keeps the wiki link's UUID in the binding")
    func blockquotePreservesLinkID() async {
        let result = await settledText { $0.didMarkdownBlockquote(nil) }

        #expect(result.contains("[[Target Note|ABC-123]]"))
        #expect(!result.contains("[[Target Note]]"))
        #expect(result.contains(">")) // the action did happen
    }

    @Test("Heading keeps the wiki link's UUID in the binding")
    func headingPreservesLinkID() async {
        let result = await settledText { $0.didMarkdownHeading(NSMenuItem.headingLevel(2)) }
        #expect(result.contains("[[Target Note|ABC-123]]"))
    }

    @Test("Unordered list keeps the wiki link's UUID in the binding")
    func unorderedListPreservesLinkID() async {
        let result = await settledText { $0.didMarkdownUnorderedList(nil) }
        #expect(result.contains("[[Target Note|ABC-123]]"))
    }

    /// Selection wrapping replaces the whole selected range — the same
    /// mechanism as the line handlers, reached differently.
    @Test("Bold over a selection containing the link keeps its UUID")
    func boldOverLinkPreservesLinkID() async {
        var published = Self.storage
        let binding = Binding<String>(get: { published }, set: { published = $0 })
        let (coordinator, textView) = makeEditor(text: binding)

        // Select from before the link to past it, in DISPLAY coordinates.
        let display = textView.string as NSString
        let linkRange = display.range(of: "[[Target Note]]")
        #expect(linkRange.location != NSNotFound)
        textView.setSelectedRange(NSRange(location: linkRange.location, length: linkRange.length))

        coordinator.didMarkdownBold(nil)
        await drainMainQueue()

        #expect(published.contains("Target Note|ABC-123"))
    }

    /// The display-form write also skipped `lastSyncedText`, which made the
    /// loss permanent for the session.
    @Test("The coordinator's sync base stays in storage form after an action")
    func syncBaseStaysStorageForm() async {
        var published = Self.storage
        let binding = Binding<String>(get: { published }, set: { published = $0 })
        let (coordinator, textView) = makeEditor(text: binding)
        textView.setSelectedRange(NSRange(location: 2, length: 0))

        coordinator.didMarkdownBlockquote(nil)
        await drainMainQueue()

        #expect(coordinator.lastSyncedText.contains("[[Target Note|ABC-123]]"))
        #expect(coordinator.lastSyncedText == published)
    }
}
#endif
