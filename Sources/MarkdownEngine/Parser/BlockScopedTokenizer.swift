//
//  BlockScopedTokenizer.swift
//  MarkdownEngine
//
//  The live tokenization pipeline. For each block from `BlockParser`:
//  block-level tokens (heading, blockquote, table, block LaTeX, code) come from
//  `BlockLevelTokenizer` (hand scanners, no regex), while ALL inline tokens come
//  from the AST (`InlineParser` → `InlineASTAdapter`). Results are offset back
//  into document coordinates. Fenced-code blocks emit only their code-block
//  token (no inline markup inside).
//

import Foundation

extension MarkdownTokenizer {

    /// Per-block memo (substring → block-relative tokens): only the edited block re-parses, O(change). FIFO-capped, locked.
    private static let blockTokenLock = NSLock()
    private static var blockTokenCache: [String: [MarkdownToken]] = [:]
    private static var blockTokenOrder: [String] = []
    private static let blockTokenCacheCap = 4096

    // Document-level token memo: re-tokenize only the touched blocks; the rest shift by the delta.
    private static let tokensLock = NSLock()
    private static var cachedTokenChars: [unichar]?
    private static var cachedTokens: [MarkdownToken]?

    /// The live tokenizer: block-level tokens + inline AST tokens; fenced code emits only its code-block token.
    static func parseTokensViaAST(in text: String) -> [MarkdownToken] {
        let t0 = DispatchTime.now().uptimeNanoseconds
        defer {
            PerfTrace.note { "🗜️ tokenizer.static \(String(format: "%.2f", Double(DispatchTime.now().uptimeNanoseconds - t0) / 1_000_000))ms" }
        }
        let ns = text as NSString
        let newLen = ns.length
        var newChars = [unichar](repeating: 0, count: newLen)
        if newLen > 0 { ns.getCharacters(&newChars, range: NSRange(location: 0, length: newLen)) }

        let blocks = BlockParser.parse(text, utf16Chars: newChars)

        tokensLock.lock()
        let prevChars = cachedTokenChars
        let prevTokens = cachedTokens
        tokensLock.unlock()

        let result: [MarkdownToken]
        if let prevChars, let prevTokens {
            if let diff = BlockParser.scanDiff(old: prevChars, new: newChars) {
                result = incrementalTokens(oldChars: prevChars, prevTokens: prevTokens, newChars: newChars, blocks: blocks, ns: ns, diff: diff)?.tokens
                    ?? fullTokens(blocks: blocks, ns: ns)
            } else {
                result = prevTokens   // identical text
            }
        } else {
            result = fullTokens(blocks: blocks, ns: ns)
        }

        tokensLock.lock(); cachedTokenChars = newChars; cachedTokens = result; tokensLock.unlock()
        return result
    }

    /// Adopt an externally computed parse (DocumentParseState publishes its
    /// per-keystroke result) so static-path callers hit instead of re-splicing
    /// against a one-keystroke-stale cache.
    static func seedCache(chars: [unichar], tokens: [MarkdownToken]) {
        tokensLock.lock(); cachedTokenChars = chars; cachedTokens = tokens; tokensLock.unlock()
    }

    static func fullTokens(blocks: [Block], ns: NSString) -> [MarkdownToken] {
        var result: [MarkdownToken] = []
        for block in blocks {
            let delta = block.range.location
            let relTokens = cachedBlockTokens(kind: block.kind, sub: ns.substring(with: block.range))
            result.append(contentsOf: relTokens.map { $0.shifted(by: delta) })
        }
        return result
    }

    /// Reuse prefix/suffix tokens (suffix shifted) and re-tokenize only touched blocks,
    /// against a precomputed change region; nil to fall back to full.
    static func incrementalTokens(oldChars o: [unichar], prevTokens: [MarkdownToken], newChars n: [unichar], blocks: [Block], ns: NSString, diff: BufferDiff) -> (tokens: [MarkdownToken], retok: Int)? {
        let oldLen = o.count, newLen = n.count
        guard oldLen > 0, newLen > 0, !blocks.isEmpty else { return nil }

        let delta = diff.delta
        let changeStart = diff.changeStart, changeEndNew = diff.changeEndNew
        guard changeStart >= 0, diff.changeEndOld <= oldLen, changeEndNew <= newLen,
              changeStart <= diff.changeEndOld, changeStart <= changeEndNew else { return nil }

        // A fence/block-LaTeX delimiter can pair with a distant partner and ripple far → full tokenization.
        if BlockParser.hasBlockDelimiter(o, changeStart, diff.changeEndOld)
            || BlockParser.hasBlockDelimiter(n, changeStart, changeEndNew) { return nil }

        // New blocks touching the changed char range [changeStart, changeEndNew].
        // Blocks tile in order → the touching set is one contiguous run;
        // binary search replaces the O(#blocks) full scan per keystroke.
        var lo = 0, hi = blocks.count - 1
        while lo < hi {                       // first block ending >= changeStart
            let m = (lo + hi) / 2
            if NSMaxRange(blocks[m].range) >= changeStart { hi = m } else { lo = m + 1 }
        }
        var first = lo
        lo = 0; hi = blocks.count - 1
        while lo < hi {                       // last block starting <= changeEndNew
            let m = (lo + hi + 1) / 2
            if blocks[m].range.location <= changeEndNew { lo = m } else { hi = m - 1 }
        }
        let last = lo
        // Validate the run actually touches (mirrors the old filter exactly).
        if first > last || blocks[first].range.location > changeEndNew || NSMaxRange(blocks[last].range) < changeStart {
            return delta == 0 ? (prevTokens, 0) : nil
        }
        lo = first
        hi = last

        // Widen the window until no previous token straddles either cut (a block's extent can change in place).
        var expanded = true
        while expanded {
            expanded = false
            for t in prevTokens {
                let cutStart = blocks[lo].range.location
                if t.range.location < cutStart, NSMaxRange(t.range) > cutStart {
                    while lo > 0, blocks[lo].range.location > t.range.location { lo -= 1; expanded = true }
                }
                let cutEndOld = NSMaxRange(blocks[hi].range) - delta
                if t.range.location < cutEndOld, NSMaxRange(t.range) > cutEndOld {
                    while hi < blocks.count - 1, NSMaxRange(blocks[hi].range) - delta < NSMaxRange(t.range) { hi += 1; expanded = true }
                }
            }
        }

        let regionStart = blocks[lo].range.location
        let regionEndOld = NSMaxRange(blocks[hi].range) - delta

        var result: [MarkdownToken] = []
        for t in prevTokens where NSMaxRange(t.range) <= regionStart { result.append(t) }   // prefix, unchanged
        for i in lo...hi {                                                                   // changed window, retokenized
            let off = blocks[i].range.location
            let rel = cachedBlockTokens(kind: blocks[i].kind, sub: ns.substring(with: blocks[i].range))
            result.append(contentsOf: rel.map { $0.shifted(by: off) })
        }
        for t in prevTokens where t.range.location >= regionEndOld { result.append(t.shifted(by: delta)) }  // suffix, shifted
        return (result, hi - lo + 1)
    }

    /// Cached block-relative tokens for `sub` (computed on miss); a pure memo over the token logic.
    static func cachedBlockTokens(kind: BlockKind, sub: String) -> [MarkdownToken] {
        blockTokenLock.lock()
        if let cached = blockTokenCache[sub] {
            blockTokenLock.unlock()
            return cached
        }
        blockTokenLock.unlock()

        let blockLevel = BlockLevelTokenizer.tokens(for: kind, in: sub as NSString)
        // Fenced code is opaque — no inline markup inside it.
        let inline = kind == .fencedCode
            ? []
            : InlineASTAdapter.tokens(from: InlineParser.parse(sub))
        let computed = blockLevel + inline

        blockTokenLock.lock()
        if blockTokenCache[sub] == nil {
            blockTokenCache[sub] = computed
            blockTokenOrder.append(sub)
            if blockTokenOrder.count > blockTokenCacheCap {
                blockTokenCache[blockTokenOrder.removeFirst()] = nil
            }
        }
        blockTokenLock.unlock()
        return computed
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
