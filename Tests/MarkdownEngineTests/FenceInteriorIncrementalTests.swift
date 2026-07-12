//
//  FenceInteriorIncrementalTests.swift
//  MarkdownEngine
//
//  Created by Luca Chen on 12.07.26.
//
//  Typing INSIDE a fenced code / $$ block used to bail the incremental block
//  parse (full O(doc) computeBlocks + fullTokens on every keystroke — the
//  single biggest per-keystroke cliff in large documents). The edit-window
//  delimiter guards plus the trailing-fence guard make the window splice
//  sound for interior edits; these tests pin that, and the fence-heavy fuzz
//  holds the equivalence contract (fallback allowed, divergence never).
//

import Foundation
import Testing
@testable import MarkdownEngine

@Suite("Fence-interior incremental parse")
struct FenceInteriorIncrementalTests {

    private func chars(_ s: String) -> [unichar] {
        let ns = s as NSString
        var buf = [unichar](repeating: 0, count: ns.length)
        if ns.length > 0 { ns.getCharacters(&buf, range: NSRange(location: 0, length: ns.length)) }
        return buf
    }

    private func splice(_ old: String, at loc: Int, remove: Int, insert: String)
        -> (new: String, diff: BufferDiff) {
        let ns = NSMutableString(string: old)
        ns.replaceCharacters(in: NSRange(location: loc, length: remove), with: insert)
        let insertLen = (insert as NSString).length
        return (ns as String, BufferDiff(
            changeStart: loc,
            changeEndOld: loc + remove,
            changeEndNew: loc + insertLen,
            delta: insertLen - remove
        ))
    }

    @Test func interiorFenceEditSplicesIncrementally() throws {
        let old = "para one\n\n```swift\nlet x = 1\nlet y = 2\n```\n\ntail paragraph"
        let editLoc = (old as NSString).range(of: "x = 1").location
        let (new, diff) = splice(old, at: editLoc, remove: 1, insert: "value")

        let result = BlockParser.incrementalParse(
            oldChars: chars(old), oldBlocks: BlockParser.computeBlocks(old),
            newChars: chars(new), newNS: new as NSString, diff: diff
        )

        let blocks = try #require(result?.blocks)
        #expect(blocks == BlockParser.computeBlocks(new))
    }

    @Test func interiorBlockLatexEditSplicesIncrementally() throws {
        let old = "before\n\n$$\nE = mc^2\n$$\n\nafter text"
        let editLoc = (old as NSString).range(of: "mc^2").location
        let (new, diff) = splice(old, at: editLoc, remove: 0, insert: "k")

        let result = BlockParser.incrementalParse(
            oldChars: chars(old), oldBlocks: BlockParser.computeBlocks(old),
            newChars: chars(new), newNS: new as NSString, diff: diff
        )

        let blocks = try #require(result?.blocks)
        #expect(blocks == BlockParser.computeBlocks(new))
    }

    // Un-closing edit far from the backticks (trailing chars on the closer
    // line): the splice must either bail (nil) or match ground truth.
    @Test func unclosingEditStaysEquivalent() {
        let old = "para\n\n```\ncode line\n```      \n\ntail one\n\ntail two"
        let closerRange = (old as NSString).range(of: "```      ")
        let editLoc = NSMaxRange(closerRange) - 1     // 6 past the backticks
        let (new, diff) = splice(old, at: editLoc, remove: 0, insert: "x")

        let result = BlockParser.incrementalParse(
            oldChars: chars(old), oldBlocks: BlockParser.computeBlocks(old),
            newChars: chars(new), newNS: new as NSString, diff: diff
        )

        if let result {
            #expect(result.blocks == BlockParser.computeBlocks(new))
        }
    }

    // Fence-heavy differential fuzz: edits biased into fence/latex interiors.
    @Test(arguments: [0xFE7CE, 0x5EED5, 0xACE02, 0xB16F1] as [UInt64])
    func fenceHeavyFuzzMatchesFullParse(seed: UInt64) {
        var state = SplitMix(seed: seed)
        let state1 = DocumentParseState()
        var text = [
            "# Doc with many fences",
            "```swift", "let a = 1", "let b = 2", "func f() {", "  return", "}", "```",
            "prose between the fences with **bold**",
            "$$", "\\sum_{i=0}^n i^2", "$$",
            "```python", "def g():", "    pass", "```",
            "- a list item",
            "trailing paragraph",
        ].joined(separator: "\n")
        _ = state1.tokens(for: text, edit: nil)

        let interiorSnippets = ["x", "ab", " ", "\n", "word", "    indent", "0"]
        for step in 0..<300 {
            let ns = NSMutableString(string: text)
            let loc = state.int(ns.length + 1)
            let removeLen = min(state.int(5), ns.length - loc)
            let insert = state.int(5) == 0 ? "" : interiorSnippets[state.int(interiorSnippets.count)]
            ns.replaceCharacters(in: NSRange(location: loc, length: removeLen), with: insert)
            text = ns as String

            let edit = ParseEditDescriptor(
                editedRange: NSRange(location: loc, length: (insert as NSString).length),
                delta: (insert as NSString).length - removeLen
            )
            let incremental = state1.tokens(for: text, edit: edit)
            let full = MarkdownTokenizer.fullTokens(blocks: BlockParser.computeBlocks(text), ns: text as NSString)
            let same = incremental.count == full.count && zip(incremental, full).allSatisfy {
                $0.kind == $1.kind && $0.range == $1.range && $0.contentRange == $1.contentRange
                    && $0.markerRanges == $1.markerRanges
            }
            #expect(same, "step \(step): fence-heavy incremental diverged (edit at \(loc), removed \(removeLen), inserted \(insert.debugDescription))")
            if !same { return }
        }
    }

    private struct SplitMix {
        var seed: UInt64
        mutating func next() -> UInt64 {
            seed &+= 0x9E3779B97F4A7C15
            var z = seed
            z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
            z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
            return z ^ (z >> 31)
        }
        mutating func int(_ upper: Int) -> Int { upper <= 0 ? 0 : Int(next() % UInt64(upper)) }
    }
}
