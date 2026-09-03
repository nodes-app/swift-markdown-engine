//
//  SpellCheckingPolicyTests.swift
//  MarkdownEngineTests
//

import Testing
@testable import MarkdownEngine

@Suite("SpellCheckingPolicy")
struct SpellCheckingPolicyTests {
    @Test("automaticQuoteSubstitution defaults to true, preserving prior always-on behavior")
    func defaultsToEnabled() {
        let policy = SpellCheckingPolicy()
        #expect(policy.automaticQuoteSubstitution == true)
        #expect(SpellCheckingPolicy.default.automaticQuoteSubstitution == true)
    }

    @Test("automaticQuoteSubstitution can be disabled independently of the other toggles")
    func canBeDisabled() {
        let policy = SpellCheckingPolicy(automaticQuoteSubstitution: false)
        #expect(policy.automaticQuoteSubstitution == false)
        #expect(policy.continuousSpellChecking == true)
        #expect(policy.grammarChecking == true)
        #expect(policy.automaticSpellingCorrection == true)
    }
}
