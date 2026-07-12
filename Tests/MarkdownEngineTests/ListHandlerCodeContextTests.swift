//
//  ListHandlerCodeContextTests.swift
//  MarkdownEngine
//
//  Created by Luca Chen on 12.07.26.
//
//  The list handler now gets "is the caret in code?" from the keystroke's
//  parse (codeTokens) instead of a full-document contains("`") + tokenizer
//  scan on every space/Enter/Tab. These pin that list continuation still
//  fires outside code and stays inert inside a fenced block.
//

import AppKit
import SwiftUI
import Testing
@testable import MarkdownEngine

@MainActor
@Suite("List handler code-block context")
struct ListHandlerCodeContextTests {

    private func makeEditor(text: String) -> NativeTextView {
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
        return textView
    }

    @Test func enterContinuesListOutsideCode() {
        let tv = makeEditor(text: "- hello")
        tv.setSelectedRange(NSRange(location: 7, length: 0))

        tv.insertText("\n", replacementRange: NSRange(location: 7, length: 0))

        #expect(tv.string == "- hello\n- ")
    }

    @Test func enterDoesNotContinueListInsideFencedCode() {
        let text = "```\n- hello\n```"
        let tv = makeEditor(text: text)
        tv.setSelectedRange(NSRange(location: 11, length: 0))   // end of "- hello", inside the fence

        tv.insertText("\n", replacementRange: NSRange(location: 11, length: 0))

        #expect(tv.string == "```\n- hello\n\n```")
    }
}
