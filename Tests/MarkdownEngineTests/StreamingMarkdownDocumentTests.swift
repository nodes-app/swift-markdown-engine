import AppKit
import Foundation
import SwiftUI
import Testing
@testable import MarkdownEngine

@Suite("Streaming Markdown document")
struct StreamingMarkdownDocumentTests {
    @Test func firstUpdateResetsThenLaterUpdatesAppendOnlyTheTail() {
        let document = StreamingMarkdownDocument()

        #expect(document.update(documentID: "answer", text: "Hello") == .reset("Hello"))
        #expect(document.update(documentID: "answer", text: "Hello **wor") == .append(" **wor"))
        #expect(document.update(documentID: "answer", text: "Hello **world**") == .append("ld**"))
    }

    @Test func unchangedTextDoesNoWork() {
        let document = StreamingMarkdownDocument()
        _ = document.update(documentID: "answer", text: "Hello")

        #expect(document.update(documentID: "answer", text: "Hello") == .none)
    }

    @Test func replacementAndDocumentSwitchReset() {
        let document = StreamingMarkdownDocument()
        _ = document.update(documentID: "answer", text: "Long answer")

        #expect(document.update(documentID: "answer", text: "Short") == .reset("Short"))
        #expect(document.update(documentID: "other", text: "Other") == .reset("Other"))
    }

    @Test func utf16TailExtractionHandlesEmoji() {
        let document = StreamingMarkdownDocument()
        _ = document.update(documentID: "answer", text: "Hi 👋")

        #expect(document.update(documentID: "answer", text: "Hi 👋 world") == .append(" world"))
    }

    @Test func finishStartsAnewStreamingDocument() {
        let document = StreamingMarkdownDocument()
        _ = document.update(documentID: "answer", text: "First")
        document.finish()

        #expect(document.update(documentID: "answer", text: "Second") == .reset("Second"))
    }
}

@MainActor
@Suite("Streaming Markdown rendering")
struct StreamingMarkdownRenderingTests {
    private func makeStack() -> (
        coordinator: NativeTextViewCoordinator,
        scrollView: ClampedScrollView,
        textView: NativeTextView
    ) {
        let coordinator = NativeTextViewCoordinator(
            text: .constant(""),
            fontName: "SF Pro",
            fontSize: 16,
            isWikiLinkActive: .constant(false),
            onLinkClick: nil,
            onInlineSelectionChange: nil
        )
        let stack = HeightBehaviorStack(heightBehavior: .fitsContent)
        coordinator.configuration = stack.textView.configuration
        coordinator.textView = stack.textView
        stack.textView.delegate = coordinator
        return (coordinator, stack.scrollView, stack.textView)
    }

    @Test func streamingAppendLeavesMarkdownUnparsedUntilFinalRebuild() {
        let stack = makeStack()
        let first = "# Answer\n\n**hel"
        let complete = "# Answer\n\n**hello**"

        stack.coordinator.updateStreamingDocument(
            stack.textView,
            in: stack.scrollView,
            documentID: "answer",
            text: first,
            forceReset: false
        )
        stack.coordinator.updateStreamingDocument(
            stack.textView,
            in: stack.scrollView,
            documentID: "answer",
            text: complete,
            forceReset: false
        )

        #expect(stack.textView.string == complete)
        #expect(stack.coordinator.cachedParsedDocument == nil)
        #expect(stack.coordinator.activeTokenIndices.isEmpty)
        let streamedFont = stack.textView.textStorage?.attribute(
            .font,
            at: 0,
            effectiveRange: nil
        ) as? NSFont
        #expect(streamedFont?.pointSize == 16)

        stack.coordinator.streamingDocument.finish()
        stack.coordinator.rebuildTextStorageAndStyle(stack.textView, from: complete)

        let parsed = stack.coordinator.parsedDocument(for: stack.textView.string)
        #expect(parsed.tokens.contains { $0.kind == .heading })
        #expect(parsed.tokens.contains { $0.kind == .bold })
    }

    @Test func appendPreservesExistingAttributedPrefix() {
        let stack = makeStack()
        stack.coordinator.updateStreamingDocument(
            stack.textView,
            in: stack.scrollView,
            documentID: "answer",
            text: "prefix",
            forceReset: false
        )
        stack.textView.textStorage?.addAttribute(
            .backgroundColor,
            value: NSColor.systemPink,
            range: NSRange(location: 0, length: 6)
        )

        stack.coordinator.updateStreamingDocument(
            stack.textView,
            in: stack.scrollView,
            documentID: "answer",
            text: "prefix tail",
            forceReset: false
        )

        #expect(
            stack.textView.textStorage?.attribute(
                .backgroundColor,
                at: 0,
                effectiveRange: nil
            ) as? NSColor == NSColor.systemPink
        )
        #expect(
            stack.textView.textStorage?.attribute(
                .backgroundColor,
                at: 7,
                effectiveRange: nil
            ) == nil
        )
    }
}
