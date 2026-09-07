#if os(macOS)
//
//  ParseIncrementalEquivalenceTests.swift
//  MarkdownEngine
//
//  Created by Luca Chen on 11.07.26.
//
//  Differential fuzz for the incremental parse pipeline: after every random
//  edit, DocumentParseState (descriptor-driven and scan-driven) must produce
//  tokens identical to a from-scratch full parse, and the incremental backtick
//  census must equal the full scan. The incremental paths may fall back —
//  equivalence is the only contract.
//

import Foundation
import Testing
@testable import MarkdownEngine

@Suite("Incremental parse ≡ full parse")
struct ParseIncrementalEquivalenceTests {

    // Deterministic PRNG (SplitMix64) — reproducible failures.
    private struct Rng {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E3779B97F4A7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
            z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
            return z ^ (z >> 31)
        }
        mutating func int(_ upper: Int) -> Int { upper <= 0 ? 0 : Int(next() % UInt64(upper)) }
        mutating func pick<T>(_ a: [T]) -> T { a[int(a.count)] }
    }

    private static let lineTemplates = [
        "Plain prose with **bold** and *italic* text here.",
        "# Heading level one",
        "## Second heading",
        "- list item with `inline code`",
        "1. ordered item",
        "> a blockquote line",
        "| a | b |", "|---|---|", "| 1 | 2 |",
        "```swift", "let x = 1", "```",
        "$$", "E = mc^2", "$$",
        "A [[Wiki Link]] and ==highlight== and ~~strike~~.",
        "Inline $x^2$ latex and an ![[embed.png]] image.",
        "",
    ]

    private static let editSnippets = [
        "x", "ab", " ", "\n", "`", "``", "```", "$", "$$", "**", "- ", "# ",
        "| c |", "[[N]]", "\n\n", "word and more",
    ]

    private func makeDoc(_ rng: inout Rng, lines: Int) -> String {
        var out: [String] = []
        for _ in 0..<lines { out.append(rng.pick(Self.lineTemplates)) }
        return out.joined(separator: "\n")
    }

    /// Comparable dump — MarkdownToken has no Equatable conformance.
    private func dump(_ tokens: [MarkdownToken]) -> [String] {
        tokens.map {
            "\($0.kind)|\($0.range)|\($0.contentRange)|\($0.markerRanges.map { r in "\(r)" }.joined(separator: ","))"
        }
    }

    private func groundTruth(_ text: String) -> [String] {
        let ns = text as NSString
        return dump(MarkdownTokenizer.fullTokens(blocks: BlockParser.computeBlocks(text), ns: ns))
    }

    private func runFuzz(seed: UInt64, useDescriptor: Bool, widen: Bool = false) {
        var rng = Rng(state: seed)
        let state = DocumentParseState()
        var text = makeDoc(&rng, lines: 40)

        // Seed the state with the initial document.
        _ = state.tokens(for: text, edit: nil)

        for step in 0..<250 {
            let ns = NSMutableString(string: text)
            let loc = rng.int(ns.length + 1)
            let removeLen = min(rng.int(6), ns.length - loc)
            let insert = rng.int(4) == 0 ? "" : rng.pick(Self.editSnippets)
            ns.replaceCharacters(in: NSRange(location: loc, length: removeLen), with: insert)
            text = ns as String

            var edit: ParseEditDescriptor?
            if useDescriptor {
                var range = NSRange(location: loc, length: (insert as NSString).length)
                if widen {
                    // A containing region must be just as correct as the minimal one.
                    let grow = rng.int(3)
                    let lo = max(0, range.location - grow)
                    let hi = min(ns.length, NSMaxRange(range) + grow)
                    range = NSRange(location: lo, length: hi - lo)
                }
                edit = ParseEditDescriptor(editedRange: range, delta: (insert as NSString).length - removeLen)
            }

            let incremental = dump(state.tokens(for: text, edit: edit))
            let full = groundTruth(text)
            #expect(incremental == full,
                    "seed \(seed) step \(step): incremental tokens diverged (edit at \(loc), removed \(removeLen), inserted \(insert.debugDescription))")
            if incremental != full { return }   // stop at first divergence, keep output readable
        }
    }

    @Test func descriptorDrivenMatchesFullParse() {
        runFuzz(seed: 0xA11CE, useDescriptor: true)
        runFuzz(seed: 0xB0B, useDescriptor: true)
    }

    @Test func widenedDescriptorMatchesFullParse() {
        runFuzz(seed: 0xC0FFEE, useDescriptor: true, widen: true)
    }

    @Test func scanDrivenMatchesFullParse() {
        runFuzz(seed: 0xD00D, useDescriptor: false)
    }

    // MARK: - Backtick census

    @Test func windowCensusComposesExactly() {
        // Boundary cases: completing ``` between existing backticks, joining
        // fences by deleting the separator, runs of 4/6/7.
        let cases: [(before: String, edit: NSRange, insert: String)] = [
            ("a``b", NSRange(location: 2, length: 0), "`"),     // `` + ` → ```
            ("```\n```", NSRange(location: 3, length: 1), ""),  // join to ``````
            ("````x````", NSRange(location: 4, length: 1), "`"),
            ("abc", NSRange(location: 1, length: 0), "```"),
            ("`````", NSRange(location: 2, length: 1), ""),
        ]
        for c in cases {
            let beforeNS = c.before as NSString
            let oldWindow = MarkdownDetection.backtickWindowCount(in: beforeNS, around: c.edit)
            let after = beforeNS.replacingCharacters(in: c.edit, with: c.insert) as NSString
            let newRange = NSRange(location: c.edit.location, length: (c.insert as NSString).length)
            let newWindow = MarkdownDetection.backtickWindowCount(in: after, around: newRange)
            let composed = MarkdownDetection.tripleBacktickCount(in: beforeNS) - oldWindow + newWindow
            #expect(composed == MarkdownDetection.tripleBacktickCount(in: after),
                    "census composition failed for \(c.before.debugDescription) + \(c.insert.debugDescription)")
        }
    }

    @Test func windowCensusFuzz() {
        var rng = Rng(state: 0xFACE)
        let alphabet = ["`", "a", "\n", "``", "b`"]
        var text = (0..<60).map { _ in rng.pick(alphabet) }.joined()
        for step in 0..<400 {
            let ns = text as NSString
            let loc = rng.int(ns.length + 1)
            let removeLen = min(rng.int(4), ns.length - loc)
            let insert = rng.int(4) == 0 ? "" : rng.pick(alphabet)
            let editOld = NSRange(location: loc, length: removeLen)

            let oldWindow = MarkdownDetection.backtickWindowCount(in: ns, around: editOld)
            let after = ns.replacingCharacters(in: editOld, with: insert) as NSString
            let editNew = NSRange(location: loc, length: (insert as NSString).length)
            let newWindow = MarkdownDetection.backtickWindowCount(in: after, around: editNew)

            let composed = MarkdownDetection.tripleBacktickCount(in: ns) - oldWindow + newWindow
            #expect(composed == MarkdownDetection.tripleBacktickCount(in: after), "step \(step)")
            if composed != MarkdownDetection.tripleBacktickCount(in: after) { return }
            text = after as String
        }
    }
}
#endif
