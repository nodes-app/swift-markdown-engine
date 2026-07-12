//
//  DocumentParseState.swift
//  MarkdownEngine
//
//  Created by Luca Chen on 11.07.26.
//
//  Per-editor incremental parse state: one UTF-16 buffer, its block list, and
//  its token list evolve together under a single edit descriptor. A keystroke
//  then pays one O(edit) buffer splice and a block-window re-tokenize instead
//  of a full-document re-extraction plus two independent O(doc) prefix/suffix
//  diff scans (BlockParser and the tokenizer each ran their own).
//

import Foundation

/// A contiguous edit in NEW-text coordinates plus the length delta, as
/// delivered by shouldChangeTextIn/textDidChange. The described region may be
/// wider than the minimal diff — splice logic only requires containment.
struct ParseEditDescriptor {
    let editedRange: NSRange   // post-edit coords: location + replacement length
    let delta: Int
}

final class DocumentParseState {
    private let lock = NSLock()
    private var chars: [unichar] = []
    private var blocks: [Block] = []
    private var tokens: [MarkdownToken] = []
    private var valid = false
#if DEBUG
    private var verifyCounter: UInt = 0
#endif

    /// The block list matching the most recent `tokens(for:edit:)` call —
    /// handed to the restyle so DocumentAST.parse skips the block parser.
    var currentBlocks: [Block] {
        lock.lock(); defer { lock.unlock() }
        return blocks
    }

    /// Drop all state (document switch / full rebuild) — the next parse
    /// re-extracts and re-parses from scratch.
    func invalidate() {
        lock.lock()
        valid = false
        chars = []; blocks = []; tokens = []
        lock.unlock()
    }

    /// Tokens for `text`. With a trustworthy `edit` the update is
    /// O(edit + touched blocks + suffix shift); without one, a single shared
    /// O(doc) diff scan replaces the two independent scans of the static path.
    func tokens(for text: String, edit: ParseEditDescriptor?) -> [MarkdownToken] {
        let ns = text as NSString
        let newLen = ns.length
        let tStart = DispatchTime.now().uptimeNanoseconds

        lock.lock()
        let prevChars = chars
        let prevBlocks = blocks
        let prevTokens = tokens
        let wasValid = valid
        lock.unlock()

        // 1. New buffer + change region — spliced O(edit) when the descriptor
        //    passes every sanity check, extracted O(doc) otherwise.
        var newChars: [unichar]
        var diff: BufferDiff?
        if wasValid, let edit,
           edit.delta != Int.min,
           edit.editedRange.location != NSNotFound,
           edit.editedRange.location >= 0, edit.editedRange.length >= 0,
           NSMaxRange(edit.editedRange) <= newLen,
           edit.editedRange.length - edit.delta >= 0,
           prevChars.count == newLen - edit.delta {
            let changeStart = edit.editedRange.location
            let changeEndNew = NSMaxRange(edit.editedRange)
            let changeEndOld = changeEndNew - edit.delta
            var replacement = [unichar](repeating: 0, count: edit.editedRange.length)
            if edit.editedRange.length > 0 { ns.getCharacters(&replacement, range: edit.editedRange) }
            newChars = prevChars
            newChars.replaceSubrange(changeStart..<changeEndOld, with: replacement)
            diff = BufferDiff(changeStart: changeStart, changeEndOld: changeEndOld,
                              changeEndNew: changeEndNew, delta: edit.delta)
#if DEBUG
            // Sampled safety net: the spliced buffer must equal the storage.
            // Opt-in (MD_PERF_VERIFY=1) — the fresh O(doc) extraction spikes
            // every 64th keystroke and pollutes the PERF numbers.
            verifyCounter &+= 1
            if PerfTrace.verifyEnabled, verifyCounter % 64 == 0 {
                var fresh = [unichar](repeating: 0, count: newLen)
                if newLen > 0 { ns.getCharacters(&fresh, range: NSRange(location: 0, length: newLen)) }
                assert(fresh == newChars, "spliced parse buffer diverged from the text storage")
            }
#endif
        } else {
            var buffer = [unichar](repeating: 0, count: newLen)
            if newLen > 0 { ns.getCharacters(&buffer, range: NSRange(location: 0, length: newLen)) }
            newChars = buffer
            if wasValid {
                diff = BlockParser.scanDiff(old: prevChars, new: newChars)
                if diff == nil, prevChars.count == newLen {
                    return prevTokens   // identical text
                }
            }
        }

        let tBuffer = DispatchTime.now().uptimeNanoseconds

        // 2. Blocks: window splice on the shared diff, full reparse fallback.
        var newBlocks: [Block]?
        if wasValid, let diff {
            newBlocks = BlockParser.incrementalParse(
                oldChars: prevChars, oldBlocks: prevBlocks,
                newChars: newChars, newNS: ns, diff: diff
            )?.blocks
        }
        let resolvedBlocks = newBlocks ?? BlockParser.computeBlocks(text)
        let tBlocks = DispatchTime.now().uptimeNanoseconds

        // 3. Tokens: prefix/suffix reuse on the same diff, full fallback.
        var newTokens: [MarkdownToken]?
        if wasValid, let diff, newBlocks != nil {
            newTokens = MarkdownTokenizer.incrementalTokens(
                oldChars: prevChars, prevTokens: prevTokens,
                newChars: newChars, blocks: resolvedBlocks, ns: ns, diff: diff
            )?.tokens
        }
        let resolvedTokens = newTokens ?? MarkdownTokenizer.fullTokens(blocks: resolvedBlocks, ns: ns)
        let tTokens = DispatchTime.now().uptimeNanoseconds
        PerfTrace.note {
            let ms = { (a: UInt64, b: UInt64) in String(format: "%.2f", Double(b - a) / 1_000_000) }
            let blockMode = newBlocks != nil ? "splice" : "FULL"
            let tokenMode = newTokens != nil ? "incremental" : "FULL"
            return "parseState split: buffer=\(ms(tStart, tBuffer))ms blocks(\(blockMode))=\(ms(tBuffer, tBlocks))ms tokens(\(tokenMode))=\(ms(tBlocks, tTokens))ms #blocks=\(resolvedBlocks.count) #tokens=\(resolvedTokens.count)"
        }

        lock.lock()
        chars = newChars
        blocks = resolvedBlocks
        tokens = resolvedTokens
        valid = true
        lock.unlock()

        // Publish to the static memos so their callers (restyle's
        // DocumentAST.parse, smart-input helpers) take the memcmp hit instead
        // of splicing against a one-keystroke-stale cache every time.
        BlockParser.seedCache(chars: newChars, blocks: resolvedBlocks)
        MarkdownTokenizer.seedCache(chars: newChars, tokens: resolvedTokens)
        return resolvedTokens
    }
}
