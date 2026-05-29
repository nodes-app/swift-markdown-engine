//
//  ScopedParityTests.swift
//  MarkdownEngineTests
//
//  Phase 1 — proves the per-block scoped tokenizer reproduces the
//  whole-document tokenizer EXACTLY (order-normalized) across the corpus.
//  Any divergence means BlockParser split a multi-line construct; the failure
//  message names the case and shows the first differing line.
//

import Foundation
import Testing
@testable import MarkdownEngine

@Suite("Phase 1 — scoped parser parity")
struct ScopedParityTests {

    @Test("per-block parse equals whole-document parse", arguments: MarkdownCorpus.cases)
    func parity(_ c: MarkdownCase) {
        let whole = tokenSnapshot(MarkdownTokenizer.parseTokens(in: c.text), in: c.text)
        let byBlock = tokenSnapshot(MarkdownTokenizer.parseTokensByBlock(in: c.text), in: c.text)
        if whole != byBlock {
            Issue.record("""
            parity diff for '\(c.name)':
            \(firstDiffLine(whole: whole, byBlock: byBlock))
            """)
        }
    }

    private func firstDiffLine(whole: String, byBlock: String) -> String {
        let w = whole.split(separator: "\n", omittingEmptySubsequences: false)
        let b = byBlock.split(separator: "\n", omittingEmptySubsequences: false)
        for i in 0..<Swift.max(w.count, b.count) {
            let wl = i < w.count ? String(w[i]) : "⟨missing⟩"
            let bl = i < b.count ? String(b[i]) : "⟨missing⟩"
            if wl != bl {
                return "  line \(i + 1):\n    whole:   \(wl)\n    byBlock: \(bl)"
            }
        }
        return "  (equal)"
    }
}
