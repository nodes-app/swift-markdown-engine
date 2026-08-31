//
//  InlineBoxCaretTests.swift
//  MarkdownEngineTests
//
//  A box (`InlineSyntax.inlineBoxWidth`) behaves as one thing: the caret steps
//  over it, a selection takes all of it or none, delete removes it whole, and
//  its laid-out rect is the box the pointer can be tested against.
//

import AppKit
import Testing
@testable import MarkdownEngine

@MainActor
@Suite("Inline box caret")
struct InlineBoxCaretTests {

    private let boxWidth: CGFloat = 20
    private let document = "- Ship it [t=12.0-15.5] tomorrow"

    private struct BoxExtension: MarkdownExtension {
        var width: CGFloat
        var id: String { "box" }
        var inline: InlineSyntax? {
            InlineSyntax(open: "[t=", close: "]", parsesContent: false, inlineBoxWidth: width)
        }

        func contentAttributes(theme _: MarkdownEditorTheme) -> [NSAttributedString.Key: Any] { [:] }
        func html(childrenHTML _: String) -> String { "" }
    }

    /// Same syntax laid out as text, to show the caret rules are the box's and
    /// not the extension's.
    private struct PlainExtension: MarkdownExtension {
        var id: String { "box" }
        var inline: InlineSyntax? {
            InlineSyntax(open: "[t=", close: "]", parsesContent: false)
        }

        func contentAttributes(theme _: MarkdownEditorTheme) -> [NSAttributedString.Key: Any] { [:] }
        func html(childrenHTML _: String) -> String { "" }
    }

    /// Span of `[t=12.0-15.5]`, which is what the styler boxes.
    private var box: NSRange {
        let ns = document as NSString
        let start = ns.range(of: "[t=").location
        let end = NSMaxRange(ns.range(of: "]"))
        return NSRange(location: start, length: end - start)
    }

    /// Holds the editor's collaborators for the length of a test. The text view
    /// keeps the coordinator and the layout bridge weakly, exactly as it does in
    /// the app, where the wrapper owns both.
    private final class Editor {
        let textView: NativeTextView
        let coordinator: NativeTextViewCoordinator
        let bridge: LayoutBridge?

        init(textView: NativeTextView, coordinator: NativeTextViewCoordinator, bridge: LayoutBridge?) {
            self.textView = textView
            self.coordinator = coordinator
            self.bridge = bridge
        }
    }

    /// A text view carrying the styled document, applied the way the
    /// coordinator applies it (flattened runs, one `setAttributes` per run).
    private func makeEditor(boxed: Bool = true) -> Editor {
        _ = NSApplication.shared
        let textView = NativeTextView(frame: NSRect(x: 0, y: 0, width: 600, height: 200))
        textView.isEditable = true
        var configuration = MarkdownEditorConfiguration.default
        configuration.extensions = boxed ? [BoxExtension(width: boxWidth)] : [PlainExtension()]
        textView.configuration = configuration
        let coordinator = NativeTextViewCoordinator(
            text: .constant(document),
            fontName: "SF Pro Text",
            fontSize: 14,
            isWikiLinkActive: .constant(false),
            onLinkClick: nil,
            onInlineSelectionChange: nil
        )
        coordinator.configuration = configuration
        coordinator.textView = textView
        textView.delegate = coordinator
        textView.string = document
        coordinator.lastSyncedText = document
        coordinator.lastComputedStorage = document
        coordinator.previousDisplayLength = (document as NSString).length
        let bridge = textView.textLayoutManager.map(LayoutBridge.init)
        coordinator.layoutBridge = bridge
        textView.layoutBridge = bridge

        let font = NSFont(name: "SF Pro Text", size: 14) ?? .systemFont(ofSize: 14)
        let full = NSRange(location: 0, length: (document as NSString).length)
        let ranges = MarkdownStyler.styleAttributes(
            text: document,
            fontName: font.fontName,
            fontSize: 14,
            caretLocation: -1,
            activeTokenIndices: [],
            configuration: configuration
        )
        let runs = MarkdownStyler.flattenedRuns(ranges, base: [.font: font], documentLength: full.length)
        textView.textStorage?.beginEditing()
        for (range, attributes) in runs {
            textView.textStorage?.setAttributes(attributes, range: range)
        }
        textView.textStorage?.endEditing()
        return Editor(textView: textView, coordinator: coordinator, bridge: bridge)
    }

    // MARK: - Stepping

    @Test("the right arrow steps from in front of the box to behind it")
    func rightArrowStepsOverTheBox() {
        let editor = makeEditor()
        let textView = editor.textView
        textView.setSelectedRange(NSRange(location: box.location, length: 0))
        textView.moveRight(nil)
        #expect(textView.selectedRange() == NSRange(location: NSMaxRange(box), length: 0))
    }

    @Test("the left arrow steps from behind the box to in front of it")
    func leftArrowStepsBackOverTheBox() {
        let editor = makeEditor()
        let textView = editor.textView
        textView.setSelectedRange(NSRange(location: NSMaxRange(box), length: 0))
        textView.moveLeft(nil)
        #expect(textView.selectedRange() == NSRange(location: box.location, length: 0))
    }

    @Test("stepping into the box from either side never rests inside it")
    func steppingNeverRestsInside() {
        let editor = makeEditor()
        let textView = editor.textView
        for start in [box.location - 1, NSMaxRange(box) + 1] {
            textView.setSelectedRange(NSRange(location: start, length: 0))
            textView.moveRight(nil)
            #expect(InlineBoxCaret.box(strictlyContaining: textView.selectedRange().location,
                                       in: textView.textStorage!) == nil)
            textView.moveLeft(nil)
            #expect(InlineBoxCaret.box(strictlyContaining: textView.selectedRange().location,
                                       in: textView.textStorage!) == nil)
        }
    }

    /// A click has no direction to continue in, so it takes the edge it landed
    /// nearest — jumping to the far side would move the caret away from the tap.
    @Test("a caret dropped inside the box takes the nearer edge")
    func droppedCaretTakesTheNearerEdge() {
        let editor = makeEditor()
        let textView = editor.textView
        textView.setSelectedRange(NSRange(location: 0, length: 0))
        textView.setSelectedRange(NSRange(location: box.location + 2, length: 0))
        #expect(textView.selectedRange() == NSRange(location: box.location, length: 0))

        textView.setSelectedRange(NSRange(location: 0, length: 0))
        textView.setSelectedRange(NSRange(location: NSMaxRange(box) - 2, length: 0))
        #expect(textView.selectedRange() == NSRange(location: NSMaxRange(box), length: 0))
    }

    // MARK: - Selection

    @Test("extending the selection into the box takes all of it")
    func shiftArrowSelectsTheWholeBox() {
        let editor = makeEditor()
        let textView = editor.textView
        textView.setSelectedRange(NSRange(location: box.location, length: 0))
        textView.moveRightAndModifySelection(nil)
        #expect(textView.selectedRange() == box)
    }

    @Test("a selection ending inside the box grows to cover it")
    func selectionNeverCarriesHalfABox() {
        let editor = makeEditor()
        let textView = editor.textView
        let from = 2
        textView.setSelectedRange(NSRange(location: from, length: box.location + 3 - from))
        let selection = textView.selectedRange()
        #expect(selection == NSRange(location: from, length: NSMaxRange(box) - from))
    }

    // MARK: - Delete

    @Test("backspace behind the box removes the whole box")
    func backspaceRemovesTheWholeBox() {
        let editor = makeEditor()
        let textView = editor.textView
        textView.setSelectedRange(NSRange(location: NSMaxRange(box), length: 0))
        #expect(InlineBoxCaret.handleDeleteBackward(textView: textView))
        #expect(textView.string == "- Ship it  tomorrow")
        #expect(textView.selectedRange() == NSRange(location: box.location, length: 0))
    }

    @Test("forward delete in front of the box removes the whole box")
    func forwardDeleteRemovesTheWholeBox() {
        let editor = makeEditor()
        let textView = editor.textView
        textView.setSelectedRange(NSRange(location: box.location, length: 0))
        #expect(InlineBoxCaret.handleDeleteForward(textView: textView))
        #expect(textView.string == "- Ship it  tomorrow")
    }

    @Test("delete away from a box is left to AppKit")
    func deleteElsewhereIsInert() {
        let editor = makeEditor()
        let textView = editor.textView
        textView.setSelectedRange(NSRange(location: 5, length: 0))
        #expect(!InlineBoxCaret.handleDeleteBackward(textView: textView))
        #expect(!InlineBoxCaret.handleDeleteForward(textView: textView))
        #expect(textView.string == document)
    }

    // MARK: - Without a box

    @Test("the same span laid out as text keeps ordinary caret and delete")
    func plainSpanIsUntouched() {
        let editor = makeEditor(boxed: false)
        let textView = editor.textView
        textView.setSelectedRange(NSRange(location: box.location, length: 0))
        textView.moveRight(nil)
        #expect(textView.selectedRange() == NSRange(location: box.location + 1, length: 0))

        textView.setSelectedRange(NSRange(location: NSMaxRange(box), length: 0))
        #expect(!InlineBoxCaret.handleDeleteBackward(textView: textView))
    }

    // MARK: - Pointer

    /// What the pointer is tested against: the span's laid-out rect has to BE
    /// the box, or the hand cursor and the embedder's control would disagree
    /// about where the box is.
    @Test("the box's laid-out rect is the reserved width")
    func laidOutRectIsTheBox() {
        let editor = makeEditor()
        let rect = boxRect(in: editor)
        #expect(abs(rect.width - boxWidth) < 0.5)
        #expect(rect.height > 0)
    }

    /// The whole box answers to the pointer, not just the middle of it: the
    /// control the embedder draws fills the reserved space edge to edge.
    @Test("every point of the box reads as a control, and no point beside it does")
    func theWholeBoxIsTheTarget() {
        let editor = makeEditor()
        let rect = boxRect(in: editor)
        let inset: CGFloat = 0.5
        for x in [rect.minX + inset, rect.midX, rect.maxX - inset] {
            let point = viewPoint(x: x, y: rect.midY, in: editor.textView)
            #expect(editor.textView.isOverInlineBox(atViewPoint: point), "x=\(x) is inside the box")
        }
        for x in [rect.minX - 3, rect.maxX + 3] {
            let point = viewPoint(x: x, y: rect.midY, in: editor.textView)
            #expect(!editor.textView.isOverInlineBox(atViewPoint: point), "x=\(x) is beside the box")
        }
    }

    /// The same span as text is text: the pointer keeps the I-beam over it.
    @Test("a span without a box is never a pointer target")
    func plainSpanIsNotATarget() {
        let editor = makeEditor(boxed: false)
        let rect = boxRect(in: editor)
        let point = viewPoint(x: rect.midX, y: rect.midY, in: editor.textView)
        #expect(!editor.textView.isOverInlineBox(atViewPoint: point))
    }

    /// Laid-out rect of the span, in text-container coordinates.
    private func boxRect(in editor: Editor) -> CGRect {
        guard let container = editor.textView.textContainer,
              let bridge = editor.bridge,
              let layoutManager = editor.textView.textLayoutManager
        else {
            Issue.record("the editor has no TextKit 2 layout")
            return .zero
        }
        layoutManager.ensureLayout(for: layoutManager.documentRange)
        return bridge.boundingRect(forCharacterRange: box, in: container)
    }

    private func viewPoint(x: CGFloat, y: CGFloat, in textView: NativeTextView) -> CGPoint {
        CGPoint(x: x + textView.textContainerOrigin.x, y: y + textView.textContainerOrigin.y)
    }
}
