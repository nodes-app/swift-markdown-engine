//
//  ReadOnlyTaskCheckboxTests.swift
//  MarkdownEngineTests
//

import AppKit
import SwiftUI
import Testing
@testable import MarkdownEngine

@MainActor
@Suite("Read-only task checkbox interaction")
struct ReadOnlyTaskCheckboxTests {
    @Test("The public wrapper defaults read-only checkbox interaction to off")
    func wrapperDefaultIsOff() {
        let wrapper = NativeTextViewWrapper(text: .constant(""))

        #expect(wrapper.allowsTaskCheckboxInteractionWhenReadOnly == false)
    }

    @Test("The opt-in click toggles the binding while ordinary edits stay blocked")
    func optInClickTogglesWithoutEnablingEditing() async throws {
        let source = "- [ ] Item\r\nPlain\r\n"
        let fixture = try makeFixture(
            source,
            checkboxRange: NSRange(location: 2, length: 3),
            allowsReadOnlyToggle: true
        )

        #expect(fixture.textView.isEditable == false)
        #expect(fixture.textView.shouldChangeText(
            in: NSRange(location: 6, length: 0),
            replacementString: "X"
        ) == false)

        #expect(fixture.textView.toggleTaskCheckboxIfHit(event: fixture.click) == true)
        await settleBinding()

        #expect(fixture.textView.string == "- [x] Item\r\nPlain\r\n")
        #expect(fixture.published() == "- [x] Item\r\nPlain\r\n")
    }

    @Test("Read-only checkboxes remain inert by default")
    func defaultReadOnlyClickIsInert() throws {
        let source = "- [ ] Item\n"
        let fixture = try makeFixture(
            source,
            checkboxRange: NSRange(location: 2, length: 3),
            allowsReadOnlyToggle: false
        )

        #expect(fixture.textView.toggleTaskCheckboxIfHit(event: fixture.click) == true)
        #expect(fixture.textView.string == source)
        #expect(fixture.published() == source)
    }

    @Test(
        "Clicking the second checkbox changes only its source range",
        arguments: ["\n", "\r\n"]
    )
    func secondCheckboxChangesOnlyItsRange(lineEnding: String) async throws {
        let source = "- [ ] First\(lineEnding)- [ ] Second\(lineEnding)Plain\(lineEnding)"
        let range = try secondCheckboxRange(in: source)
        let fixture = try makeFixture(
            source,
            checkboxRange: range,
            allowsReadOnlyToggle: true
        )

        #expect(fixture.textView.toggleTaskCheckboxIfHit(event: fixture.click) == true)
        await settleBinding()

        let expected = "- [ ] First\(lineEnding)- [x] Second\(lineEnding)Plain\(lineEnding)"
        #expect(fixture.textView.string == expected)
        #expect(fixture.published() == expected)
    }

    @Test("The click reports the exact three-character text mutation")
    func reportsExactMutation() async throws {
        let source = "- [ ] First\n- [ ] Second\n"
        let range = try secondCheckboxRange(in: source)
        var mutations: [MarkdownTextMutation] = []
        let fixture = try makeFixture(
            source,
            checkboxRange: range,
            allowsReadOnlyToggle: true,
            onTextMutation: { mutations.append($0) }
        )

        #expect(fixture.textView.toggleTaskCheckboxIfHit(event: fixture.click) == true)
        await settleBinding()

        #expect(mutations.count == 1)
        #expect(mutations.first?.range == range)
        #expect(mutations.first?.replacement == "[x]")
    }

    @Test("A read-only checkbox toggle participates in undo and redo")
    func supportsUndoAndRedo() async throws {
        let source = "- [ ] Item\r\n"
        let fixture = try makeFixture(
            source,
            checkboxRange: NSRange(location: 2, length: 3),
            allowsReadOnlyToggle: true
        )

        #expect(fixture.textView.toggleTaskCheckboxIfHit(event: fixture.click) == true)
        await settleBinding()
        #expect(fixture.textView.string == "- [x] Item\r\n")

        let undoManager = try #require(fixture.coordinator.undoManager(for: fixture.textView))
        #expect(undoManager.canUndo)
        undoManager.undo()
        await settleBinding()
        #expect(fixture.textView.string == source)
        #expect(fixture.published() == source)

        #expect(undoManager.canRedo)
        undoManager.redo()
        await settleBinding()
        #expect(fixture.textView.string == "- [x] Item\r\n")
        #expect(fixture.published() == "- [x] Item\r\n")
        #expect(fixture.textView.isEditable == false)
    }

    private func makeFixture(
        _ source: String,
        checkboxRange: NSRange,
        allowsReadOnlyToggle: Bool,
        onTextMutation: ((MarkdownTextMutation) -> Void)? = nil
    ) throws -> (
        textView: NativeTextView,
        click: NSEvent,
        published: () -> String,
        coordinator: NativeTextViewCoordinator,
        window: NSWindow
    ) {
        _ = NSApplication.shared
        var published = source
        let coordinator = NativeTextViewCoordinator(
            text: Binding(get: { published }, set: { published = $0 }),
            fontName: NSFont.systemFont(ofSize: 14).fontName,
            fontSize: 14,
            isWikiLinkActive: .constant(false),
            onLinkClick: nil,
            onInlineSelectionChange: nil
        )
        coordinator.onTextMutation = onTextMutation
        let textView = NativeTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 200),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = textView
        textView.frame = window.contentView?.bounds ?? .zero
        textView.baseFont = .systemFont(ofSize: 14)
        textView.font = textView.baseFont
        textView.textContainerInset = NSSize(width: 40, height: 20)
        textView.isEditable = false
        textView.isSelectable = true
        textView.allowsUndo = true
        textView.allowsTaskCheckboxInteractionWhenReadOnly = allowsReadOnlyToggle
        textView.delegate = coordinator
        coordinator.textView = textView
        coordinator.rebuildTextStorageAndStyle(textView, from: source)

        guard let textContainer = textView.textContainer,
              let layoutManager = textView.textLayoutManager else {
            throw FixtureError.missingTextKitStack
        }
        let bridge = LayoutBridge(layoutManager)
        textView.layoutBridge = bridge
        coordinator.layoutBridge = bridge
        layoutManager.ensureLayout(for: layoutManager.documentRange)
        let anchor = bridge.boundingRect(forCharacterRange: checkboxRange, in: textContainer)
        let size = TaskCheckboxGeometry.size(for: textView.baseFont)
        let containerPoint = CGPoint(
            x: TaskCheckboxGeometry.boxX(contentX: anchor.minX, size: size) + size / 2,
            y: anchor.midY
        )
        let viewPoint = CGPoint(
            x: containerPoint.x + textView.textContainerOrigin.x,
            y: containerPoint.y + textView.textContainerOrigin.y
        )
        let windowPoint = textView.convert(viewPoint, to: nil)
        guard let click = NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: windowPoint,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 1,
            clickCount: 1,
            pressure: 1
        ) else {
            throw FixtureError.missingMouseEvent
        }

        return (textView, click, { published }, coordinator, window)
    }

    private func secondCheckboxRange(in source: String) throws -> NSRange {
        let text = source as NSString
        let first = text.range(of: "[ ]")
        guard first.location != NSNotFound else { throw FixtureError.missingCheckbox }
        let remainder = NSRange(location: NSMaxRange(first), length: text.length - NSMaxRange(first))
        let second = text.range(of: "[ ]", options: [], range: remainder)
        guard second.location != NSNotFound else { throw FixtureError.missingCheckbox }
        return second
    }

    private func settleBinding() async {
        for _ in 0..<4 {
            await withCheckedContinuation { continuation in
                DispatchQueue.main.async { continuation.resume() }
            }
        }
    }

    private enum FixtureError: Error {
        case missingTextKitStack
        case missingMouseEvent
        case missingCheckbox
    }
}
