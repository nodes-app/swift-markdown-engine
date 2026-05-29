//
//  BlockScopedTokenizer.swift
//  MarkdownEngine
//
//  Phase 1 — the per-block tokenization pipeline. Runs the EXISTING tokenizer
//  scoped to each block produced by `BlockParser`, then offsets the results
//  back into document coordinates. Reusing the existing `parseTokens` per block
//  (rather than re-deriving suppression rules) keeps behavior identical to the
//  whole-document parse — *including* today's quirks — so this can ship behind
//  the old default while parity is proven. The inline parser replaces the
//  reused logic in Phase 2.
//
//  This is exact-equal to `parseTokens(in:)` as long as `BlockParser` never
//  splits a multi-line construct (fenced code, block LaTeX, table) across
//  blocks — single-line/inline constructs are confined to their block and are
//  reproduced by the per-block parse regardless of the block's kind.
//

import Foundation

extension MarkdownTokenizer {

    /// Tokenize by running the existing tokenizer on each `BlockParser` block's
    /// substring and shifting ranges back to absolute document offsets.
    static func parseTokensByBlock(in text: String) -> [MarkdownToken] {
        let nsText = text as NSString
        var result: [MarkdownToken] = []
        for block in BlockParser.parse(text) {
            let substring = nsText.substring(with: block.range)
            let delta = block.range.location
            for token in parseTokens(in: substring) {
                result.append(token.shifted(by: delta))
            }
        }
        return result
    }

    /// Block-level tokens whose recognition stays with the legacy regexes for
    /// now; only the *inline* layer moves to the new AST parser in Phase 2.5.
    private static let blockLevelKinds: Set<MarkdownTokenKind> = [
        .heading, .blockquote, .table, .blockLatex, .codeBlock,
    ]

    /// Phase 2.5 pipeline — legacy block-level tokens + NEW inline AST tokens.
    /// Opaque fenced-code blocks emit only their code-block token (no inline
    /// markup inside — fixes the "inline parsed inside a code block" bug). This
    /// is the candidate that becomes the default once snapshot diffs are reviewed.
    static func parseTokensViaAST(in text: String) -> [MarkdownToken] {
        let ns = text as NSString
        var result: [MarkdownToken] = []
        for block in BlockParser.parse(text) {
            let sub = ns.substring(with: block.range)
            let delta = block.range.location
            let kept: [MarkdownToken]
            if block.kind == .fencedCode {
                kept = parseTokens(in: sub).filter { $0.kind == .codeBlock }
            } else {
                let blockLevel = parseTokens(in: sub).filter { blockLevelKinds.contains($0.kind) }
                let inline = InlineASTAdapter.tokens(from: InlineParser.parse(sub))
                kept = blockLevel + inline
            }
            result.append(contentsOf: kept.map { $0.shifted(by: delta) })
        }
        return result
    }
}

private extension MarkdownToken {
    /// Returns a copy with every range moved forward by `delta` UTF-16 units.
    func shifted(by delta: Int) -> MarkdownToken {
        func move(_ r: NSRange) -> NSRange {
            NSRange(location: r.location + delta, length: r.length)
        }
        return MarkdownToken(
            kind: kind,
            range: move(range),
            contentRange: move(contentRange),
            markerRanges: markerRanges.map(move)
        )
    }
}
