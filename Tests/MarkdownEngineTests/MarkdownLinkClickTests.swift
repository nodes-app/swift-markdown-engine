//
//  MarkdownLinkClickTests.swift
//  MarkdownEngineTests
//
//  A click on `[text](target)` reaches the embedder with the target as written
//  in the source. The `.link` attribute holds a URL completed with a scheme, so
//  a relative target such as `notes/b.md` is only recoverable from the tokens.
//

import AppKit
import SwiftUI
import Testing
@testable import MarkdownEngine

@MainActor
struct MarkdownLinkClickTests {

    private func makeEditor(_ source: String, isEditable: Bool = false) -> (NativeTextViewCoordinator, NativeTextView) {
        _ = NSApplication.shared

        let coordinator = NativeTextViewCoordinator(
            text: .constant(source), fontName: "SF Pro", fontSize: 16,
            isWikiLinkActive: .constant(false), onLinkClick: nil, onInlineSelectionChange: nil
        )
        let textView = NativeTextView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        textView.isEditable = isEditable
        textView.delegate = coordinator
        coordinator.textView = textView
        coordinator.rebuildTextStorageAndStyle(textView, from: source)
        return (coordinator, textView)
    }

    /// Clicks the character at `needle`'s midpoint and returns what the delegate answered.
    private func click(_ needle: String, in textView: NativeTextView, coordinator: NativeTextViewCoordinator) throws -> Bool {
        let range = (textView.string as NSString).range(of: needle)
        let index = range.location + range.length / 2
        let link = try #require(textView.textStorage?.attribute(.link, at: index, effectiveRange: nil))
        return coordinator.textView(textView, clickedOnLink: link, at: index)
    }

    @Test("A markdown link hands its source target to the embedder",
          arguments: ["notes/b.md", "../b.md", "b.md#heading", "My%20Note.md", "https://example.com/a"])
    func linkTargetReachesEmbedder(target: String) throws {
        let (coordinator, textView) = makeEditor("See [the other note](\(target)) here.\n")
        var clicked: [String] = []
        coordinator.onMarkdownLinkClick = { clicked.append($0); return true }

        #expect(try click("other", in: textView, coordinator: coordinator))
        #expect(clicked == [target])
    }

    @Test("A bare URL hands its address to the embedder")
    func autolinkReachesEmbedder() throws {
        let (coordinator, textView) = makeEditor("See https://example.com/a here.\n")
        var clicked: [String] = []
        coordinator.onMarkdownLinkClick = { clicked.append($0); return true }

        #expect(try click("example", in: textView, coordinator: coordinator))
        #expect(clicked == ["https://example.com/a"])
    }

    @Test("A declined click is left to the system")
    func declinedClickFallsThrough() throws {
        let (coordinator, textView) = makeEditor("See [the other note](notes/b.md) here.\n")
        coordinator.onMarkdownLinkClick = { _ in false }

        #expect(try click("other", in: textView, coordinator: coordinator) == false)
    }

    @Test("Without a handler the system opens the link")
    func noHandlerFallsThrough() throws {
        let (coordinator, textView) = makeEditor("See [the other note](notes/b.md) here.\n")

        #expect(try click("other", in: textView, coordinator: coordinator) == false)
    }

    @Test("The edit zone at a link's edge still places the caret in an editable view")
    func editZoneKeepsCaretPlacement() throws {
        let (coordinator, textView) = makeEditor("See [the other note](notes/b.md) here.\n", isEditable: true)
        var clicked: [String] = []
        coordinator.onMarkdownLinkClick = { clicked.append($0); return true }
        let first = (textView.string as NSString).range(of: "the other note").location
        let link = try #require(textView.textStorage?.attribute(.link, at: first, effectiveRange: nil))

        #expect(coordinator.textView(textView, clickedOnLink: link, at: first))
        #expect(clicked.isEmpty)
        #expect(textView.selectedRange() == NSRange(location: first - 1, length: 0))
    }
}
