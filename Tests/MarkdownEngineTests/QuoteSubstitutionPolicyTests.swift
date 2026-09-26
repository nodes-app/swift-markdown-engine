//
//  QuoteSubstitutionPolicyTests.swift
//  MarkdownEngineTests
//
//  Smart-quote substitution follows `SpellCheckingPolicy.automaticQuoteSubstitution`
//  instead of being forced on: an embedder editing raw Markdown/LaTeX source can
//  keep straight `'` and `"`, and neither caret moves out of a code/LaTeX span nor
//  a rebuild turn it back on. The menu toggle is captured like the spelling ones.
//

import AppKit
import SwiftUI
import Testing
@testable import MarkdownEngine

@MainActor
@Suite("Quote substitution policy")
struct QuoteSubstitutionPolicyTests {

    private func makeEditor(quotes: Bool) -> (NativeTextViewCoordinator, NativeTextView) {
        _ = NSApplication.shared   // selection path reads NSApp.currentEvent
        let coordinator = NativeTextViewCoordinator(
            text: .constant(""), fontName: "SF Pro Text", fontSize: 14,
            isWikiLinkActive: .constant(false), onLinkClick: nil, onInlineSelectionChange: nil
        )
        coordinator.userPrefersAutomaticQuoteSubstitution = quotes
        let textView = NativeTextView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        textView.isEditable = true
        textView.configuration = .default
        textView.delegate = coordinator
        coordinator.textView = textView
        return (coordinator, textView)
    }

    private func moveCaret(_ tv: NSTextView, into needle: String) {
        let r = (tv.string as NSString).range(of: needle)
        #expect(r.location != NSNotFound)
        tv.setSelectedRange(NSRange(location: r.location + 1, length: 0))
    }

    @Test func defaultPolicyKeepsSmartQuotesOn() {
        #expect(SpellCheckingPolicy.default.automaticQuoteSubstitution == true)
    }

    // Leaving a suppress zone used to force smart quotes back on regardless of policy.
    @Test func optOutSurvivesLeavingSuppressZones() {
        let (coord, tv) = makeEditor(quotes: false)
        coord.rebuildTextStorageAndStyle(tv, from: "prose here\n```\ncode line\n```\nmore prose\n")
        #expect(tv.isAutomaticQuoteSubstitutionEnabled == false)

        moveCaret(tv, into: "code line")
        #expect(tv.isAutomaticQuoteSubstitutionEnabled == false)
        moveCaret(tv, into: "more prose")
        #expect(tv.isAutomaticQuoteSubstitutionEnabled == false)
    }

    @Test func optInStillSuppressedInsideCode() {
        let (coord, tv) = makeEditor(quotes: true)
        coord.rebuildTextStorageAndStyle(tv, from: "prose here\n```\ncode line\n```\nmore prose\n")

        moveCaret(tv, into: "code line")
        #expect(tv.isAutomaticQuoteSubstitutionEnabled == false)
        moveCaret(tv, into: "more prose")
        #expect(tv.isAutomaticQuoteSubstitutionEnabled == true)
    }

    // Edit > Substitutions > Smart Quotes is captured into the policy and reported.
    @Test func menuToggleIsCapturedAndReported() {
        let (coord, tv) = makeEditor(quotes: true)
        coord.rebuildTextStorageAndStyle(tv, from: "prose here\n```\ncode line\n```\nmore prose\n")
        var reported: SpellCheckingPolicy?
        coord.onSpellCheckingPolicyChanged = { reported = $0 }

        moveCaret(tv, into: "more prose")
        tv.toggleAutomaticQuoteSubstitution(nil)

        #expect(coord.userPrefersAutomaticQuoteSubstitution == false)
        #expect(reported?.automaticQuoteSubstitution == false)
        moveCaret(tv, into: "code line")
        moveCaret(tv, into: "more prose")
        #expect(tv.isAutomaticQuoteSubstitutionEnabled == false)
    }
}
