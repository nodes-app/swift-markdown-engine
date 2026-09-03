//
//  BlockFormattingActionTests.swift
//  MarkdownEngineTests
//

import AppKit
import SwiftUI
import Testing
@testable import MarkdownEngine

@MainActor
@Suite("Paragraph and task-list formatting")
struct BlockFormattingActionTests {
    @Test("Paragraph removes a heading at the caret")
    func paragraphAtCaret() {
        let (coordinator, textView) = makeEditor("# Title\n")
        textView.setSelectedRange(NSRange(location: 3, length: 0))

        coordinator.didMarkdownParagraph(nil)

        #expect(textView.string == "Title\n")
        #expect(textView.selectedRange() == NSRange(location: 1, length: 0))
    }

    @Test("Paragraph changes every selected heading and preserves LF")
    func paragraphMultiline() {
        let source = "# One\n## Two\nPlain\n"
        let (coordinator, textView) = makeEditor(source)
        textView.setSelectedRange(NSRange(location: 0, length: (source as NSString).length))

        coordinator.didMarkdownParagraph(nil)

        let expected = "One\nTwo\nPlain\n"
        #expect(textView.string == expected)
        #expect(textView.selectedRange() == NSRange(location: 0, length: (expected as NSString).length))
    }

    @Test("Paragraph preserves CRLF line endings")
    func paragraphCRLF() {
        let source = "# One\r\n## Two\r\n"
        let (coordinator, textView) = makeEditor(source)
        textView.setSelectedRange(NSRange(location: 0, length: (source as NSString).length))

        coordinator.didMarkdownParagraph(nil)

        #expect(textView.string == "One\r\nTwo\r\n")
    }

    @Test("Task list inserts at an empty caret")
    func taskListAtEmptyCaret() {
        let (coordinator, textView) = makeEditor("")
        textView.setSelectedRange(NSRange(location: 0, length: 0))

        coordinator.didMarkdownTaskList(nil)

        #expect(textView.string == "- [ ] ")
        #expect(textView.selectedRange() == NSRange(location: 6, length: 0))
    }

    @Test("Task list formats every selected line and preserves LF")
    func taskListMultiline() {
        let source = "First\n* Second\n"
        let (coordinator, textView) = makeEditor(source)
        textView.setSelectedRange(NSRange(location: 0, length: (source as NSString).length))

        coordinator.didMarkdownTaskList(nil)

        let expected = "- [ ] First\n* [ ] Second\n"
        #expect(textView.string == expected)
        #expect(textView.selectedRange() == NSRange(location: 6, length: (expected as NSString).length - 6))
    }

    @Test("Task list removes markers when every selected line is a task")
    func taskListTogglesOff() {
        let source = "- [ ] First\n- [x] Second\n"
        let (coordinator, textView) = makeEditor(source)
        textView.setSelectedRange(NSRange(location: 0, length: (source as NSString).length))

        coordinator.didMarkdownTaskList(nil)

        #expect(textView.string == "First\nSecond\n")
    }

    @Test("Task list preserves CRLF line endings")
    func taskListCRLF() {
        let source = "First\r\nSecond\r\n"
        let (coordinator, textView) = makeEditor(source)
        textView.setSelectedRange(NSRange(location: 0, length: (source as NSString).length))

        coordinator.didMarkdownTaskList(nil)

        #expect(textView.string == "- [ ] First\r\n- [ ] Second\r\n")
    }

    @Test("Task list preserves indentation while replacing bullet markers")
    func taskListIndentation() {
        let source = "\t* Nested\n"
        let (coordinator, textView) = makeEditor(source)
        textView.setSelectedRange(NSRange(location: 4, length: 0))

        coordinator.didMarkdownTaskList(nil)

        #expect(textView.string == "\t* [ ] Nested\n")
    }

    @Test("A mixed selection preserves tasks and converts plain and list lines")
    func mixedTaskListSelection() {
        let source = "- [x] Done\nPlain\n* Bullet\n1. Ordered\n"
        let (coordinator, textView) = makeEditor(source)
        textView.setSelectedRange(NSRange(location: 0, length: (source as NSString).length))

        coordinator.didMarkdownTaskList(nil)

        #expect(textView.string == "- [x] Done\n- [ ] Plain\n* [ ] Bullet\n1. [ ] Ordered\n")
    }

    @Test(
        "Existing unordered and ordered task markers toggle off cleanly",
        arguments: ["* [x] Item", "+ [ ] Item", "2. [X] Item"]
    )
    func existingTaskMarker(source: String) {
        let (coordinator, textView) = makeEditor(source)
        textView.setSelectedRange(NSRange(location: 0, length: 0))

        coordinator.didMarkdownTaskList(nil)

        #expect(textView.string == "Item")
    }

    @Test("Bus notifications invoke both formatting actions")
    func busNotifications() {
        let paragraph = Notification.Name("test.paragraph.\(UUID().uuidString)")
        let taskList = Notification.Name("test.task.\(UUID().uuidString)")
        let (coordinator, textView) = makeEditor("# Item")
        var configuration = MarkdownEditorConfiguration.default
        configuration.services.bus = MarkdownEditorBus(
            applyParagraphRequest: paragraph,
            applyTaskListRequest: taskList
        )
        coordinator.configuration = configuration
        textView.setSelectedRange(NSRange(location: 2, length: 0))

        NotificationCenter.default.post(name: paragraph, object: nil)
        NotificationCenter.default.post(name: taskList, object: nil)

        #expect(textView.string == "- [ ] Item")
    }

    @Test("Paragraph preserves wiki-link storage metadata in the settled binding")
    func paragraphPreservesStorageLink() async {
        let result = await settledStorageText("## Intro [[Target|ABC-123]]\n") { coordinator, textView in
            textView.setSelectedRange(NSRange(location: 3, length: 0))
            coordinator.didMarkdownParagraph(nil)
        }

        #expect(result == "Intro [[Target|ABC-123]]\n")
    }

    @Test("Task list preserves wiki-link storage metadata in the settled binding")
    func taskListPreservesStorageLink() async {
        let result = await settledStorageText("Intro [[Target|ABC-123]]\n") { coordinator, textView in
            textView.setSelectedRange(NSRange(location: 2, length: 0))
            coordinator.didMarkdownTaskList(nil)
        }

        #expect(result == "- [ ] Intro [[Target|ABC-123]]\n")
    }

    private func makeEditor(_ text: String) -> (NativeTextViewCoordinator, NativeTextView) {
        _ = NSApplication.shared
        let textView = NativeTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        textView.isEditable = true
        textView.string = text
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
        return (coordinator, textView)
    }

    private func settledStorageText(
        _ storage: String,
        action: (NativeTextViewCoordinator, NativeTextView) -> Void
    ) async -> String {
        var published = storage
        let binding = Binding<String>(get: { published }, set: { published = $0 })
        let coordinator = NativeTextViewCoordinator(
            text: binding,
            fontName: "SF Pro Text",
            fontSize: 14,
            isWikiLinkActive: .constant(false),
            onLinkClick: nil,
            onInlineSelectionChange: nil
        )
        let textView = NativeTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        textView.delegate = coordinator
        coordinator.textView = textView
        coordinator.rebuildTextStorageAndStyle(textView, from: storage)

        action(coordinator, textView)
        for _ in 0..<4 {
            await withCheckedContinuation { continuation in
                DispatchQueue.main.async { continuation.resume() }
            }
        }
        return published
    }
}
