//
//  ListHandlerCodeContextTests.swift
//  MarkdownEngine
//
//  Created by Luca Chen on 12.07.26.
//
//  Characterization for the smart-input list handler's code-block awareness:
//  list continuation / Tab indent / "->" substitution must stay inert inside
//  fenced code, and fence completion must close an unmatched ``` opener.
//  Locks the behavior across the O(doc)-scan removal (the handler used to
//  re-derive "am I in code?" via a full-document contains("`") + tokenizer
//  pass on EVERY space/Enter/Tab).
//

import AppKit
import SwiftUI
import Testing
@testable import MarkdownEngine

@MainActor
@Suite("List handler code-block context")
struct ListHandlerCodeContextTests {

    /// Editor wired like production: coordinator as delegate, sync state seeded.
    private func makeEditor(text: String) -> (NativeTextView, NativeTextViewCoordinator) {
        _ = NSApplication.shared
        let textView = NativeTextView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        textView.isEditable = true
        textView.configuration = .default
        let coordinator = NativeTextViewCoordinator(
            text: .constant(text),
            fontName: "SF Pro Text",
            fontSize: 14,
            isWikiLinkActive: .constant(false),
            onLinkClick: nil,
            onInlineSelectionChange: nil
        )
        coordinator.textView = textView
        textView.delegate = coordinator
        textView.string = text
        coordinator.lastSyncedText = text
        coordinator.lastComputedStorage = text
        coordinator.previousDisplayLength = (text as NSString).length
        return (textView, coordinator)
    }

    @Test func enterContinuesListOutsideCode() {
        let (tv, _) = makeEditor(text: "- hello")
        tv.setSelectedRange(NSRange(location: 7, length: 0))

        tv.insertText("\n", replacementRange: NSRange(location: 7, length: 0))

        #expect(tv.string == "- hello\n- ")
    }

    @Test func enterDoesNotContinueListInsideFencedCode() {
        let text = "```\n- hello\n```"
        let (tv, _) = makeEditor(text: text)
        // Caret at the end of "- hello" (inside the fence).
        tv.setSelectedRange(NSRange(location: 11, length: 0))

        tv.insertText("\n", replacementRange: NSRange(location: 11, length: 0))

        #expect(tv.string == "```\n- hello\n\n```")
    }

    @Test func tabIndentsListItemOutsideCode() {
        let (tv, _) = makeEditor(text: "- hello")
        tv.setSelectedRange(NSRange(location: 7, length: 0))

        tv.insertText("\t", replacementRange: NSRange(location: 7, length: 0))

        #expect(tv.string == "\t- hello")
    }

    @Test func tabStaysLiteralInsideFencedCode() {
        let text = "```\n- hello\n```"
        let (tv, _) = makeEditor(text: text)
        tv.setSelectedRange(NSRange(location: 11, length: 0))

        tv.insertText("\t", replacementRange: NSRange(location: 11, length: 0))

        #expect(tv.string == "```\n- hello\t\n```")
    }

    @Test func arrowSubstitutionStaysLiteralInsideFencedCode() {
        let text = "```\nabc - def\n```"
        let (tv, _) = makeEditor(text: text)
        // Right after the "-" inside the fence.
        tv.setSelectedRange(NSRange(location: 9, length: 0))

        tv.insertText(">", replacementRange: NSRange(location: 9, length: 0))

        #expect(tv.string == "```\nabc -> def\n```")
    }

    @Test func enterAtUnmatchedFenceOpenerInsertsClosingFence() {
        let (tv, _) = makeEditor(text: "```swift")
        tv.setSelectedRange(NSRange(location: 8, length: 0))

        tv.insertText("\n", replacementRange: NSRange(location: 8, length: 0))

        #expect(tv.string == "```swift\n\n```")
    }

    @Test func enterAtClosingFenceJustBreaksLine() {
        // Caret at the end of the CLOSING fence: one ``` precedes the line
        // (odd → it's a closer, not an opener), so no completion fires and
        // the newline stays literal.
        let text = "```\ncode\n```"
        let (tv, _) = makeEditor(text: text)
        let end = (text as NSString).length
        tv.setSelectedRange(NSRange(location: end, length: 0))

        tv.insertText("\n", replacementRange: NSRange(location: end, length: 0))

        #expect(tv.string == "```\ncode\n```\n")
    }
}
