#if os(macOS)
//
//  CaretColorTests.swift
//  MarkdownEngineTests
//
//  Created by Luca Chen on 30.07.26.
//
//  The caret takes the ink of the extension span it sits in — otherwise a span
//  that inverts (dark ink on a light block) draws the caret in the block's own
//  color and it disappears.
//

import AppKit
import SwiftUI
import Testing
@testable import MarkdownEngine

/// `==text==` painted as an inverted block, like the Nodes app registers.
private struct InvertingHighlight: MarkdownExtension {
    var id: String { HighlightExtension.identifier }
    var inline: InlineSyntax? { InlineSyntax(open: "==", close: "==") }
    func contentAttributes(theme: MarkdownEditorTheme) -> [NSAttributedString.Key: Any] {
        [.backgroundColor: NSColor.white, .foregroundColor: NSColor.black]
    }
    func html(childrenHTML: String) -> String { "<mark>\(childrenHTML)</mark>" }
}

@MainActor
@Suite("Caret color follows the span's ink")
struct CaretColorTests {

    private func makeEditor(
        _ text: String,
        extensions: [any MarkdownExtension],
        followsInk: Bool = true
    ) -> (NativeTextViewCoordinator, NativeTextView) {
        _ = NSApplication.shared
        let coordinator = NativeTextViewCoordinator(
            text: .constant(text), fontName: "SF Pro", fontSize: 16,
            isWikiLinkActive: .constant(false), onLinkClick: nil, onInlineSelectionChange: nil
        )
        coordinator.configuration.extensions = extensions
        coordinator.configuration.cursorFollowsSpanInk = followsInk
        let tv = NativeTextView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        tv.isEditable = true
        tv.delegate = coordinator
        coordinator.textView = tv
        coordinator.rebuildTextStorageAndStyle(tv, from: text)
        coordinator.lastSyncedText = text
        coordinator.lastComputedStorage = text
        coordinator.previousDisplayLength = (text as NSString).length
        return (coordinator, tv)
    }

    // "plain ==marked== tail": content `marked` is {8, 6}, markers {6,2} and {14,2}.
    private static let text = "plain ==marked== tail"

    @Test("caret inside the span takes the span's ink, and gives it back on the way out")
    func caretInsideSpanInvertsAndRestores() {
        let (coordinator, tv) = makeEditor(Self.text, extensions: [InvertingHighlight()])
        let body = coordinator.configuration.theme.bodyText

        tv.setSelectedRange(NSRange(location: 11, length: 0))   // middle of `marked`
        #expect(tv.insertionPointColor == NSColor.black)

        tv.setSelectedRange(NSRange(location: 2, length: 0))    // back in plain text
        #expect(tv.insertionPointColor == body)
    }

    @Test("the markers themselves keep the body ink — the block starts at the content")
    func caretOnMarkersKeepsBodyInk() {
        let (coordinator, tv) = makeEditor(Self.text, extensions: [InvertingHighlight()])
        let body = coordinator.configuration.theme.bodyText

        tv.setSelectedRange(NSRange(location: 7, length: 0))    // between the two `=`
        #expect(tv.insertionPointColor == body)

        tv.setSelectedRange(NSRange(location: 19, length: 0))   // in `tail`
        #expect(tv.insertionPointColor == body)
    }

    /// The whole behavior is off unless the embedder asks for it — an inverting
    /// extension alone must not change any other app's caret.
    @Test("off by default, even with an inverting extension registered")
    func doesNothingWithoutTheOptIn() {
        let (coordinator, tv) = makeEditor(Self.text, extensions: [InvertingHighlight()], followsInk: false)

        tv.setSelectedRange(NSRange(location: 11, length: 0))

        #expect(tv.insertionPointColor == coordinator.configuration.theme.bodyText)
        #expect(coordinator.resolvedCaretColor == coordinator.configuration.theme.bodyText)
    }

    /// The engine's own highlight paints a background only, so nothing changes
    /// for embedders that didn't ask for inverted ink.
    @Test("an extension that paints no foreground leaves the caret alone")
    func plainHighlightLeavesCaretAtBodyInk() {
        let (coordinator, tv) = makeEditor(Self.text, extensions: [HighlightExtension()])

        tv.setSelectedRange(NSRange(location: 11, length: 0))

        #expect(tv.insertionPointColor == coordinator.configuration.theme.bodyText)
    }

    /// `updateNSView` used to reset the caret to `theme.bodyText` on every
    /// SwiftUI pass, which stomped the inverted ink a moment after it was set.
    @Test("the resolved ink survives a view update")
    func resolvedInkSurvivesViewUpdate() {
        let (coordinator, tv) = makeEditor(Self.text, extensions: [InvertingHighlight()])

        tv.setSelectedRange(NSRange(location: 11, length: 0))
        #expect(coordinator.resolvedCaretColor == NSColor.black)

        // What updateNSView re-applies (see NativeTextViewWrapper).
        tv.insertionPointColor = coordinator.resolvedCaretColor ?? coordinator.configuration.theme.bodyText
        #expect(tv.insertionPointColor == NSColor.black)
    }
}
#endif
