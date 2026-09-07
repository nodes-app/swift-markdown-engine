#if os(macOS)
//
//  FlattenedRunsTests.swift
//  MarkdownEngineTests
//
//  Created by Luca Chen on 25.07.26.
//
//  `flattenedRuns` replaced a per-key `addAttribute` loop that was quadratic in
//  document size (19.1s of a 21s open at 346k chars). Speed is only half the
//  requirement — the flattened write must land the SAME attributes, including
//  the "later range wins per key" precedence the old loop got for free from
//  repeated `addAttribute` calls. So these tests assert equivalence against the
//  old loop rather than against hand-written expectations.
//

import AppKit
import Testing
@testable import MarkdownEngine

private let base: [NSAttributedString.Key: Any] = [
    .font: NSFont.systemFont(ofSize: 13),
    .foregroundColor: NSColor.black
]

/// The loop `flattenedRuns` replaced, kept here as the oracle.
private func applyNaively(_ ranges: [StyledRange], to text: String) -> NSMutableAttributedString {
    let storage = NSMutableAttributedString(string: text)
    storage.setAttributes(base, range: NSRange(location: 0, length: (text as NSString).length))
    for (range, attrs) in ranges {
        for (key, value) in attrs {
            storage.addAttribute(key, value: value, range: range)
        }
    }
    return storage
}

private func applyFlattened(_ ranges: [StyledRange], to text: String) -> NSMutableAttributedString {
    let length = (text as NSString).length
    let storage = NSMutableAttributedString(string: text)
    storage.setAttributes(base, range: NSRange(location: 0, length: length))
    for (range, attrs) in MarkdownStyler.flattenedRuns(ranges, base: base, documentLength: length) {
        storage.setAttributes(attrs, range: range)
    }
    return storage
}

@Suite("flattenedRuns")
struct FlattenedRunsTests {

    @Test("Disjoint ranges land identically")
    func disjoint() {
        let text = "The quick brown fox jumps over the lazy dog"
        let ranges: [StyledRange] = [
            (NSRange(location: 4, length: 5), [.foregroundColor: NSColor.red]),
            (NSRange(location: 16, length: 3), [.foregroundColor: NSColor.blue])
        ]
        #expect(applyFlattened(ranges, to: text).isEqual(to: applyNaively(ranges, to: text)))
    }

    @Test("A later overlapping range wins per key, and only per key")
    func overlapPrecedence() {
        let text = "abcdefghij"
        let ranges: [StyledRange] = [
            (NSRange(location: 0, length: 6), [.foregroundColor: NSColor.red,
                                               .backgroundColor: NSColor.yellow]),
            // Overrides the color on 2..<8 but must leave the background from the
            // first range standing on 2..<6.
            (NSRange(location: 2, length: 6), [.foregroundColor: NSColor.green])
        ]
        let flattened = applyFlattened(ranges, to: text)
        #expect(flattened.isEqual(to: applyNaively(ranges, to: text)))
        #expect(flattened.attribute(.foregroundColor, at: 3, effectiveRange: nil) as? NSColor == .green)
        #expect(flattened.attribute(.backgroundColor, at: 3, effectiveRange: nil) as? NSColor == .yellow)
    }

    @Test("Fully nested and identical ranges")
    func nested() {
        let text = String(repeating: "x", count: 40)
        let ranges: [StyledRange] = [
            (NSRange(location: 0, length: 40), [.foregroundColor: NSColor.red]),
            (NSRange(location: 10, length: 20), [.backgroundColor: NSColor.gray]),
            (NSRange(location: 10, length: 20), [.foregroundColor: NSColor.blue]),
            (NSRange(location: 15, length: 1), [.foregroundColor: NSColor.green])
        ]
        #expect(applyFlattened(ranges, to: text).isEqual(to: applyNaively(ranges, to: text)))
    }

    @Test("Character-sized adjacent ranges coalesce without changing the result")
    func adjacentCoalesce() {
        let text = String(repeating: "y", count: 50)
        // The shape `styleIncompleteLinkBrackets` used to emit: one range per char.
        let ranges: [StyledRange] = (0..<50).map {
            (NSRange(location: $0, length: 1), [.foregroundColor: NSColor.red])
        }
        #expect(applyFlattened(ranges, to: text).isEqual(to: applyNaively(ranges, to: text)))
        // 50 equal single-char ranges must collapse to one run.
        #expect(MarkdownStyler.flattenedRuns(ranges, base: base, documentLength: 50).count == 1)
    }

    @Test("Touching ranges are not merged when their attributes differ")
    func touchingNotMerged() {
        let text = String(repeating: "z", count: 10)
        let ranges: [StyledRange] = [
            (NSRange(location: 0, length: 5), [.foregroundColor: NSColor.red]),
            (NSRange(location: 5, length: 5), [.foregroundColor: NSColor.blue])
        ]
        let runs = MarkdownStyler.flattenedRuns(ranges, base: base, documentLength: 10)
        #expect(runs.count == 2)
        #expect(applyFlattened(ranges, to: text).isEqual(to: applyNaively(ranges, to: text)))
    }

    @Test("Degenerate ranges are dropped, not applied out of bounds")
    func degenerate() {
        let text = String(repeating: "w", count: 20)
        let ranges: [StyledRange] = [
            (NSRange(location: 5, length: 0), [.foregroundColor: NSColor.red]),
            (NSRange(location: NSNotFound, length: 3), [.foregroundColor: NSColor.red]),
            (NSRange(location: 18, length: 10), [.foregroundColor: NSColor.red]),   // past the end
            (NSRange(location: 2, length: 4), [.foregroundColor: NSColor.blue])
        ]
        let runs = MarkdownStyler.flattenedRuns(ranges, base: base, documentLength: 20)
        #expect(runs.count == 1)
        #expect(runs[0].range == NSRange(location: 2, length: 4))
    }

    @Test("Randomised overlap storms stay equivalent to the old loop")
    func randomisedEquivalence() {
        let length = 400
        let text = String(repeating: "m", count: length)
        let colors: [NSColor] = [.red, .green, .blue, .orange, .purple]
        // Deterministic generator: a failure must be reproducible from the seed.
        var seed: UInt64 = 0x9E3779B97F4A7C15
        func next(_ bound: Int) -> Int {
            seed ^= seed << 13; seed ^= seed >> 7; seed ^= seed << 17
            return Int(seed % UInt64(bound))
        }
        for _ in 0..<40 {
            var ranges: [StyledRange] = []
            for _ in 0..<120 {
                let location = next(length)
                let maxLength = length - location
                let rangeLength = maxLength == 0 ? 0 : next(min(maxLength, 25)) + 1
                var attrs: [NSAttributedString.Key: Any] = [.foregroundColor: colors[next(colors.count)]]
                if next(2) == 0 { attrs[.backgroundColor] = colors[next(colors.count)] }
                if next(3) == 0 { attrs[.underlineStyle] = next(2) }
                ranges.append((NSRange(location: location, length: rangeLength), attrs))
            }
            #expect(applyFlattened(ranges, to: text).isEqual(to: applyNaively(ranges, to: text)))
        }
    }
}
#endif
