//
//  InlineASTAdapterTests.swift
//  MarkdownEngineTests
//
//  Phase 2.5 — verifies the inline-AST → token adapter against the legacy
//  tokenizer as an oracle for unchanged inline constructs, plus the intended
//  divergences (the bug fixes).
//

import Foundation
import Testing
@testable import MarkdownEngine

@Suite("Phase 2.5 — inline AST → token adapter")
struct InlineASTAdapterTests {

    /// For inline inputs whose behavior is unchanged, the adapter output must
    /// match the legacy tokenizer exactly (position-normalized via tokenSnapshot).
    @Test("adapter matches legacy tokenizer for unchanged inline constructs", arguments: [
        "plain text with no markup",
        "**x**", "*y*", "***z***", "_u_", "__v__",
        "~~s~~", "`c`", "`` `tick` ``",
        "[a](b)", "[text](https://example.com)",
        "[[N]]", "[[N|id]]", "![[E]]", "![a](b)",
        "$x+y$", "**a *b* c**", "a *b* and `c` and [d](e)",
    ])
    func matchesLegacy(_ input: String) {
        let viaAdapter = InlineASTAdapter.tokens(from: InlineParser.parse(input))
        let legacy = MarkdownTokenizer.parseTokens(in: input)
        #expect(tokenSnapshot(viaAdapter, in: input) == tokenSnapshot(legacy, in: input),
                "adapter/legacy mismatch for '\(input)'")
    }

    // MARK: - Intended divergences (bug fixes)

    @Test("bug 4: link URL with balanced parens is one whole link token")
    func bug4LinkParens() {
        let tokens = InlineASTAdapter.tokens(from: InlineParser.parse("[a](b(c))"))
        #expect(tokens.count == 1)
        #expect(tokens.first?.kind == .link)
        #expect(tokens.first?.range == NSRange(location: 0, length: 9))
    }

    @Test("bug 3: a $…$ that would cross a code span produces no latex token")
    func bug3NoCrossCodeLatex() {
        let tokens = InlineASTAdapter.tokens(from: InlineParser.parse("$x `c` y$"))
        #expect(!tokens.contains { $0.kind == .inlineLatex })
        #expect(tokens.contains { $0.kind == .inlineCode })
    }
}
