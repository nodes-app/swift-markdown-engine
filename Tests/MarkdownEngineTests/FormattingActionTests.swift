//
//  FormattingActionTests.swift
//  MarkdownEngineTests
//
//  Headless tests for formatting actions wired through the coordinator.
//

import AppKit
import Testing
@testable import MarkdownEngine
import SwiftUI

@MainActor
@Suite("Formatting actions")
struct FormattingActionTests {

    /// Sets up a NativeTextView + Coordinator, sets initial text
    /// and selection, then runs the action closure and returns
    /// the resulting text view for assertion.
    private func apply(
        initialText: String,
        selection: NSRange,
        action: (NativeTextViewCoordinator) -> Void
    ) -> NativeTextView {
        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        let textView = NativeTextView(frame: scrollView.contentView.bounds)
        textView.minSize = .zero
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        textView.isEditable = true
        // Formatting toggles resolve ==/~~ spans via extension tokens, so the
        // test editor registers both extensions (like a real embedder would).
        var config = MarkdownEditorConfiguration.default
        config.extensions = [HighlightExtension(), StrikethroughExtension()]
        textView.configuration = config
        let coordinator = NativeTextViewCoordinator(
            text: .constant(""),
            fontName: "SF Pro Text",
            fontSize: 14,
            isWikiLinkActive: .constant(false),
            onLinkClick: nil,
            onInlineSelectionChange: nil
        )
        coordinator.textView = textView
        coordinator.configuration = config
        textView.string = initialText
        textView.setSelectedRange(selection)
        action(coordinator)
        return textView
    }

    // MARK: - Bold

    @Test func boldWrapsSelection() {
        let tv = apply(initialText: "hello world", selection: NSRange(location: 0, length: 5)) {
            $0.didMarkdownBold(nil)
        }
        #expect(tv.string == "**hello** world")
        #expect(tv.selectedRange() == NSRange(location: 2, length: 5))
    }

    @Test func boldWrapsWord() {
        let tv = apply(initialText: "hello world", selection: NSRange(location: 1, length: 0)) {
            $0.didMarkdownBold(nil)
        }
        #expect(tv.string == "**hello** world")
    }

    @Test func boldPreservesCursorOffset() {
        let tv = apply(initialText: "hello world", selection: NSRange(location: 2, length: 0)) {
            $0.didMarkdownBold(nil)
        }
        #expect(tv.string == "**hello** world")
        #expect(tv.selectedRange().location == 4)
    }

    @Test func boldInsertsEmptyMarkers() {
        let tv = apply(initialText: "hello  world", selection: NSRange(location: 6, length: 0)) {
            $0.didMarkdownBold(nil)
        }
        #expect(tv.string == "hello **** world")
        #expect(tv.selectedRange().location == 8)
    }

    @Test func boldTogglesOff() {
        let tv = apply(initialText: "aa **bb** cc", selection: NSRange(location: 5, length: 2)) {
            $0.didMarkdownBold(nil)
        }
        #expect(tv.string == "aa bb cc")
    }

    @Test func boldTogglesOffByCursor() {
        let tv = apply(initialText: "aa **bold** cc", selection: NSRange(location: 7, length: 0)) {
            $0.didMarkdownBold(nil)
        }
        #expect(tv.string == "aa bold cc")
        #expect(tv.selectedRange().location == 3)
    }

    @Test func boldItalicTogglesToItalic() {
        let tv = apply(initialText: "***both***", selection: NSRange(location: 4, length: 4)) {
            $0.didMarkdownBold(nil)
        }
        #expect(tv.string == "*both*")
    }

    // MARK: - Strikethrough

    @Test func strikethroughWrapsSelection() {
        let tv = apply(initialText: "hello world", selection: NSRange(location: 6, length: 5)) {
            $0.didMarkdownStrikethrough(nil)
        }
        #expect(tv.string == "hello ~~world~~")
        #expect(tv.selectedRange() == NSRange(location: 8, length: 5))
    }

    @Test func strikethroughWrapsWord() {
        let tv = apply(initialText: "hello world", selection: NSRange(location: 7, length: 0)) {
            $0.didMarkdownStrikethrough(nil)
        }
        #expect(tv.string == "hello ~~world~~")
    }

    @Test func strikethroughTogglesOff() {
        let tv = apply(initialText: "~~text~~", selection: NSRange(location: 3, length: 4)) {
            $0.didMarkdownStrikethrough(nil)
        }
        #expect(tv.string == "text")
    }

    // MARK: - Inline code

    @Test func inlineCodeWrapsSelection() {
        let tv = apply(initialText: "var x = 1", selection: NSRange(location: 4, length: 5)) {
            $0.didMarkdownInlineCode(nil)
        }
        #expect(tv.string == "var `x = 1`")
    }

    @Test func inlineCodeTogglesOff() {
        let tv = apply(initialText: "call `fn()` here", selection: NSRange(location: 6, length: 4)) {
            $0.didMarkdownInlineCode(nil)
        }
        #expect(tv.string == "call fn() here")
    }

    // MARK: - Blockquote

    @Test func blockquoteAddsPrefix() {
        let tv = apply(initialText: "a quote line\n", selection: NSRange(location: 3, length: 0)) {
            $0.didMarkdownBlockquote(nil)
        }
        #expect(tv.string == "> a quote line\n")
    }

    @Test func blockquoteRemovesPrefix() {
        let tv = apply(initialText: "> a quote\n", selection: NSRange(location: 4, length: 0)) {
            $0.didMarkdownBlockquote(nil)
        }
        #expect(tv.string == "a quote\n")
    }

    // MARK: - Link

    @Test func linkWrapsSelection() {
        let tv = apply(initialText: "click here", selection: NSRange(location: 0, length: 5)) { coord in
            let note = Notification(name: .init("test"), userInfo: ["url": "https://example.com"])
            coord.didMarkdownLink(note)
        }
        #expect(tv.string == "[click](https://example.com) here")
    }

    @Test func linkInsertsEmptyBrackets() {
        let tv = apply(initialText: "text", selection: NSRange(location: 4, length: 0)) { coord in
            let note = Notification(name: .init("test"), userInfo: ["url": "https://a.b"])
            coord.didMarkdownLink(note)
        }
        #expect(tv.string == "text[](https://a.b)")
        #expect(tv.selectedRange().location == 5)
    }

    // MARK: - Code block

    @Test func codeBlockInsertsAtEnd() {
        let tv = apply(initialText: "a b", selection: NSRange(location: 1, length: 0)) {
            $0.didMarkdownCodeBlock(nil)
        }
        #expect(tv.string == "a\n```\n\n```\n b")
        #expect(tv.selectedRange().location == 6)
    }

    @Test func codeBlockInsertsMidText() {
        let tv = apply(initialText: "before after", selection: NSRange(location: 6, length: 0)) {
            $0.didMarkdownCodeBlock(nil)
        }
        #expect(tv.string == "before\n```\n\n```\n after")
    }

    // MARK: - Horizontal rule

    @Test func horizontalRuleAtEnd() {
        let tv = apply(initialText: "line\n", selection: NSRange(location: 5, length: 0)) {
            $0.didMarkdownHorizontalRule(nil)
        }
        #expect(tv.string == "line\n---\n")
    }

    @Test func horizontalRuleMidText() {
        let tv = apply(initialText: "a b", selection: NSRange(location: 1, length: 0)) {
            $0.didMarkdownHorizontalRule(nil)
        }
        #expect(tv.string == "a\n---\n b")
    }

    // MARK: - Image

    @Test func imageInserts() {
        let tv = apply(initialText: "text", selection: NSRange(location: 4, length: 0)) { coord in
            let note = Notification(name: .init("test"), userInfo: ["url": "img.png"])
            coord.didMarkdownImage(note)
        }
        #expect(tv.string == "text![](img.png)")
    }
}
