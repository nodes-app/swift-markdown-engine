//
//  SpanInkCursorTests.swift
//  MarkdownEngineTests
//
//  Created by Luca Chen on 26.11.26.
//
//  Which runs get the recolored I-beam: only an inverted extension span. A code
//  block also carries a background (the highlighter's) and ink of its own (token
//  colors, the clear fence), and the I-beam recolored there turned see-through.
//

import AppKit
import SwiftUI
import Testing
@testable import MarkdownEngine

/// Inverted like Nodes' `==highlight==`: a line-box block plus its own ink.
private struct InvertedBlockHighlight: MarkdownExtension {
    static let ink = NSColor.white
    static let block = NSColor.black
    var id: String { HighlightExtension.identifier }
    var inline: InlineSyntax? { InlineSyntax(open: "==", close: "==") }
    func contentAttributes(theme: MarkdownEditorTheme) -> [NSAttributedString.Key: Any] {
        [.markdownBlockBackground: Self.block, .foregroundColor: Self.ink]
    }
    func html(childrenHTML: String) -> String { "<mark>\(childrenHTML)</mark>" }
}

/// Every token red on an opaque code background.
private struct RedTokens: SyntaxHighlighter {
    func codeFont(size: CGFloat) -> NSFont { .monospacedSystemFont(ofSize: size, weight: .regular) }
    func backgroundColor() -> NSColor { NSColor(white: 0.9, alpha: 1) }
    func highlight(code: String, language: String?) -> NSAttributedString? {
        NSAttributedString(string: code, attributes: [.foregroundColor: NSColor.systemRed])
    }
    var appearanceDidChangeNotification: Notification.Name? { nil }
}

@MainActor
@Suite("Recolored I-beam only over inverted spans")
struct SpanInkCursorTests {

    // "plain ==marked== tail": `marked` is {8, 6}. The fence opens at 23, `x` is at 36.
    private static let text = "plain ==marked== tail\n\n```swift\nlet x = 1\n```\n"
    private static let marked = 10
    private static let fence = 24
    private static let token = 36

    /// The coordinator and window are returned too: nothing else keeps them alive.
    private func makeEditor() -> (NativeTextViewCoordinator, NativeTextView, NSWindow) {
        _ = NSApplication.shared
        let coordinator = NativeTextViewCoordinator(
            text: .constant(Self.text), fontName: "SF Pro", fontSize: 16,
            isWikiLinkActive: .constant(false), onLinkClick: nil, onInlineSelectionChange: nil
        )
        var configuration = coordinator.configuration
        configuration.extensions = [InvertedBlockHighlight()]
        configuration.services = MarkdownEditorServices(syntaxHighlighter: RedTokens())
        configuration.cursorFollowsSpanInk = true
        coordinator.configuration = configuration
        let tv = NativeTextView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        tv.configuration = configuration
        tv.isEditable = true
        tv.delegate = coordinator
        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        scrollView.documentView = tv
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
            styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.contentView = scrollView
        coordinator.textView = tv
        coordinator.rebuildTextStorageAndStyle(tv, from: Self.text)
        tv.layoutSubtreeIfNeeded()
        return (coordinator, tv, window)
    }

    /// A mouse move over the middle of the character at `index`.
    private func hover(_ index: Int, in tv: NativeTextView, _ window: NSWindow) throws -> NSEvent {
        let screen = tv.firstRect(forCharacterRange: NSRange(location: index, length: 1), actualRange: nil)
        let point = window.convertPoint(fromScreen: NSPoint(x: screen.midX, y: screen.midY))
        return try #require(NSEvent.mouseEvent(
            with: .mouseMoved, location: point, modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 0, pressure: 0))
    }

    @Test("a syntax-colored code token keeps the system I-beam")
    func codeTokenKeepsSystemIBeam() throws {
        let (coordinator, tv, window) = makeEditor()
        defer { _ = (coordinator, window) }
        let ink = tv.textStorage?.attribute(.foregroundColor, at: Self.token, effectiveRange: nil) as? NSColor
        try #require(ink == .systemRed)            // the stub highlighter really colored it

        #expect(tv.invertedRunColors(at: try hover(Self.token, in: tv, window)) == nil)
    }

    @Test("the hidden fence keeps the system I-beam")
    func hiddenFenceKeepsSystemIBeam() throws {
        let (coordinator, tv, window) = makeEditor()
        defer { _ = (coordinator, window) }

        #expect(tv.invertedRunColors(at: try hover(Self.fence, in: tv, window)) == nil)
    }

    @Test("an inverted highlight's block gets its own ink")
    func invertedHighlightGetsItsInk() throws {
        let (coordinator, tv, window) = makeEditor()
        defer { _ = (coordinator, window) }

        let colors = try #require(tv.invertedRunColors(at: try hover(Self.marked, in: tv, window)))
        #expect(colors.ink == InvertedBlockHighlight.ink.usingColorSpace(.deviceRGB))
        #expect(colors.block == InvertedBlockHighlight.block.usingColorSpace(.deviceRGB))
    }
}
