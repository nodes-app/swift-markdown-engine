#if os(macOS)
//
//  RebuildSelectionReplayTests.swift
//  MarkdownEngineTests
//
//  Created by Luca Chen on 26.07.26.
//
//  A document rebuild suppresses the re-entrant textViewDidChangeSelection
//  (isRebuildingDocument) that `textView.string =` and the styled-string transfer
//  fire synchronously. These prove the rebuild still leaves the selection-derived
//  state that suppressed handler used to produce: the spell/grammar toggles for the
//  loaded caret, and the previous* bookkeeping the next selection change diffs
//  against.
//

import AppKit
import SwiftUI
import Testing
@testable import MarkdownEngine

@MainActor
@Suite("Rebuild replays selection-derived state")
struct RebuildSelectionReplayTests {

    private func makeEditor() -> (NativeTextViewCoordinator, NativeTextView) {
        _ = NSApplication.shared   // selection path reads NSApp.currentEvent
        let coordinator = NativeTextViewCoordinator(
            text: .constant(""), fontName: "SF Pro Text", fontSize: 14,
            isWikiLinkActive: .constant(false), onLinkClick: nil, onInlineSelectionChange: nil
        )
        let textView = NativeTextView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        textView.isEditable = true
        textView.configuration = .default
        textView.delegate = coordinator
        coordinator.textView = textView
        return (coordinator, textView)
    }

    // After a rebuild the previous* fields must describe the LOADED document, not the
    // one open before — the first real selection change diffs against them, and a
    // stale caret mis-scopes its restyle. Poisoned here as a prior document would.
    @Test func rebuildSeedsSelectionBookkeeping() {
        let (coord, tv) = makeEditor()
        coord.previousCaretLocation = 9_999
        coord.previousSelectedRange = NSRange(location: 9_999, length: 42)
        coord.previousActiveTokenIndices = [7, 8, 9]

        coord.rebuildTextStorageAndStyle(tv, from: "Hello **world** and `code`.\n")

        #expect(coord.isRebuildingDocument == false)   // defer cleared it
        #expect(coord.previousCaretLocation == tv.selectedRange().location)
        #expect(coord.previousSelectedRange == tv.selectedRange())
        #expect(coord.previousActiveTokenIndices == coord.activeTokenIndices)
    }

    // updateAutocorrectSettings is the one side effect nothing else runs after a
    // rebuild; the replay must apply the toggles for the loaded caret. Starting the
    // cache at nil proves the call ran — it only early-returns when the cache already
    // matches the decision. Expectations derive from the handler's own logic against
    // the actual final caret, so this tracks the replay's inputs exactly.
    @Test func rebuildAppliesAutocorrectForLoadedCaret() {
        let (coord, tv) = makeEditor()
        coord.cachedSpellingDisabled = nil

        coord.rebuildTextStorageAndStyle(tv, from: "```\nlet x = 1\n```\nprose here\n")

        let caret = tv.selectedRange().location
        let parsed = coord.parsedDocument(for: tv.string)
        let inCode = MarkdownDetection.isInsideCodeBlock(location: caret, codeTokens: parsed.codeTokens)
        let inLatex = MarkdownDetection.isInsideLatex(location: caret, latexTokens: parsed.latexTokens)
        let inLink = parsed.tokens.contains {
            ($0.kind == .wikiLink || $0.kind == .link || $0.kind == .imageEmbed)
                && NSLocationInRange(caret, $0.range)
        }
        let expectedDisabled = inCode || inLatex || inLink

        #expect(coord.cachedSpellingDisabled == expectedDisabled)   // the replay ran
        #expect(tv.isContinuousSpellCheckingEnabled
                == (expectedDisabled ? false : coord.userPrefersContinuousSpellChecking))
        #expect(tv.isAutomaticQuoteSubstitutionEnabled == !expectedDisabled)
    }

    // The guard is scoped to the rebuild only — a genuine caret move afterwards must
    // still run the full handler (here: disabling spelling inside a code block).
    @Test func selectionChangeAfterRebuildStillRuns() {
        let (coord, tv) = makeEditor()
        coord.rebuildTextStorageAndStyle(tv, from: "prose\n```\ncode line\n```\n")
        #expect(coord.isRebuildingDocument == false)

        let ns = tv.string as NSString
        let codeInner = ns.range(of: "code line")
        #expect(codeInner.location != NSNotFound)
        tv.setSelectedRange(NSRange(location: codeInner.location + 1, length: 0))

        #expect(tv.isContinuousSpellCheckingEnabled == false)   // handler ran, caret is in code
    }
}
#endif
