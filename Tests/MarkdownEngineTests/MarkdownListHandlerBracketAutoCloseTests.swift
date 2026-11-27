//
//  MarkdownListHandlerBracketAutoCloseTests.swift
//  MarkdownEngine
//
//  Both the single-`[` auto-close and the Obsidian-style `[[` node-bracket
//  completion are bracket auto-closing, so both should honor
//  `ListStyle.autoClosePairsEnabled` — an embedder editing plain Markdown
//  source (autoClosePairsEnabled = false) expects `[` to insert exactly `[`.
//

import AppKit
import SwiftUI
import Testing
@testable import MarkdownEngine

@MainActor
@Suite("MarkdownListHandler bracket auto-close")
struct MarkdownListHandlerBracketAutoCloseTests {

    private func makeEditor(text: String, configuration: MarkdownEditorConfiguration = .default) -> NativeTextView {
        _ = NSApplication.shared
        let textView = NativeTextView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        textView.isEditable = true
        textView.configuration = configuration
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

    @Test func singleBracketAutoClosesByDefault() {
        let tv = makeEditor(text: "")
        tv.setSelectedRange(NSRange(location: 0, length: 0))

        tv.insertText("[", replacementRange: NSRange(location: 0, length: 0))

        #expect(tv.string == "[]")
    }

    @Test func obsidianDoubleBracketCompletesByDefault() {
        let tv = makeEditor(text: "[")
        tv.setSelectedRange(NSRange(location: 1, length: 0))

        tv.insertText("[", replacementRange: NSRange(location: 1, length: 0))

        #expect(tv.string == "[[]]")
    }

    @Test func singleBracketInsertsExactlyOneCharWhenAutoCloseDisabled() {
        let config = MarkdownEditorConfiguration(lists: ListStyle(autoClosePairsEnabled: false))
        let tv = makeEditor(text: "", configuration: config)
        tv.setSelectedRange(NSRange(location: 0, length: 0))

        tv.insertText("[", replacementRange: NSRange(location: 0, length: 0))

        #expect(tv.string == "[")
    }

    @Test func obsidianDoubleBracketDoesNotAutoCompleteWhenAutoCloseDisabled() {
        let config = MarkdownEditorConfiguration(lists: ListStyle(autoClosePairsEnabled: false))
        let tv = makeEditor(text: "[", configuration: config)
        tv.setSelectedRange(NSRange(location: 1, length: 0))

        tv.insertText("[", replacementRange: NSRange(location: 1, length: 0))

        #expect(tv.string == "[[")
    }
}
