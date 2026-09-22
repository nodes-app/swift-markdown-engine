//
//  MarkdownStyler.swift
//  MarkdownEngine
//
//  Created by Luca Chen on 18.02.26.
//

// Applies the Markdown look (bold, links, code, headings, etc.). Most styling
// is now produced by the AST-native styler (`MarkdownASTStyler`); this type
// builds the `StylingContext` and runs the NSImage rendering passes that still
// consume tokens:
//   - MarkdownStyler+Latex.swift   (block + inline LaTeX rendering)
//   - MarkdownStyler+Images.swift  (image embeds / image links)
//   - MarkdownStyler+Tables.swift  (rendered tables)
import AppKit
import Foundation

// MARK: - Styling Context

extension MarkdownStyler {
    typealias IndexedToken = (index: Int, token: MarkdownToken)

    /// Per-kind token arrays (each with the token's index into the full array,
    /// for activeTokenIndices), built ONCE in the parse classification and
    /// reused across keystrokes. Lets the NSImage passes iterate a small,
    /// scope-sliced array instead of walking every document token per pass.
    struct ClassifiedStyleTokens {
        let inlineLatex: [IndexedToken]
        let blockLatex: [IndexedToken]
        let imageEmbed: [IndexedToken]
        let imageLink: [IndexedToken]
        let table: [IndexedToken]
        let code: [MarkdownToken]   // codeBlock + inlineCode, for isInsideCodeBlock checks
    }

    struct StylingContext {
        let nsText: NSString
        let tokens: [MarkdownToken]
        let codeTokens: [MarkdownToken]
        let activeTokenIndices: Set<Int>
        let baseFont: NSFont
        let layoutBridge: LayoutBridge?
        let baseDefaultLineHeight: CGFloat
        let codeBackgroundColor: NSColor
        let latexMarkerFont: NSFont
        let configuration: MarkdownEditorConfiguration
        let wikiLinkIDProvider: (NSRange) -> String?
        /// Union bounds of the restyle's paragraph scope; nil = whole document
        /// (initial load). Attribute application clips per paragraph anyway,
        /// so the NSImage passes can skip tokens wholly outside these bounds
        /// instead of walking every token in the document per keystroke.
        var scopeBounds: (lo: Int, hi: Int)? = nil
        /// Pre-classified per-kind token arrays; nil for direct callers (tests),
        /// which fall back to classifying `tokens` on demand.
        var classified: ClassifiedStyleTokens? = nil

        var services: MarkdownEditorServices { configuration.services }

        // Per-kind indexed arrays: the cached classification, or a one-off
        // classification of `tokens` when a direct caller passed none.
        var inlineLatexIndexed: [IndexedToken] { classified?.inlineLatex ?? Self.indexed(tokens, .inlineLatex) }
        var blockLatexIndexed: [IndexedToken] { classified?.blockLatex ?? Self.indexed(tokens, .blockLatex) }
        var imageEmbedIndexed: [IndexedToken] { classified?.imageEmbed ?? Self.indexed(tokens, .imageEmbed) }
        var imageLinkIndexed: [IndexedToken] { classified?.imageLink ?? Self.indexed(tokens, .imageLink) }
        var tableIndexed: [IndexedToken] { classified?.table ?? Self.indexed(tokens, .table) }

        static func indexed(_ tokens: [MarkdownToken], _ kind: MarkdownTokenKind) -> [IndexedToken] {
            tokens.enumerated().compactMap { $0.element.kind == kind ? ($0.offset, $0.element) : nil }
        }

        /// The slice of a location-sorted, non-overlapping per-kind array that
        /// intersects the restyle scope — binary-searched so out-of-scope
        /// tokens are never even visited. Whole array when scope is nil.
        func scoped(_ arr: [IndexedToken]) -> ArraySlice<IndexedToken> {
            guard let bounds = scopeBounds else { return arr[...] }
            return MarkdownStyler.scopedSlice(arr, lo: bounds.lo, hi: bounds.hi)
        }

        /// True when `range` lies entirely outside the restyle scope — its
        /// attributes would be clipped away at application time.
        func outsideScope(_ range: NSRange) -> Bool {
            guard let scopeBounds else { return false }
            return NSMaxRange(range) <= scopeBounds.lo || range.location >= scopeBounds.hi
        }

        /// True when iteration (over location-sorted tokens) is past the scope.
        func pastScope(_ range: NSRange) -> Bool {
            guard let scopeBounds else { return false }
            return range.location >= scopeBounds.hi
        }
    }

    /// Binary-searched slice of a location-sorted, non-overlapping per-kind
    /// array whose tokens intersect `[lo, hi)` — tokens outside are never
    /// visited. Shared by the styler's scope culling and the coordinator's
    /// edit-scoped candidate collection (which used to walk each array
    /// linearly from the document head to the edit).
    static func scopedSlice(_ arr: [IndexedToken], lo bound: Int, hi upper: Int) -> ArraySlice<IndexedToken> {
        var lo = 0, hi = arr.count
        while lo < hi {                                   // first NSMaxRange > bound
            let m = (lo + hi) / 2
            if NSMaxRange(arr[m].token.range) > bound { hi = m } else { lo = m + 1 }
        }
        let start = lo
        hi = arr.count
        while lo < hi {                                   // first location >= upper
            let m = (lo + hi) / 2
            if arr[m].token.range.location >= upper { hi = m } else { lo = m + 1 }
        }
        return arr[start..<lo]
    }
}

typealias StyledRange = (range: NSRange, attributes: [NSAttributedString.Key: Any])

// MARK: - Public API

enum MarkdownStyler {

    /// Collapses styler output into non-overlapping runs, ascending, so a caller can
    /// write each character range to the text storage exactly once.
    ///
    /// The styler emits ranges pass by pass, so they arrive unordered and heavily
    /// overlapping. Applying them with one `addAttribute` per key per range mutates
    /// the storage once per pair — 89,916 times on a 346k-char note — and every
    /// mutation re-splits the attribute-run array, so the cost of a single call grows
    /// with the runs already present: measured 0.54µs/call on a 437-char note against
    /// 213µs/call on the big one. That quadratic was 19.1s of a 21s open. Writing
    /// left to right instead only ever splits the trailing run.
    ///
    /// Semantics are identical to the loop it replaces: later ranges win per key, and
    /// `base` fills what no range covers (the caller applies it to the whole document
    /// first, so each returned run must carry it too — `setAttributes` replaces).
    static func flattenedRuns(
        _ ranges: [StyledRange],
        base: [NSAttributedString.Key: Any],
        documentLength: Int
    ) -> [StyledRange] {
        // (position, isStart, emission index). Ends sort before starts at the same
        // position so a range ending where the next begins doesn't briefly overlap it.
        var events: [(pos: Int, isStart: Bool, idx: Int)] = []
        events.reserveCapacity(ranges.count * 2)
        for (i, styled) in ranges.enumerated() {
            let r = styled.range
            guard r.location != NSNotFound, r.location >= 0, r.length > 0,
                  NSMaxRange(r) <= documentLength else { continue }
            events.append((r.location, true, i))
            events.append((NSMaxRange(r), false, i))
        }
        guard !events.isEmpty else { return [] }
        events.sort { a, b in
            if a.pos != b.pos { return a.pos < b.pos }
            if a.isStart != b.isStart { return !a.isStart }
            return a.idx < b.idx
        }

        var runs: [StyledRange] = []
        runs.reserveCapacity(min(events.count, 4096))
        // Emission indices of the ranges covering the current position, kept ascending
        // so merging them in order reproduces "later range wins".
        var active: [Int] = []
        var cursor = events[0].pos
        var i = 0
        while i < events.count {
            let pos = events[i].pos
            if pos > cursor, !active.isEmpty {
                var attrs = base
                for idx in active {
                    attrs.merge(ranges[idx].attributes) { _, newer in newer }
                }
                let run = NSRange(location: cursor, length: pos - cursor)
                // Adjacent runs frequently carry identical attributes — one styling
                // pass emits a separate range per character — so coalesce before the
                // write instead of paying a storage mutation per character.
                if let last = runs.last, NSMaxRange(last.range) == run.location,
                   (last.attributes as NSDictionary).isEqual(to: attrs) {
                    runs[runs.count - 1].range.length += run.length
                } else {
                    runs.append((run, attrs))
                }
            }
            while i < events.count, events[i].pos == pos {
                let event = events[i]
                if event.isStart {
                    let slot = active.firstIndex { $0 > event.idx } ?? active.count
                    active.insert(event.idx, at: slot)
                } else if let slot = active.firstIndex(of: event.idx) {
                    active.remove(at: slot)
                }
                i += 1
            }
            cursor = pos
        }
        return runs
    }

    static func styleAttributes(
        text: String,
        fontName: String,
        fontSize: CGFloat,
        layoutBridge: LayoutBridge? = nil,
        caretLocation: Int,
        selection: NSRange? = nil,
        activeTokenIndices: Set<Int>,
        wikiLinkIDProvider: @escaping (NSRange) -> String? = { _ in nil },
        precomputedTokens: [MarkdownToken]? = nil,
        classified: ClassifiedStyleTokens? = nil,
        precomputedBlocks: [Block]? = nil,
        scopedRanges: [NSRange]? = nil,
        configuration: MarkdownEditorConfiguration = .default
    ) -> [StyledRange] {
        let ctx = makeStylingContext(
            text: text,
            fontName: fontName,
            fontSize: fontSize,
            layoutBridge: layoutBridge,
            activeTokenIndices: activeTokenIndices,
            wikiLinkIDProvider: wikiLinkIDProvider,
            precomputedTokens: precomputedTokens,
            classified: classified,
            scopedRanges: scopedRanges,
            configuration: configuration
        )

        var result: [StyledRange] = []
        // AST-native styler handles everything but NSImage rendering (incl. the composition fixes).
        let astT0 = DispatchTime.now().uptimeNanoseconds
        result += MarkdownASTStyler.styleAttributes(
            text: text, fontName: fontName, fontSize: fontSize,
            caretLocation: caretLocation, selection: selection, wikiLinkIDProvider: wikiLinkIDProvider,
            scopedRanges: scopedRanges, precomputedBlocks: precomputedBlocks,
            configuration: configuration
        )
        let astMs = Double(DispatchTime.now().uptimeNanoseconds - astT0) / 1_000_000
        // NSImage rendering reuses the existing, proven machinery.
        let imgT0 = DispatchTime.now().uptimeNanoseconds
        result += styleBlockLatex(ctx)
        result += styleInlineLatex(ctx)
        result += styleImageEmbeds(ctx)
        result += styleImageLinks(ctx)
        let imgMs = Double(DispatchTime.now().uptimeNanoseconds - imgT0) / 1_000_000
        result += styleTables(ctx)
        PerfTrace.note { "  styleAttributes: ast=\(String(format: "%.2f", astMs))ms latex+img4=\(String(format: "%.2f", imgMs))ms styledRanges=\(result.count)" }
        return result
    }

    /// Width changes only affect table rasters and their collapsed-block
    /// attributes. Bypassing the generic AST and unrelated image passes keeps
    /// an all-table resize linear in the number of tables.
    static func styleTableAttributes(
        text: String,
        fontName: String,
        fontSize: CGFloat,
        layoutBridge: LayoutBridge? = nil,
        activeTokenIndices: Set<Int>,
        wikiLinkIDProvider: @escaping (NSRange) -> String? = { _ in nil },
        precomputedTokens: [MarkdownToken]? = nil,
        classified: ClassifiedStyleTokens? = nil,
        scopedRanges: [NSRange]? = nil,
        configuration: MarkdownEditorConfiguration = .default
    ) -> [StyledRange] {
        let ctx = makeStylingContext(
            text: text,
            fontName: fontName,
            fontSize: fontSize,
            layoutBridge: layoutBridge,
            activeTokenIndices: activeTokenIndices,
            wikiLinkIDProvider: wikiLinkIDProvider,
            precomputedTokens: precomputedTokens,
            classified: classified,
            scopedRanges: scopedRanges,
            configuration: configuration
        )
        return styleTables(ctx)
    }

    private static func makeStylingContext(
        text: String,
        fontName: String,
        fontSize: CGFloat,
        layoutBridge: LayoutBridge?,
        activeTokenIndices: Set<Int>,
        wikiLinkIDProvider: @escaping (NSRange) -> String?,
        precomputedTokens: [MarkdownToken]?,
        classified: ClassifiedStyleTokens?,
        scopedRanges: [NSRange]?,
        configuration: MarkdownEditorConfiguration
    ) -> StylingContext {
        let tokens = precomputedTokens ?? MarkdownTokenizer.parseTokensViaAST(
            in: text,
            registry: configuration.extensionRegistry
        )
        let scopeBounds: (lo: Int, hi: Int)? = scopedRanges.flatMap { ranges in
            let valid = ranges.filter {
                $0.location != NSNotFound && $0.length > 0
            }
            guard let lo = valid.map(\.location).min(),
                  let hi = valid.map({ NSMaxRange($0) }).max() else {
                return nil
            }
            return (lo, hi)
        }
        let codeTokens = classified?.code ?? tokens.filter {
            $0.kind == .codeBlock || $0.kind == .inlineCode
        }
        let baseFont = NSFont(name: fontName, size: fontSize)
            ?? NSFont.systemFont(ofSize: fontSize)
        let baseDefaultLineHeight = ceil(
            layoutBridge?.defaultLineHeight(for: baseFont)
                ?? (baseFont.ascender - baseFont.descender + baseFont.leading)
        )
        let hiddenMarkerSize = configuration.markers.hiddenMarkerFontSize
        return StylingContext(
            nsText: text as NSString,
            tokens: tokens,
            codeTokens: codeTokens,
            activeTokenIndices: activeTokenIndices,
            baseFont: baseFont,
            layoutBridge: layoutBridge,
            baseDefaultLineHeight: baseDefaultLineHeight,
            codeBackgroundColor: configuration.services.syntaxHighlighter
                .backgroundColor(),
            latexMarkerFont: NSFont(name: fontName, size: hiddenMarkerSize)
                ?? NSFont.systemFont(ofSize: hiddenMarkerSize),
            configuration: configuration,
            wikiLinkIDProvider: wikiLinkIDProvider,
            scopeBounds: scopeBounds,
            classified: classified
        )
    }
}

// MARK: - Shared helpers used by multiple styling extensions

extension MarkdownStyler {

    static func appendSecondaryMarkers(
        for token: MarkdownToken,
        to attrs: inout [StyledRange],
        theme: MarkdownEditorTheme
    ) {
        token.markerRanges.forEach {
            attrs.append(($0, [.foregroundColor: theme.mutedText]))
        }
    }

    enum RenderedStandaloneBlockMode {
        case collapsedSource(markerTexts: [String])
        case visibleSource(imageGap: CGFloat)
        /// Wide-table mode: anchor reserves container width, line gains scroller strip, tagged by sourceID.
        case collapsedSourceScrollable(
            markerTexts: [String],
            displayWidth: CGFloat,
            sourceID: Int
        )
    }

    static func appendRenderedStandaloneBlock(
        for token: MarkdownToken,
        rawContent: String,
        image: NSImage,
        imageBounds: CGRect,
        paragraphSpacingBefore: CGFloat,
        paragraphSpacing: CGFloat,
        alignment: NSTextAlignment,
        mode: RenderedStandaloneBlockMode,
        restyleOnWidthChange: Bool = false,
        ctx: StylingContext,
        attrs: inout [StyledRange]
    ) -> Bool {
        guard let paraRange = token.standaloneParagraphRange(in: ctx.nsText) else { return false }

        let para = NSMutableParagraphStyle()
        let baseLineHeight = layoutBridgeDefaultLineHeight(for: ctx.baseFont, using: ctx.layoutBridge)
        para.paragraphSpacingBefore = max(para.paragraphSpacingBefore, paragraphSpacingBefore)
        para.alignment = alignment
        let widthChangeAnchorAttrs: [NSAttributedString.Key: Any] = restyleOnWidthChange
            ? [.scrollableBlockFullRange: NSValue(range: paraRange)]
            : [:]

        switch mode {
        case .collapsedSource(let markerTexts):
            emitCollapsedAttrs(
                token: token,
                rawContent: rawContent,
                image: image,
                imageBounds: imageBounds,
                paragraphSpacing: paragraphSpacing,
                para: para,
                paraRange: paraRange,
                advanceWidth: imageBounds.width,
                neededLineHeight: imageBounds.height,
                extraAnchorAttrs: widthChangeAnchorAttrs,
                markerTexts: markerTexts,
                ctx: ctx,
                attrs: &attrs
            )

        case .collapsedSourceScrollable(let markerTexts, let displayWidth, let sourceID):
            let scrollerStrip = MarkdownTextLayoutFragment.scrollableBlockScrollerStrip
            let totalHeight = imageBounds.height + scrollerStrip
            var anchorAttrs = widthChangeAnchorAttrs
            anchorAttrs[.scrollableBlockNaturalWidth] = imageBounds.width
            anchorAttrs[.scrollableBlockSourceID] = sourceID
            anchorAttrs[.scrollableBlockTotalHeight] = totalHeight
            emitCollapsedAttrs(
                token: token,
                rawContent: rawContent,
                image: image,
                imageBounds: imageBounds,
                paragraphSpacing: paragraphSpacing,
                para: para,
                paraRange: paraRange,
                advanceWidth: displayWidth,
                neededLineHeight: totalHeight,
                extraAnchorAttrs: anchorAttrs,
                markerTexts: markerTexts,
                ctx: ctx,
                attrs: &attrs
            )

        case .visibleSource(let imageGap):
            para.minimumLineHeight = max(para.minimumLineHeight, baseLineHeight)
            para.maximumLineHeight = max(para.maximumLineHeight, baseLineHeight)
            para.paragraphSpacing = max(para.paragraphSpacing, imageBounds.height + imageGap + paragraphSpacing)

            attrs.append((paraRange, [.paragraphStyle: para]))
            attrs.append((token.range, [
                .latexImage: image,
                .latexBounds: NSValue(rect: imageBounds),
                .latexIsBlock: true,
                .latexBlockOffsetY: baseLineHeight + imageGap
            ]))
            appendSecondaryMarkers(for: token, to: &attrs, theme: ctx.configuration.theme)
        }

        return true
    }

    /// Per-character kern that collapses a hidden run to zero width.
    ///
    /// `.kern` is applied to EVERY character in the range, so a run of `n`
    /// characters ends up `width + n * kern` wide — feeding it the whole run's
    /// width made a long run `(n - 1)` widths too NEGATIVE. AppKit clamps most
    /// such lines to zero, but a line holding a composed character sequence
    /// (e.g. `z` + U+0304) instead laid out at x = +1783 with width -1783,
    /// which poisoned `usageBoundsForTextContainer` for the whole document
    /// (measured -1778…695 instead of 5…695 on a 14-line table).
    static func hiddenRunKern(_ text: String, font: NSFont) -> CGFloat {
        let count = max(1, (text as NSString).length)
        return HeadingHelpers.textWidth(text, font: font) / CGFloat(count)
    }

    /// Shared body for collapsed-source modes; hides raw source, plants image on anchor.
    private static func emitCollapsedAttrs(
        token: MarkdownToken,
        rawContent: String,
        image: NSImage,
        imageBounds: CGRect,
        paragraphSpacing: CGFloat,
        para: NSMutableParagraphStyle,
        paraRange: NSRange,
        advanceWidth: CGFloat,
        neededLineHeight: CGFloat,
        extraAnchorAttrs: [NSAttributedString.Key: Any],
        markerTexts: [String],
        ctx: StylingContext,
        attrs: inout [StyledRange]
    ) {
        let baseLineHeight = layoutBridgeDefaultLineHeight(for: ctx.baseFont, using: ctx.layoutBridge)
        let resolved = max(para.minimumLineHeight, neededLineHeight, baseLineHeight)
        para.minimumLineHeight = resolved
        para.maximumLineHeight = max(para.maximumLineHeight, resolved)
        para.paragraphSpacing = max(para.paragraphSpacing, paragraphSpacing)
        para.lineBreakMode = .byClipping

        let collapsedPara = NSMutableParagraphStyle()
        collapsedPara.maximumLineHeight = 1
        collapsedPara.paragraphSpacing = 0
        collapsedPara.paragraphSpacingBefore = 0

        let leadingWhitespaceUnits = rawContent.utf16.prefix { codeUnit in
            guard let scalar = UnicodeScalar(UInt32(codeUnit)) else { return false }
            return CharacterSet.whitespacesAndNewlines.contains(scalar)
        }.count
        let contentEnd = NSMaxRange(token.contentRange)
        let anchorLocation = min(token.contentRange.location + leadingWhitespaceUnits, contentEnd - 1)

        var paragraphAttributes: [StyledRange] = []
        ctx.nsText.enumerateSubstrings(in: paraRange, options: .byParagraphs) { _, _, enclosingRange, _ in
            if NSLocationInRange(anchorLocation, enclosingRange) {
                paragraphAttributes.append((enclosingRange, [.paragraphStyle: para]))
            } else {
                paragraphAttributes.append((enclosingRange, [.paragraphStyle: collapsedPara]))
            }
        }
        attrs.append(contentsOf: paragraphAttributes)

        if leadingWhitespaceUnits > 0 {
            let leadingRange = NSRange(location: token.contentRange.location, length: leadingWhitespaceUnits)
            let leadingText = ctx.nsText.substring(with: leadingRange)
            attrs.append((leadingRange, [
                .foregroundColor: NSColor.clear,
                .font: ctx.latexMarkerFont,
                .kern: -hiddenRunKern(leadingText, font: ctx.latexMarkerFont)
            ]))
        }

        let anchorRange = NSRange(location: anchorLocation, length: 1)
        let anchorChar = ctx.nsText.substring(with: anchorRange)
        var anchorAttrs: [NSAttributedString.Key: Any] = [
            .latexImage: image,
            .latexBounds: NSValue(rect: imageBounds),
            .latexIsBlock: true,
            .foregroundColor: NSColor.clear,
            .font: ctx.latexMarkerFont,
            .kern: advanceWidth - HeadingHelpers.textWidth(anchorChar, font: ctx.latexMarkerFont)
        ]
        for (key, value) in extraAnchorAttrs { anchorAttrs[key] = value }
        attrs.append((anchorRange, anchorAttrs))

        let trailingStart = anchorLocation + 1
        let trailingLength = contentEnd - trailingStart
        if trailingLength > 0 {
            let trailingRange = NSRange(location: trailingStart, length: trailingLength)
            let trailingText = ctx.nsText.substring(with: trailingRange)
            attrs.append((trailingRange, [
                .foregroundColor: NSColor.clear,
                .font: ctx.latexMarkerFont,
                .kern: -hiddenRunKern(trailingText, font: ctx.latexMarkerFont)
            ]))
        }

        for (index, markerRange) in token.markerRanges.enumerated() {
            let markerText = markerTexts.indices.contains(index)
                ? markerTexts[index]
                : ctx.nsText.substring(with: markerRange)
            attrs.append((markerRange, [
                .foregroundColor: NSColor.clear,
                .font: ctx.latexMarkerFont,
                .kern: -hiddenRunKern(markerText, font: ctx.latexMarkerFont)
            ]))
        }

        let preTokenLength = token.range.location - paraRange.location
        if preTokenLength > 0 {
            let preTokenRange = NSRange(location: paraRange.location, length: preTokenLength)
            let preTokenText = ctx.nsText.substring(with: preTokenRange)
            attrs.append((preTokenRange, [
                .foregroundColor: NSColor.clear,
                .font: ctx.latexMarkerFont,
                .kern: -hiddenRunKern(preTokenText, font: ctx.latexMarkerFont)
            ]))
        }
    }
}

// MARK: - Whole-document & inline-only styling kept inline (small helpers)

extension MarkdownStyler {

    /// Line range if `location` is on a thematic-break line (3+ `-`/`*`/`_`), else nil; drives HR restyle.
    static func hrLineRange(at location: Int, in text: String) -> NSRange? {
        let nsText = text as NSString
        let safeLoc = max(0, min(location, nsText.length))
        let lineRange = nsText.lineRange(for: NSRange(location: safeLoc, length: 0))
        let line = nsText.substring(with: lineRange)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard line.range(
            of: #"^[ \t]*(-{3,}|\*{3,}|_{3,})[ \t]*$"#,
            options: .regularExpression
        ) != nil else {
            return nil
        }
        return lineRange
    }
}
