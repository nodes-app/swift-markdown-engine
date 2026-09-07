#if os(macOS)
//
//  TextStylingService.swift
//  MarkdownEngine
//
//  Created by Luca Chen on 18.02.26.
//

// Applies base text styling and refreshes only changed sections so editing
// stays smooth while Markdown formatting updates.
import AppKit
import Foundation

struct TextStylingService {
    static func makeBaseTypingAttributes(
        font: NSFont,
        paragraphStyle: NSParagraphStyle,
        theme: MarkdownEditorTheme = .default
    ) -> [NSAttributedString.Key: Any] {
        [
            .font: font,
            .foregroundColor: theme.bodyText,
            .paragraphStyle: paragraphStyle
        ]
    }

    static func makeBaseFontAndStyle(
        fontName: String,
        fontSize: CGFloat,
        layoutBridge: LayoutBridge? = nil,
        configuration: MarkdownEditorConfiguration = .default
    ) -> (font: NSFont, style: NSMutableParagraphStyle) {
        let baseFont = NSFont(name: fontName, size: fontSize) ?? NSFont.systemFont(ofSize: fontSize)
        let defaultLineHeight = layoutBridgeDefaultLineHeight(for: baseFont, using: layoutBridge)
        let paragraph = NSMutableParagraphStyle()
        paragraph.minimumLineHeight = ceil(defaultLineHeight) + configuration.paragraph.lineHeightExtraSpacing
        paragraph.lineSpacing = 0
        let baseParagraphSpacing = ceil(defaultLineHeight * configuration.paragraph.spacingFactor)
        paragraph.paragraphSpacing = baseParagraphSpacing
        paragraph.paragraphSpacingBefore = 0
        paragraph.lineBreakMode = .byWordWrapping
        // 24 explicit tab stops at indentPerLevel intervals, then natural wrap.
        let perLevel = configuration.lists.indentPerLevel
        paragraph.tabStops = (1...24).map { NSTextTab(textAlignment: .left, location: CGFloat($0) * perLevel) }
        paragraph.defaultTabInterval = 0
        return (baseFont, paragraph)
    }

    static func restyle(
        textView: NSTextView,
        layoutBridge: LayoutBridge?,
        paragraphCandidates: [NSRange],
        baseFont: NSFont,
        paragraphStyle: NSMutableParagraphStyle,
        caretLocation: Int,
        selection: NSRange? = nil,
        activeTokenIndices: Set<Int>,
        wikiLinkIDProvider: @escaping (NSRange) -> String?,
        precomputedTokens: [MarkdownToken]? = nil,
        classified: MarkdownStyler.ClassifiedStyleTokens? = nil,
        precomputedBlocks: [Block]? = nil,
        configuration: MarkdownEditorConfiguration = .default
    ) {
        let paragraphs = normalize(paragraphCandidates)

        textView.typingAttributes = makeBaseTypingAttributes(
            font: baseFont,
            paragraphStyle: paragraphStyle,
            theme: configuration.theme
        )

        guard !paragraphs.isEmpty else {
            textView.setNeedsDisplay(textView.visibleRect)
            return
        }

        let styleT0 = DispatchTime.now().uptimeNanoseconds
        let styledRanges = MarkdownStyler.styleAttributes(
            text: textView.string,
            fontName: baseFont.fontName,
            fontSize: baseFont.pointSize,
            layoutBridge: layoutBridge,
            caretLocation: caretLocation,
            selection: selection,
            activeTokenIndices: activeTokenIndices,
            wikiLinkIDProvider: wikiLinkIDProvider,
            precomputedTokens: precomputedTokens,
            classified: classified,
            precomputedBlocks: precomputedBlocks,
            scopedRanges: paragraphs,
            configuration: configuration
        )
        let styleMs = Double(DispatchTime.now().uptimeNanoseconds - styleT0) / 1_000_000

        let spellT0 = DispatchTime.now().uptimeNanoseconds
        let spellingDisabledRanges = styledRanges.compactMap { (range, attrs) -> NSRange? in
            attrs[.spellingState] as? Int == 0 ? range : nil
        }

        // Remove existing spelling markers before reapplying disabled ranges.
        for disabledRange in spellingDisabledRanges {
            layoutBridge?.removeTemporaryAttribute(.spellingState, forCharacterRange: disabledRange)
        }

        textView.textStorage?.beginEditing()
        for disabledRange in spellingDisabledRanges {
            textView.textStorage?.addAttribute(.spellingState, value: 0, range: disabledRange)
        }
        let spellMs = Double(DispatchTime.now().uptimeNanoseconds - spellT0) / 1_000_000
        let attrT0 = DispatchTime.now().uptimeNanoseconds
        applyStyledRanges(
            styledRanges,
            paragraphs: paragraphs,
            baseAttributes: [
                .font: baseFont,
                .foregroundColor: configuration.theme.bodyText,
                .paragraphStyle: paragraphStyle
            ],
            to: textView.textStorage
        )
        textView.textStorage?.endEditing()
        let attrMs = Double(DispatchTime.now().uptimeNanoseconds - attrT0) / 1_000_000
        // No ensureLayout here:
        let evlT0 = DispatchTime.now().uptimeNanoseconds
        textView.setNeedsDisplay(textView.visibleRect)
        (textView as? NativeTextView)?.ensureVisibleLayout()
        let evlMs = Double(DispatchTime.now().uptimeNanoseconds - evlT0) / 1_000_000
        PerfTrace.note { "  restyle split: styleAttrs=\(String(format: "%.2f", styleMs))ms spell=\(String(format: "%.2f", spellMs))ms attrApply(paras=\(paragraphs.count))=\(String(format: "%.2f", attrMs))ms ensureVisLayout=\(String(format: "%.2f", evlMs))ms" }
    }

    /// Lays the base attributes down per paragraph and paints the styled ranges over
    /// them, clipped to the paragraph. Order is load-bearing twice: paragraphs run in
    /// the given order (paragraphs may nest, and the later `setAttributes` wipes what an
    /// earlier one painted), and inside a paragraph the ranges run in their original
    /// order (repeated `addAttribute` is what makes a later range win per key).
    static func applyStyledRanges(
        _ styledRanges: [StyledRange],
        paragraphs: [NSRange],
        baseAttributes: [NSAttributedString.Key: Any],
        to storage: NSMutableAttributedString?,
        minimumParagraphsForIndex: Int = 32
    ) {
        // Rescanning every range per paragraph is paragraphs × ranges — fine for the 1-3
        // paragraphs a keystroke restyles, 10.8s of main thread for a selection-wide
        // restyle (7,714 paragraphs × 33k ranges on the 346k note). Not the open path:
        // that one passes a single full-document paragraph. The index sorts once instead
        // — 76ms there — but loses under ~32 paragraphs, hence the floor.
        let index = paragraphs.count >= minimumParagraphsForIndex
            ? overlapIndex(styledRanges: styledRanges, paragraphs: paragraphs)
            : nil
        let everyRange: [Int] = index == nil ? Array(styledRanges.indices) : []

        for (paragraphIndex, paragraph) in paragraphs.enumerated() {
            storage?.setAttributes(baseAttributes, range: paragraph)
            storage?.removeAttribute(.link, range: paragraph)
            for rangeIndex in index?.members(for: paragraphIndex) ?? everyRange[...] {
                let (range, attrs) = styledRanges[rangeIndex]
                let clippedRange = NSIntersectionRange(range, paragraph)
                guard clippedRange.length > 0 else { continue }
                for (key, value) in attrs {
                    storage?.addAttribute(key, value: value, range: clippedRange)
                }
            }
        }
    }

    /// Which styled ranges reach which paragraph, in original range order per paragraph.
    struct OverlapIndex {
        let offsets: [Int]
        let indices: [Int]

        func members(for paragraph: Int) -> ArraySlice<Int> {
            indices[offsets[paragraph]..<offsets[paragraph + 1]]
        }
    }

    /// One sweep over both lists in ascending start order, so a paragraph only visits
    /// ranges that can still reach it.
    static func overlapIndex(styledRanges: [StyledRange], paragraphs: [NSRange]) -> OverlapIndex {
        var offsets = [Int](repeating: 0, count: paragraphs.count + 1)
        guard !paragraphs.isEmpty, !styledRanges.isEmpty else {
            return OverlapIndex(offsets: offsets, indices: [])
        }

        // Bounds unpacked once so the sort and the sweep walk two flat Int arrays instead
        // of striding over the attribute dictionaries. Degenerate ranges need no special
        // case: the end saturates instead of overflowing, and an NSNotFound location
        // starts past every paragraph, so both fall out of the tests below exactly as
        // `NSIntersectionRange` drops them.
        var starts = [Int](repeating: 0, count: styledRanges.count)
        var ends = [Int](repeating: 0, count: styledRanges.count)
        for index in styledRanges.indices {
            let range = styledRanges[index].range
            starts[index] = range.location
            let (end, overflowed) = range.location.addingReportingOverflow(range.length)
            ends[index] = overflowed ? Int.max : end
        }

        let rangesByStart = Array(styledRanges.indices).sorted {
            starts[$0] == starts[$1] ? $0 < $1 : starts[$0] < starts[$1]
        }
        let paragraphsByStart = Array(paragraphs.indices).sorted {
            paragraphs[$0].location == paragraphs[$1].location
                ? $0 < $1
                : paragraphs[$0].location < paragraphs[$1].location
        }

        var pairs: [(paragraph: Int, range: Int)] = []
        pairs.reserveCapacity(styledRanges.count)
        var active: [Int] = []
        var cursor = 0

        for paragraphIndex in paragraphsByStart {
            let paragraph = paragraphs[paragraphIndex]
            let paragraphStart = paragraph.location
            let (end, overflowed) = paragraphStart.addingReportingOverflow(paragraph.length)
            let paragraphEnd = overflowed ? Int.max : end

            while cursor < rangesByStart.count, starts[rangesByStart[cursor]] < paragraphEnd {
                active.append(rangesByStart[cursor])
                cursor += 1
            }
            // Paragraphs are visited by ascending start, so a range ending at or before
            // this start can never reach a later paragraph either — dropping it for good
            // is what keeps the sweep linear. A range starting past this paragraph's end
            // is only skipped: a later, longer paragraph can still contain it.
            var kept = 0
            for slot in 0..<active.count {
                let rangeIndex = active[slot]
                guard ends[rangeIndex] > paragraphStart else { continue }
                active[kept] = rangeIndex
                kept += 1
                if starts[rangeIndex] < paragraphEnd {
                    pairs.append((paragraphIndex, rangeIndex))
                }
            }
            active.removeLast(active.count - kept)
        }

        for pair in pairs { offsets[pair.paragraph + 1] += 1 }
        for index in 1...paragraphs.count { offsets[index] += offsets[index - 1] }
        var indices = [Int](repeating: 0, count: pairs.count)
        var fill = offsets
        for pair in pairs {
            indices[fill[pair.paragraph]] = pair.range
            fill[pair.paragraph] += 1
        }
        // The sweep collects by start; the apply loop needs the original emission order.
        for paragraphIndex in paragraphs.indices
        where offsets[paragraphIndex + 1] - offsets[paragraphIndex] > 1 {
            indices[offsets[paragraphIndex]..<offsets[paragraphIndex + 1]].sort()
        }
        return OverlapIndex(offsets: offsets, indices: indices)
    }

    private static func normalize(_ candidates: [NSRange]) -> [NSRange] {
        // Exact-duplicate drop in one pass (was O(n²) via contains); order and
        // overlapping-but-unequal ranges are preserved exactly as before.
        var seen = Set<Int>()
        seen.reserveCapacity(candidates.count)
        var result: [NSRange] = []
        for candidate in candidates where candidate.location != NSNotFound && candidate.length > 0 {
            let key = candidate.location &* 1_000_003 &+ candidate.length
            if seen.insert(key).inserted { result.append(candidate) }
        }
        return result
    }

    /// Convert an NSRange into an NSTextRange for use with NSTextLayoutManager.
    static func textRange(from range: NSRange, in contentStorage: NSTextContentStorage) -> NSTextRange? {
        let docStart = contentStorage.documentRange.location
        guard let start = contentStorage.location(docStart, offsetBy: range.location),
              let end = contentStorage.location(start, offsetBy: range.length) else {
            return nil
        }
        return NSTextRange(location: start, end: end)
    }
}
#endif
