//
//  CaretVisibilityTests.swift
//  MarkdownEngineTests
//
//  Keyboard selection changes must keep the caret inside the editor's
//  visible viewport when TextKit 2 owns layout.
//

import AppKit
import Testing
@testable import MarkdownEngine

@MainActor
@Suite("Caret visibility")
struct CaretVisibilityTests {
    private struct Stack {
        let scrollView: ClampedScrollView
        let container: NativeTextViewContainer
        let textView: NativeTextView
        let window: NSWindow
        let layoutBridge: LayoutBridge
    }

    private func makeStack() throws -> Stack {
        _ = NSApplication.shared
        let viewport = NSSize(width: 320, height: 120)
        let scrollView = ClampedScrollView(frame: NSRect(origin: .zero, size: viewport))
        scrollView.hasVerticalScroller = true

        let textView = NativeTextView(frame: .zero)
        var configuration = MarkdownEditorConfiguration.default
        configuration.heightBehavior = .scrolls
        textView.configuration = configuration
        textView.font = NSFont.systemFont(ofSize: 16)
        textView.baseFont = textView.font ?? NSFont.systemFont(ofSize: 16)
        textView.isEditable = true
        textView.isSelectable = true
        textView.isVerticallyResizable = true
        textView.maxSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.autoresizingMask = []
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.heightTracksTextView = false

        let text = (0..<40).map { "Line \($0)" }.joined(separator: "\n")
        textView.string = text
        let textLayoutManager = try #require(textView.textLayoutManager)
        let layoutBridge = LayoutBridge(textLayoutManager)
        textView.layoutBridge = layoutBridge
        textLayoutManager.ensureLayout(for: textLayoutManager.documentRange)

        let container = NativeTextViewContainer(frame: NSRect(origin: .zero, size: viewport))
        container.autoresizingMask = [.width]
        container.textView = textView
        textView.frame = NSRect(x: 0, y: 0, width: viewport.width, height: 0)
        container.addSubview(textView)
        scrollView.documentView = container
        textView.recalcOverscroll(for: scrollView)

        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: viewport),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = scrollView
        window.layoutIfNeeded()
        return Stack(
            scrollView: scrollView,
            container: container,
            textView: textView,
            window: window,
            layoutBridge: layoutBridge
        )
    }

    @Test("an off-screen caret scrolls into view in full-width mode")
    func offscreenCaretScrollsIntoView() throws {
        let stack = try makeStack()
        defer { stack.window.contentView = nil }
        let end = (stack.textView.string as NSString).length
        let caret = NSRange(location: end, length: 0)

        #expect(stack.container.scrollableContentHeight > stack.scrollView.contentView.bounds.height)
        #expect(stack.scrollView.contentView.bounds.origin.y <= 0)

        stack.textView.setSelectedRange(caret)
        stack.textView.scrollRangeToVisible(caret)

        #expect(stack.scrollView.contentView.bounds.origin.y > 0)
    }

    @Test("arrow-key movement keeps the caret inside the viewport")
    func arrowKeyMovementKeepsCaretVisible() throws {
        let stack = try makeStack()
        defer { stack.window.contentView = nil }
        stack.textView.setSelectedRange(NSRange(location: 0, length: 0))
        stack.window.makeFirstResponder(stack.textView)

        for _ in 0..<20 {
            stack.textView.moveDown(nil)
        }

        #expect(stack.textView.selectedRange().location > 0)
        #expect(stack.scrollView.contentView.bounds.origin.y > 0)
    }
}
