#if os(macOS)
//
//  RestyleApplyEquivalenceTests.swift
//  MarkdownEngineTests
//
//  Created by Luca Chen on 25.07.26.
//
//  `applyStyledRanges` replaced the apply loop's per-paragraph rescan of the full
//  styled-range list (4.9s of main thread on a 5,241-paragraph × ~40,000-range
//  open) with a sweep index. Speed is only half the requirement — the indexed
//  apply must land the SAME attributes, including the two orderings the old loop
//  got for free: paragraphs in their given order (a nested paragraph's
//  `setAttributes` wipes what an earlier one painted) and, inside a paragraph,
//  ranges in their original order (a later range wins per key). So these tests
//  assert equivalence against the old loop rather than hand-written expectations,
//  and run every case through BOTH paths — indexed and plain rescan.
//

import AppKit
import Testing
@testable import MarkdownEngine

private let base: [NSAttributedString.Key: Any] = [
    .font: NSFont.systemFont(ofSize: 13),
    .foregroundColor: NSColor.black
]

/// Seeded so the whole document carries attributes the apply must clear: `.link`
/// (removed explicitly) and a stray colour outside every paragraph (must survive,
/// since only paragraphs are re-based).
private func seededStorage(_ text: String) -> NSMutableAttributedString {
    let storage = NSMutableAttributedString(string: text)
    let full = NSRange(location: 0, length: (text as NSString).length)
    storage.setAttributes([.link: URL(string: "https://example.com")!,
                           .foregroundColor: NSColor.magenta], range: full)
    return storage
}

/// The loop `applyStyledRanges` replaced, kept here as the oracle.
private func applyNaively(_ ranges: [StyledRange], paragraphs: [NSRange], to text: String) -> NSMutableAttributedString {
    let storage = seededStorage(text)
    for paragraph in paragraphs {
        storage.setAttributes(base, range: paragraph)
        storage.removeAttribute(.link, range: paragraph)
        for (range, attrs) in ranges where NSIntersectionRange(range, paragraph).length > 0 {
            let clippedRange = NSIntersectionRange(range, paragraph)
            for (key, value) in attrs {
                storage.addAttribute(key, value: value, range: clippedRange)
            }
        }
    }
    return storage
}

private func applyIndexed(_ ranges: [StyledRange], paragraphs: [NSRange], to text: String) -> NSMutableAttributedString {
    let storage = seededStorage(text)
    TextStylingService.applyStyledRanges(ranges, paragraphs: paragraphs, baseAttributes: base,
                                         to: storage, minimumParagraphsForIndex: 0)
    return storage
}

private func applyRescan(_ ranges: [StyledRange], paragraphs: [NSRange], to text: String) -> NSMutableAttributedString {
    let storage = seededStorage(text)
    TextStylingService.applyStyledRanges(ranges, paragraphs: paragraphs, baseAttributes: base,
                                         to: storage, minimumParagraphsForIndex: .max)
    return storage
}

/// Both branches of the paragraph-count threshold have to match the oracle.
private func expectEquivalent(_ ranges: [StyledRange], paragraphs: [NSRange], text: String,
                              _ comment: Comment? = nil, sourceLocation: SourceLocation = #_sourceLocation) {
    let oracle = applyNaively(ranges, paragraphs: paragraphs, to: text)
    #expect(applyIndexed(ranges, paragraphs: paragraphs, to: text).isEqual(to: oracle),
            comment, sourceLocation: sourceLocation)
    #expect(applyRescan(ranges, paragraphs: paragraphs, to: text).isEqual(to: oracle),
            comment, sourceLocation: sourceLocation)
}

/// Paragraphs of `size` tiling `count` of them, as a document-wide restyle passes.
private func tiled(count: Int, size: Int) -> [NSRange] {
    (0..<count).map { NSRange(location: $0 * size, length: size) }
}

@Suite("restyle apply")
struct RestyleApplyEquivalenceTests {

    @Test("A range spanning paragraph boundaries is clipped per paragraph")
    func spansBoundaries() {
        let text = String(repeating: "x", count: 120)
        let paragraphs = tiled(count: 12, size: 10)
        let ranges: [StyledRange] = [
            (NSRange(location: 5, length: 40), [.foregroundColor: NSColor.red]),
            (NSRange(location: 0, length: 120), [.backgroundColor: NSColor.yellow]),
            (NSRange(location: 98, length: 22), [.underlineStyle: 1])
        ]
        expectEquivalent(ranges, paragraphs: paragraphs, text: text)
    }

    @Test("Same location, different attributes: the later range still wins per key")
    func sameLocationPrecedence() {
        let text = String(repeating: "y", count: 80)
        let paragraphs = tiled(count: 8, size: 10)
        let ranges: [StyledRange] = [
            (NSRange(location: 20, length: 10), [.foregroundColor: NSColor.red,
                                                 .backgroundColor: NSColor.yellow]),
            (NSRange(location: 20, length: 10), [.foregroundColor: NSColor.green]),
            (NSRange(location: 20, length: 5), [.foregroundColor: NSColor.blue]),
            // Emitted last but starting FIRST: sorting by start alone would let the
            // green above overwrite it, so the index has to carry the original order.
            (NSRange(location: 18, length: 6), [.foregroundColor: NSColor.orange])
        ]
        let indexed = applyIndexed(ranges, paragraphs: paragraphs, to: text)
        expectEquivalent(ranges, paragraphs: paragraphs, text: text)
        #expect(indexed.attribute(.foregroundColor, at: 22, effectiveRange: nil) as? NSColor == .orange)
        #expect(indexed.attribute(.foregroundColor, at: 27, effectiveRange: nil) as? NSColor == .green)
        #expect(indexed.attribute(.backgroundColor, at: 27, effectiveRange: nil) as? NSColor == .yellow)
    }

    @Test("Ranges entirely outside every paragraph are never applied")
    func outsideEveryParagraph() {
        let text = String(repeating: "z", count: 100)
        // A gap at 30..<60 and everything past 80 is unstyled territory.
        let paragraphs = [NSRange(location: 0, length: 30), NSRange(location: 60, length: 20)]
        let ranges: [StyledRange] = [
            (NSRange(location: 35, length: 10), [.foregroundColor: NSColor.red]),
            (NSRange(location: 85, length: 10), [.foregroundColor: NSColor.red]),
            (NSRange(location: 10, length: 5), [.foregroundColor: NSColor.blue])
        ]
        let indexed = applyIndexed(ranges, paragraphs: paragraphs, to: text)
        expectEquivalent(ranges, paragraphs: paragraphs, text: text)
        // The seed colour outside the paragraphs is untouched — proof nothing leaked.
        #expect(indexed.attribute(.foregroundColor, at: 40, effectiveRange: nil) as? NSColor == .magenta)
        #expect(indexed.attribute(.foregroundColor, at: 90, effectiveRange: nil) as? NSColor == .magenta)
    }

    @Test("Adjacent but non-overlapping ranges do not bleed across the seam")
    func adjacentNotOverlapping() {
        let text = String(repeating: "w", count: 60)
        let paragraphs = tiled(count: 6, size: 10)
        let ranges: [StyledRange] = (0..<6).map {
            (NSRange(location: $0 * 10, length: 10), [.foregroundColor: $0 % 2 == 0 ? NSColor.red : NSColor.blue])
        }
        expectEquivalent(ranges, paragraphs: paragraphs, text: text)
        // A range that ends exactly where the next paragraph starts.
        let touching: [StyledRange] = [
            (NSRange(location: 0, length: 10), [.foregroundColor: NSColor.red]),
            (NSRange(location: 10, length: 10), [.foregroundColor: NSColor.blue])
        ]
        expectEquivalent(touching, paragraphs: paragraphs, text: text)
    }

    @Test("Degenerate ranges behave exactly as they did")
    func degenerate() {
        let text = String(repeating: "v", count: 60)
        let paragraphs = tiled(count: 6, size: 10)
        let ranges: [StyledRange] = [
            (NSRange(location: 12, length: 0), [.foregroundColor: NSColor.red]),      // empty
            (NSRange(location: 20, length: 0), [.foregroundColor: NSColor.red]),      // empty on a boundary
            (NSRange(location: NSNotFound, length: 4), [.foregroundColor: NSColor.red]),
            (NSRange(location: 55, length: 999), [.foregroundColor: NSColor.green]),  // past the end
            (NSRange(location: 30, length: Int.max - 5), [.backgroundColor: NSColor.gray]),  // end overflows
            (NSRange(location: 4, length: 3), [.foregroundColor: NSColor.blue])
        ]
        expectEquivalent(ranges, paragraphs: paragraphs, text: text)
    }

    @Test("Unsorted, duplicated and nested paragraphs keep their given order")
    func nestedAndUnsortedParagraphs() {
        let text = String(repeating: "u", count: 100)
        // What a code block contributes: the whole block, then its fence lines — nested
        // inside it, and reached after it, so their `setAttributes` re-bases those chars.
        let paragraphs = [
            NSRange(location: 60, length: 20),
            NSRange(location: 20, length: 40),   // block
            NSRange(location: 20, length: 5),    // opening fence, nested
            NSRange(location: 54, length: 6),    // closing fence, nested
            NSRange(location: 0, length: 20)
        ]
        let ranges: [StyledRange] = [
            (NSRange(location: 20, length: 40), [.backgroundColor: NSColor.gray]),
            (NSRange(location: 22, length: 30), [.foregroundColor: NSColor.orange]),
            (NSRange(location: 18, length: 8), [.underlineStyle: 1]),
            (NSRange(location: 50, length: 20), [.foregroundColor: NSColor.purple])
        ]
        expectEquivalent(ranges, paragraphs: paragraphs, text: text)
    }

    @Test("Randomised overlap storms stay equivalent to the old loop")
    func randomisedEquivalence() {
        let length = 600
        let text = String(repeating: "m", count: length)
        let colors: [NSColor] = [.red, .green, .blue, .orange, .purple]
        // Deterministic generator: a failure must be reproducible from the seed.
        var seed: UInt64 = 0x9E3779B97F4A7C15
        func next(_ bound: Int) -> Int {
            seed ^= seed << 13; seed ^= seed >> 7; seed ^= seed << 17
            return Int(seed % UInt64(bound))
        }
        for round in 0..<40 {
            // Paragraph shapes: tiled (document restyle), a handful (keystroke), and
            // overlapping/unsorted ones the normalizer is allowed to hand through.
            var paragraphs: [NSRange]
            switch round % 4 {
            case 0:
                paragraphs = tiled(count: 40, size: 15)
            case 1:
                paragraphs = (0..<3).map { _ in
                    let location = next(length - 30)
                    return NSRange(location: location, length: next(30) + 1)
                }
            case 2:
                paragraphs = (0..<35).map { _ in
                    let location = next(length - 60)
                    return NSRange(location: location, length: next(60) + 1)
                }
            default:
                // Descending, plus a whole-document paragraph and one nested inside it:
                // the order the apply loop must keep is the given one, not the sorted one.
                paragraphs = tiled(count: 20, size: 15).reversed()
                paragraphs.append(NSRange(location: 0, length: length))
                paragraphs.append(NSRange(location: 30, length: 5))
            }
            var ranges: [StyledRange] = []
            for _ in 0..<150 {
                let location = next(length)
                let maxLength = length - location
                let rangeLength = maxLength == 0 ? 0 : next(min(maxLength, 40))
                var attrs: [NSAttributedString.Key: Any] = [.foregroundColor: colors[next(colors.count)]]
                if next(2) == 0 { attrs[.backgroundColor] = colors[next(colors.count)] }
                if next(3) == 0 { attrs[.underlineStyle] = next(2) }
                ranges.append((NSRange(location: location, length: rangeLength), attrs))
            }
            expectEquivalent(ranges, paragraphs: paragraphs, text: text, "round \(round)")
        }
    }

    @Test("The index reports exactly the overlaps the naive scan finds")
    func indexMatchesNaiveOverlaps() {
        var seed: UInt64 = 0xD1B54A32D192ED03
        func next(_ bound: Int) -> Int {
            seed ^= seed << 13; seed ^= seed >> 7; seed ^= seed << 17
            return Int(seed % UInt64(bound))
        }
        for _ in 0..<25 {
            let ranges: [StyledRange] = (0..<200).map { _ in
                (NSRange(location: next(400), length: next(30)), [.foregroundColor: NSColor.red])
            }
            var paragraphs = (0..<30).map { _ -> NSRange in
                NSRange(location: next(400), length: next(40) + 1)
            }
            paragraphs.append(NSRange(location: 380, length: 20))
            let index = TextStylingService.overlapIndex(styledRanges: ranges, paragraphs: paragraphs)
            for (paragraphIndex, paragraph) in paragraphs.enumerated() {
                let expected = ranges.indices.filter {
                    NSIntersectionRange(ranges[$0].range, paragraph).length > 0
                }
                let found = Array(index.members(for: paragraphIndex)).filter {
                    NSIntersectionRange(ranges[$0].range, paragraph).length > 0
                }
                #expect(found == expected)                       // same set, ascending order
                #expect(Array(index.members(for: paragraphIndex)).sorted() == Array(index.members(for: paragraphIndex)))
            }
        }
    }
}
#endif
