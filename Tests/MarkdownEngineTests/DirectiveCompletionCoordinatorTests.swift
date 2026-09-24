//
//  DirectiveCompletionCoordinatorTests.swift
//  MarkdownEngineTests
//
//  `DirectiveCompletionScanner` has no code-span or fenced-block knowledge at
//  all — it answers purely from the characters around the caret. Every gate
//  that keeps a picker from popping inside code, on a selection, outside
//  typing, mid-IME composition, or in raw source mode lives one level up, in
//  `NativeTextViewCoordinator.updateDirectiveCompletion`. These exercise that
//  gate directly, the way the PR description already claimed was tested.
//

import AppKit
import SwiftUI
import Testing
@testable import MarkdownEngine

@MainActor
@Suite("Directive completion — coordinator gates")
struct DirectiveCompletionCoordinatorTests {

    private func makeEditor() -> (NativeTextViewCoordinator, NativeTextView) {
        _ = NSApplication.shared   // selection path reads NSApp.currentEvent
        let coordinator = NativeTextViewCoordinator(
            text: .constant(""), fontName: "SF Pro Text", fontSize: 14,
            isWikiLinkActive: .constant(false), onLinkClick: nil, onInlineSelectionChange: nil
        )
        var configuration = MarkdownEditorConfiguration.default
        configuration.directives = [FontDirective()]
        coordinator.configuration = configuration
        let textView = NativeTextView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        textView.isEditable = true
        textView.configuration = .default
        textView.delegate = coordinator
        coordinator.textView = textView
        return (coordinator, textView)
    }

    /// Baseline: a partial name at the caret, typing, no selection, not in
    /// code, not raw — proves the setup would otherwise open a picker, so
    /// each gate test below is disproving something real.
    @Test("the baseline case opens a picker")
    func baselineOpens() {
        let (coord, tv) = makeEditor()
        tv.string = "hello @fo"
        tv.setSelectedRange(NSRange(location: 9, length: 0))
        coord.updateDirectiveCompletion(tv, text: tv.string as NSString, codeTokens: [], isTyping: true)
        #expect(coord.isDirectiveCompletionActive)
    }

    @Test("a caret inside a fenced code block does not open a picker")
    func fencedCodeBlockGates() {
        let (coord, tv) = makeEditor()
        let text = "```\n@fo\n```\n"
        tv.string = text
        let parsed = coord.parsedDocument(for: text)
        let caret = (text as NSString).range(of: "@fo").location + 3   // after "@fo"
        #expect(MarkdownDetection.isInsideCodeBlock(location: caret, codeTokens: parsed.codeTokens))

        // The scanner alone, with no code awareness, WOULD offer a context
        // for this exact text and caret — proving the gate is doing the work.
        #expect(DirectiveCompletionScanner.context(
            in: text as NSString, caret: caret,
            registry: coord.cachedExtensionRegistry.directives,
            directives: coord.configuration.directives,
            settings: coord.configuration.directiveSettings
        ) != nil)

        tv.setSelectedRange(NSRange(location: caret, length: 0))
        coord.updateDirectiveCompletion(tv, text: text as NSString, codeTokens: parsed.codeTokens, isTyping: true)
        #expect(!coord.isDirectiveCompletionActive)
    }

    @Test("an inline code span does not open a picker")
    func inlineCodeSpanGates() {
        let (coord, tv) = makeEditor()
        let text = "prose `@fo` more"
        tv.string = text
        let parsed = coord.parsedDocument(for: text)
        let caret = (text as NSString).range(of: "@fo").location + 3

        tv.setSelectedRange(NSRange(location: caret, length: 0))
        coord.updateDirectiveCompletion(tv, text: text as NSString, codeTokens: parsed.codeTokens, isTyping: true)
        #expect(!coord.isDirectiveCompletionActive)
    }

    @Test("a non-empty selection does not open a picker")
    func selectionGates() {
        let (coord, tv) = makeEditor()
        tv.string = "hello @fo"
        tv.setSelectedRange(NSRange(location: 6, length: 3))   // selecting "@fo"
        coord.updateDirectiveCompletion(tv, text: tv.string as NSString, codeTokens: [], isTyping: true)
        #expect(!coord.isDirectiveCompletionActive)
    }

    @Test("not typing does not open a picker")
    func notTypingGates() {
        let (coord, tv) = makeEditor()
        tv.string = "hello @fo"
        tv.setSelectedRange(NSRange(location: 9, length: 0))
        coord.updateDirectiveCompletion(tv, text: tv.string as NSString, codeTokens: [], isTyping: false)
        #expect(!coord.isDirectiveCompletionActive)
    }

    @Test("mid-IME composition does not open a picker")
    func imeCompositionGates() {
        let (coord, tv) = makeEditor()
        tv.string = "hello @fo"
        tv.setSelectedRange(NSRange(location: 9, length: 0))
        tv.setMarkedText("x", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: 9, length: 0))
        #expect(tv.hasMarkedText())

        coord.updateDirectiveCompletion(tv, text: tv.string as NSString, codeTokens: [], isTyping: true)
        #expect(!coord.isDirectiveCompletionActive)
    }

    @Test("a wiki-link context suppresses the directive picker")
    func suppressedBySiblingPicker() {
        let (coord, tv) = makeEditor()
        tv.string = "hello @fo"
        tv.setSelectedRange(NSRange(location: 9, length: 0))
        // `suppressed: true` is what the coordinator passes whenever a
        // wiki-link/image-embed context already claims this caret this
        // pass — two pickers must never go live at once for the same key.
        coord.updateDirectiveCompletion(tv, text: tv.string as NSString, codeTokens: [], isTyping: true, suppressed: true)
        #expect(!coord.isDirectiveCompletionActive)
    }

    @Test("raw source mode does not open a picker")
    func rawSourceModeGates() {
        let (coord, tv) = makeEditor()
        coord.configuration.rawSourceMode = true
        tv.string = "hello @fo"
        tv.setSelectedRange(NSRange(location: 9, length: 0))
        coord.updateDirectiveCompletion(tv, text: tv.string as NSString, codeTokens: [], isTyping: true)
        #expect(!coord.isDirectiveCompletionActive)
    }
}
