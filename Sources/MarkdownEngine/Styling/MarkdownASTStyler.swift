//
//  MarkdownASTStyler.swift
//  MarkdownEngine
//
//  Phase 2.5 — the AST-native styler. Walks the document AST and emits
//  [StyledRange], COMPOSING attributes on descent: a heading sets a large bold
//  font, descending into bold adds the bold trait (keeping the size), into
//  italic adds italic — so nested/combined inline styles stack instead of
//  overwriting each other (the flaw in the flat 18-pass styler, e.g. the
//  shrinking bold in `# **n*o*des**`).
//
//  Built incrementally behind the existing styler; not wired until complete
//  and visually verified. Covered so far: heading/paragraph/blockquote blocks;
//  inline emphasis (font composition), strikethrough, inline code, markdown
//  links, wiki links. Still TODO: images, image embeds, inline LaTeX, escapes,
//  autolinks, marker-shrinking, paragraph styles, code/table/latex blocks,
//  bullets, task checkboxes, horizontal rules.
//

import AppKit
import Foundation

enum MarkdownASTStyler {

    static func styleAttributes(
        text: String,
        fontName: String,
        fontSize: CGFloat,
        caretLocation: Int = -1,
        selection: NSRange? = nil,
        wikiLinkIDProvider: @escaping (NSRange) -> String? = { _ in nil },
        scopedRanges: [NSRange]? = nil,
        precomputedBlocks: [Block]? = nil,
        configuration: MarkdownEditorConfiguration = .default
    ) -> [StyledRange] {
        let baseFont = NSFont(name: fontName, size: fontSize) ?? .systemFont(ofSize: fontSize)
        let baseLineHeight = ceil(baseFont.ascender - baseFont.descender + baseFont.leading)
        let baseParagraphSpacing = ceil(baseLineHeight * configuration.paragraph.spacingFactor)
        let codeFontSize = round(fontSize * configuration.codeBlock.fontSizeScale)
        let hiddenSize = configuration.markers.hiddenMarkerFontSize
        let ns = text as NSString
        let codeFont = configuration.services.syntaxHighlighter.codeFont(size: codeFontSize)
        let codeLineHeight = ceil(codeFont.ascender - codeFont.descender + codeFont.leading)
        let codePara = NSMutableParagraphStyle()
        codePara.lineBreakMode = .byCharWrapping
        codePara.lineSpacing = 0
        codePara.paragraphSpacingBefore = configuration.codeBlock.paragraphSpacing
        codePara.paragraphSpacing = configuration.codeBlock.paragraphSpacing
        codePara.headIndent = configuration.codeBlock.horizontalIndent
        codePara.firstLineHeadIndent = configuration.codeBlock.horizontalIndent
        codePara.tailIndent = -configuration.codeBlock.horizontalIndent
        codePara.minimumLineHeight = codeLineHeight
        codePara.maximumLineHeight = codeLineHeight
        // precomputed=0 ⇒ the document is parsed a SECOND time here (the rebuild already parsed it).
        // Ahead of `ctx` because the ordered-list display numbers are derived from these blocks.
        let blocks = DocumentAST.parse(text, scopedRanges: scopedRanges, precomputedBlocks: precomputedBlocks,
                                       registry: configuration.extensionRegistry)
        let ctx = Ctx(
            ns: ns,
            fontName: fontName,
            baseFont: baseFont,
            baseLineHeight: baseLineHeight,
            baseParagraphSpacing: baseParagraphSpacing,
            codeFont: codeFont,
            codeBackground: configuration.services.syntaxHighlighter.backgroundColor(),
            codeParagraphStyle: codePara,
            inlineMarkerFont: NSFont(name: fontName, size: hiddenSize) ?? .systemFont(ofSize: hiddenSize),
            caret: caretLocation,
            selection: selection,
            config: configuration,
            extensionsByID: configuration.extensionsByID,
            wikiLinkID: wikiLinkIDProvider,
            scopedRanges: scopedRanges,
            orderedDisplayNumbers: computeOrderedDisplayNumbers(blocks: blocks, ns: ns)
        )
        var attrs: [StyledRange] = []
        for block in blocks where ctx.inScope(block.range) {
            styleBlock(block, font: baseFont, ctx: ctx, into: &attrs)
        }
        shrinkInactiveMarkers(in: blocks, ctx: ctx, into: &attrs)

        // Text/regex passes (AST-agnostic); AST code ranges drive the "skip inside code" checks.
        let codeRanges = collectCodeRanges(in: blocks)
        let checkboxRanges = collectCheckboxRanges(in: blocks)
        let linkRanges = collectLinkRanges(in: blocks)
        styleAutoLinks(ctx: ctx, codeRanges: codeRanges, linkRanges: linkRanges, into: &attrs)
        styleIncompleteLinkBrackets(ctx: ctx, codeRanges: codeRanges, checkboxRanges: checkboxRanges, into: &attrs)
        return attrs
    }

    // MARK: - Text/regex-based passes (ported 1:1, AST-agnostic)

    private static func collectCodeRanges(in blocks: [BlockNode]) -> [NSRange] {
        var ranges: [NSRange] = []
        func walk(_ nodes: [InlineNode]) {
            for node in nodes {
                switch node {
                case .code(let range, _): ranges.append(range)
                case .emphasis(_, _, _, let children),
                     .link(_, _, _, _, let children): walk(children)
                case .ext(let node): walk(node.children)
                default: break
                }
            }
        }
        for block in blocks {
            switch block {
            case .codeBlock(let range): ranges.append(range)
            case .paragraph(_, let inlines), .heading(_, _, _, let inlines), .blockquote(_, let inlines):
                walk(inlines)
            case .list(_, let items):
                for item in items { walk(item.inlines) }
            case .ext(let node):
                walk(node.inlines)
            default: break
            }
        }
        return ranges
    }

    private static func isInCode(_ range: NSRange, _ codeRanges: [NSRange]) -> Bool {
        codeRanges.contains { NSIntersectionRange($0, range).length > 0 }
    }

    /// Full ranges of markdown links `[text](url)` and wiki links `[[…]]`. The NSDataDetector
    /// auto-link pass skips URLs inside these, so a link's own `(url)` isn't independently
    /// linkified into a second, competing `.link` region overlapping the link (which offsets
    /// the click edit-zone and makes the raw URL navigable).
    private static func collectLinkRanges(in blocks: [BlockNode]) -> [NSRange] {
        var ranges: [NSRange] = []
        func walk(_ nodes: [InlineNode]) {
            for node in nodes {
                switch node {
                case .link(let range, _, _, _, let children):
                    ranges.append(range)
                    walk(children)
                case .wikiLink(let range, _, _, _):
                    ranges.append(range)
                case .emphasis(_, _, _, let children):
                    walk(children)
                case .ext(let node):
                    walk(node.children)
                default: break
                }
            }
        }
        for block in blocks {
            switch block {
            case .paragraph(_, let inlines), .heading(_, _, _, let inlines), .blockquote(_, let inlines):
                walk(inlines)
            case .list(_, let items):
                for item in items { walk(item.inlines) }
            case .ext(let node):
                walk(node.inlines)
            default: break
            }
        }
        return ranges
    }

    /// Checkbox boxes (`[ ]`/`[x]`), excluded so the incomplete-link pass doesn't repaint their brackets.
    private static func collectCheckboxRanges(in blocks: [BlockNode]) -> [NSRange] {
        var ranges: [NSRange] = []
        for block in blocks {
            if case .list(_, let items) = block {
                for item in items where item.checkbox != nil { ranges.append(item.checkbox!) }
            }
        }
        return ranges
    }

    private static func regex(_ pattern: String, _ anchored: Bool = true) -> NSRegularExpression? {
        try? NSRegularExpression(pattern: pattern, options: anchored ? [.anchorsMatchLines] : [])
    }

    // Built once, reused: rebuilding these on every restyle cost 43ms (detector)
    // + 78ms (6 regexes) on a 346k note with hits=0 (ENG-8g1b/c).
    private static let autoLinkDetector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
    private static let incompleteLinkPatterns: [NSRegularExpression] =
        [#"\[\]"#, #"\[\[\]\]"#, #"\[[^\]\r\n]*$"#, #"\[[^\]\r\n]+\](?!\()"#,
         #"\[[^\]\r\n]+\]\([^)\r\n]*$"#, #"\[[^\]\r\n]+\]\(\)"#].compactMap { regex($0, false) }

    /// Tag a thematic-break line for a full-width rule (AST-driven); suppressed while the caret edits it.
    ///
    /// When `configuration.thematicBreak` maps this line's marker to a mark,
    /// `.thematicBreakMark` rides along and the fragment draws that string
    /// centered instead of the rule. Resolving here rather than at draw time
    /// keeps the presentation decision next to the configuration (`Ctx` already
    /// carries it) and leaves the fragment with nothing to look up.
    private static func styleThematicBreak(range: NSRange, ctx: Ctx, into attrs: inout [StyledRange]) {
        var hr = range
        while hr.length > 0 {
            let last = ctx.ns.character(at: NSMaxRange(hr) - 1)
            guard last == 0x0A || last == 0x0D else { break }
            hr.length -= 1
        }
        guard hr.length > 0,
              !(NSLocationInRange(ctx.caret, hr) || ctx.caret == NSMaxRange(hr)) else { return }
        var tags: [NSAttributedString.Key: Any] = [
            .foregroundColor: NSColor.clear,
            .thematicBreak: true,
        ]
        let mark = ctx.config.thematicBreak.mark(forMarker: thematicBreakMarker(in: hr, ctx: ctx))
        if let mark {
            tags[.thematicBreakMark] = mark.text
            tags[.thematicBreakMarkScale] = mark.scale
        }
        attrs.append((hr, tags))

        // A mark bigger than body size needs the line to grow with it, or it
        // would be drawn over the paragraphs above and below (the fragment
        // paints outside the line box; it does not reserve space).
        let para = NSMutableParagraphStyle()
        if let mark, mark.scale > 1 {
            let height = ceil(ctx.baseLineHeight * mark.scale)
            para.minimumLineHeight = height
            para.maximumLineHeight = height
        }
        attrs.append((hr, [.paragraphStyle: para]))
    }

    /// The marker character of a thematic-break line: its first non-whitespace
    /// character. Sound by construction — `BlockParser.isThematicBreak` accepts
    /// the line only when every non-whitespace character is the same one of
    /// `-`/`*`/`_`. Only trailing newlines are trimmed from the block range, so
    /// leading indent has to be skipped here.
    private static func thematicBreakMarker(in hr: NSRange, ctx: Ctx) -> unichar {
        for offset in 0..<hr.length {
            let c = ctx.ns.character(at: hr.location + offset)
            if c != 0x20 && c != 0x09 { return c }
        }
        return 0
    }

    /// Ordered-list display numbers computed across the WHOLE document, keyed by
    /// each ordered item's marker location. Positional, not the literal digit, so
    /// any edit renumbers correctly; the count carries across a blank line (a
    /// loose-list separator) so `1.`/`2.`⏎blank⏎`2.` shows 1,2,3 — real content
    /// between lists resets it. First item of a run keeps its own start value.
    /// Like MarkdownLists.listRegex but also accepts `)` ordered markers (`5)`),
    /// matching the AST — used by the backward seed scan (group 2 = digits).
    private static let seedOrderedLineRegex = try! NSRegularExpression(
        pattern: #"^\s*((?:(\d+)[.)]|[-•*+])(?:\s+\[[ xX]\])?\s+)"#
    )

    /// First non-blank character in a range answers "was there content in the
    /// hole between two scoped blocks" without materializing the substring.
    private static let nonWhitespace = CharacterSet.whitespacesAndNewlines.inverted

    /// Replays the ordered-list run that continues ABOVE `loc` (scanning backward
    /// in the full source: same-indent items counted, blank lines skipped, real
    /// content stops it) and returns the next number per indent. Lets a scoped
    /// restyle that only sees a local window continue the document's numbering.
    private static func seedOrderedCounters(above loc: Int, in ns: NSString) -> [Int: Int] {
        guard loc > 0, loc <= ns.length else { return [:] }
        var runLines: [(indent: Int, number: Int?)] = []   // bottom-to-top; nil = bullet/other list
        // From the START of loc's line: callers pass a MARKER offset, which for
        // an indented item still sits inside its own line — scanning up from
        // there counted the item itself, so every nested list rendered one too
        // high ("  1. a" showing 2.).
        var scan = ns.lineRange(for: NSRange(location: min(loc, ns.length), length: 0)).location
        while scan > 0 {
            let lineRange = ns.lineRange(for: NSRange(location: scan - 1, length: 0))
            let line = ns.substring(with: lineRange) as NSString
            let full = NSRange(location: 0, length: line.length)
            if (line as String).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                scan = lineRange.location                    // blank line: loose-list spacing
                continue
            }
            guard let m = seedOrderedLineRegex.firstMatch(in: line as String, range: full) else { break }
            let ws = MarkdownLists.leadingWhitespaceRegex.firstMatch(in: line as String, range: full)
                .map { line.substring(with: $0.range) } ?? ""
            let number = m.range(at: 2).location != NSNotFound ? Int(line.substring(with: m.range(at: 2))) : nil
            // Key by the raw leading-whitespace char count to match the parser's
            // `item.indent` used by computeOrderedDisplayNumbers — otherwise a
            // nested item's seed counter wouldn't line up and it'd fall back to
            // the literal digit.
            runLines.append(((ws as NSString).length, number))
            scan = lineRange.location
        }
        var counters: [Int: Int] = [:]
        for item in runLines.reversed() {                    // replay top-to-bottom
            if let number = item.number {
                counters[item.indent] = (counters[item.indent] ?? number) + 1
            } else {
                counters[item.indent] = nil
            }
            for key in counters.keys where key > item.indent { counters[key] = nil }
        }
        return counters
    }

    private static func computeOrderedDisplayNumbers(blocks: [BlockNode], ns: NSString) -> [Int: Int] {
        var result: [Int: Int] = [:]
        var counters: [Int: Int] = [:]
        // `blocks` is NOT the document: a scoped restyle keeps only the blocks that
        // intersect the scope, and a multi-region scope (caret paragraph + previous
        // caret paragraph, built on every click) drops everything between them —
        // including the prose whose `default:` below is what ends a run. So treat
        // every discontinuity like a fresh start and re-seed from the SOURCE, the
        // only thing that can still see the skipped text. Lazily, at the first
        // ordered item after the gap, so prose/bullet restyles never pay the scan.
        var needsSeed = true
        var contiguousEnd: Int?
        for block in blocks {
            if let contiguousEnd, block.range.location > contiguousEnd,
               ns.rangeOfCharacter(from: Self.nonWhitespace, options: [],
                                   range: NSRange(location: contiguousEnd,
                                                  length: block.range.location - contiguousEnd)).location != NSNotFound {
                // Only CONTENT in the hole ends the run. A hole of pure blank
                // lines is loose-list spacing — and it is the shape the
                // coordinator's forward walk hands us (list, list, list, blanks
                // skipped), where re-seeding meant one full backward scan per
                // item: 639 ms for a single Return in an 800-item loose list.
                counters = [:]
                needsSeed = true
            }
            contiguousEnd = NSMaxRange(block.range)
            switch block {
            case .list(let listRange, let items):
                // A scoped node carries only the items the scope reached, so the
                // hole check has to bound BOTH ends of the item run against the
                // block, not just the space between two materialized items: seeded
                // with the block's start here, closed against its end below.
                var previousItemEnd: Int? = listRange.location
                for item in items {
                    if let previousItemEnd,
                       item.range.location > previousItemEnd {
                        counters = [:]
                        needsSeed = true
                    }
                    if item.ordered, let literal = item.number {
                        if needsSeed {
                            counters = seedOrderedCounters(above: item.marker.location, in: ns)
                            needsSeed = false
                        }
                        let n = counters[item.indent] ?? literal
                        result[item.marker.location] = n
                        counters[item.indent] = n + 1
                    } else {
                        counters[item.indent] = nil
                    }
                    for key in counters.keys where key > item.indent { counters[key] = nil }
                    previousItemEnd = NSMaxRange(item.range)
                }
                // Items the scope dropped from the TAIL are not "already counted".
                // Leaving contiguousEnd at the block's end hides them, so the next
                // block sees only the blank separator, reads it as loose-list
                // spacing, and carries a short count into a fresh run. Ending the
                // stretch at the last materialized item turns them back into the
                // content hole they are.
                if let previousItemEnd, previousItemEnd < NSMaxRange(listRange) {
                    contiguousEnd = previousItemEnd
                }
            case .blank:
                break                     // blank lines keep the count (spacing, not a reset)
            case .paragraph(_, let inlines) where inlines.isEmpty:
                break                     // an empty paragraph line is spacing too
            default:
                counters = [:]            // real text/content ends the run
                needsSeed = false         // a seed scan would stop on this line anyway
            }
        }
        return result
    }

    /// AST list-item decoration: indent paragraph, `•` bullet, checkbox + strikethrough, all caret-aware.
    private static func styleListItem(_ item: ListItem, displayNumber: Int?, ctx: Ctx, into attrs: inout [StyledRange]) {
        guard ctx.config.lists.helpersEnabled else { return }

        // Line content (item line minus its trailing newline).
        var line = item.range
        while line.length > 0 {
            let last = ctx.ns.character(at: NSMaxRange(line) - 1)
            guard last == 0x0A || last == 0x0D else { break }
            line.length -= 1
        }

        // 1. Indent paragraph style (hanging indent so wrapped lines align).
        let wsRange = NSRange(location: item.range.location, length: item.marker.location - item.range.location)
        let ws = ctx.ns.substring(with: wsRange)
        // Revealed while the caret edits the syntax (same test as the early
        // return below): the raw `- [ ]` stays at full advance.
        let taskRevealed: Bool = {
            guard let box = item.checkbox else { return false }
            let syntax = NSRange(location: item.marker.location, length: NSMaxRange(box) - item.marker.location)
            // Caret edit OR a selection sweeping the syntax reveals the raw
            // `- [ ]` — matching how token-based elements reveal on selection.
            return NSLocationInRange(ctx.caret, syntax) || ctx.caret == NSMaxRange(box)
                || ctx.selectionIntersects(syntax)
        }()
        // Hidden task item shares the bullet geometry: `[ ] ` collapses to ~zero
        // advance below, so the hanging indent measures only `- ` and task
        // content aligns with bullet content (the box replaces the bullet slot).
        let markerGroup: NSRange
        if let box = item.checkbox, !taskRevealed {
            markerGroup = NSRange(location: item.marker.location,
                                  length: box.location - item.marker.location)
        } else {
            markerGroup = NSRange(location: item.marker.location,
                                  length: item.contentRange.location - item.marker.location)
        }
        // An ordered item whose displayed number differs from its source digit
        // gets its WHOLE marker overlaid (below); the hanging indent must then
        // measure the DISPLAY marker so wrapped lines align at any digit count.
        // Off for tasks (the checkbox branch owns those).
        //
        // Neither the caret nor a selection takes the overlay down. Every other
        // markdown construct reveals its source under one, but an ordered
        // marker's source digit is the one thing the reader never authored: it
        // is positional, and a run written `1./1./1.` would flip a number back
        // to `1.` on a plain click or a ⌘A. The digits stay hidden and the
        // painter keeps drawing the display number under the selection
        // highlight, which is sized to the same kerned slot.
        let orderedOverlayActive = item.ordered && item.checkbox == nil && item.number != nil
            && displayNumber != nil && displayNumber != item.number
        // Keep the source punctuation (`.` or `)`) when overlaying, so a paren list stays a paren list.
        let orderedPunct = orderedOverlayActive && item.marker.length > 0
            ? ctx.ns.substring(with: NSRange(location: NSMaxRange(item.marker) - 1, length: 1)) : "."
        // Via the memoized measure — list markers are a tiny repeated set (`- `, `1. `).
        let markerWidth: CGFloat = {
            if orderedOverlayActive, let displayNumber {
                let gap = ctx.ns.substring(with: NSRange(location: NSMaxRange(item.marker),
                                                         length: item.contentRange.location - NSMaxRange(item.marker)))
                return HeadingHelpers.textWidth("\(displayNumber)\(orderedPunct)" + gap, font: ctx.baseFont)
            }
            return HeadingHelpers.textWidth(ctx.ns.substring(with: markerGroup), font: ctx.baseFont)
        }()
        let depthIndent = CGFloat(MarkdownLists.indentLevel(from: ws)) * ctx.config.lists.indentPerLevel
        let ps = NSMutableParagraphStyle()
        let lineHeight = ctx.baseLineHeight + ctx.config.lists.extraLineHeight
        ps.minimumLineHeight = lineHeight
        ps.maximumLineHeight = lineHeight
        ps.lineSpacing = 0
        ps.paragraphSpacing = ctx.baseParagraphSpacing
        ps.paragraphSpacingBefore = 0
        ps.tabStops = []
        ps.defaultTabInterval = ctx.config.lists.indentPerLevel
        ps.firstLineHeadIndent = ctx.config.lists.indentPerLevel
        // Wrapped lines hang under the first line's content (indent + marker
        // width). No checkbox-specific extra: the box is a drawn overlay that
        // doesn't change text advance, so adding it here (and only here, not to
        // firstLineHeadIndent) shifted an unchecked task's wrapped lines right
        // of its first line.
        ps.headIndent = ctx.config.lists.indentPerLevel + depthIndent + markerWidth
        attrs.append((line, [.paragraphStyle: ps]))

        // 2. Marker decoration (suppressed while the caret edits the syntax).
        if let box = item.checkbox {
            if taskRevealed { return }
            let spacer = NSRange(location: NSMaxRange(item.marker), length: box.location - NSMaxRange(item.marker))
            // `- ` keeps full advance (the box's slot, like the bullet `•`);
            // `[ ]` + trailing space collapse to the hidden-marker font so the
            // content starts at the bullet-content x.
            attrs.append((item.marker, [.foregroundColor: NSColor.clear]))
            if spacer.length > 0 { attrs.append((spacer, [.foregroundColor: NSColor.clear])) }
            attrs.append((box, [.taskCheckbox: item.checked, .foregroundColor: NSColor.clear,
                                .font: ctx.inlineMarkerFont]))
            let postGap = NSRange(location: NSMaxRange(box),
                                  length: item.contentRange.location - NSMaxRange(box))
            if postGap.length > 0 {
                attrs.append((postGap, [.foregroundColor: NSColor.clear, .font: ctx.inlineMarkerFont]))
            }
            if item.checked, NSMaxRange(item.range) > NSMaxRange(box) {
                attrs.append((NSRange(location: NSMaxRange(box), length: NSMaxRange(item.range) - NSMaxRange(box)), [
                    .strikethroughStyle: NSUnderlineStyle.single.rawValue,
                    .strikethroughColor: ctx.theme.strikethroughColor,
                ]))
            }
        } else if !item.ordered {
            let syntax = NSRange(location: item.marker.location,
                                 length: item.contentRange.location - item.marker.location)
            if NSLocationInRange(ctx.caret, syntax) { return }
            attrs.append((item.marker, [.bulletMarker: true, .foregroundColor: NSColor.clear]))
        } else if orderedOverlayActive, let displayNumber {
            // Hide the ENTIRE source marker (digits + dot) as one unit and paint
            // the whole display marker "N." over it, so the dot travels with the
            // digits.
            //
            // Hidden by SIZE, like every other marker this engine hides, not by a
            // clear colour: NSTextView.selectedTextAttributes carries a
            // `selectedTextColor`, so it repaints every selected glyph opaque —
            // a colour-hidden marker comes back under the highlight and collides
            // with the number painted over it. A shrunken run cannot be
            // repainted into visibility. The colour stays as a second line of
            // defence against sub-pixel residue at extreme zoom.
            //
            // Kern that near-zero run back out to the display marker's width so
            // the slot, the hanging indent and the selection highlight all
            // measure the same thing. Horizontal only — a scaled-UP font would
            // inflate the marker ascent and push the content baseline down under
            // the pinned line height.
            let hiddenW = (ctx.ns.substring(with: item.marker) as NSString)
                .size(withAttributes: [.font: ctx.inlineMarkerFont]).width
            let displayW = ("\(displayNumber)\(orderedPunct)" as NSString)
                .size(withAttributes: [.font: ctx.baseFont]).width
            var markerAttrs: [NSAttributedString.Key: Any] = [
                .orderedMarker: "\(displayNumber)\(orderedPunct)",
                .foregroundColor: NSColor.clear,
                .font: ctx.inlineMarkerFont,
            ]
            if abs(displayW - hiddenW) > 0.01 {
                markerAttrs[.kern] = (displayW - hiddenW) / CGFloat(max(1, item.marker.length))
            }
            attrs.append((item.marker, markerAttrs))
        }
    }

    private static func styleAutoLinks(ctx: Ctx, codeRanges: [NSRange], linkRanges: [NSRange], into attrs: inout [StyledRange]) {
        guard let detector = autoLinkDetector else { return }
        for scan in ctx.scanRanges {
            detector.enumerateMatches(in: ctx.text, range: scan) { match, _, _ in
                // Skip URLs inside code and inside a markdown/wiki link's own range — a link's
                // `(url)` must not become a second `.link` region competing with the link itself.
                guard let match, let url = match.url,
                      !isInCode(match.range, codeRanges),
                      !isInCode(match.range, linkRanges) else { return }
                attrs.append((match.range, [.link: url]))
            }
        }
    }

    private static func styleIncompleteLinkBrackets(ctx: Ctx, codeRanges: [NSRange], checkboxRanges: [NSRange], into attrs: inout [StyledRange]) {
        // Every pattern starts with `\[`, so no `[` in the text ⇒ no match: skip
        // all 6 regex sweeps (the 78ms on hits=0 docs).
        guard ctx.ns.range(of: "[").location != NSNotFound else { return }
        let muted = ctx.theme.mutedText
        let faded = ctx.theme.incompleteLink.withAlphaComponent(ctx.config.link.incompleteLinkAlpha)
        for re in incompleteLinkPatterns {
            for scan in ctx.scanRanges {
              for m in re.matches(in: ctx.text, options: [], range: scan)
                  where !isInCode(m.range, codeRanges) && !isInCode(m.range, checkboxRanges) {
                // One range per RUN of same-colored characters, not per character: a
                // single `[Design System]` used to emit 15 ranges, and the note in the
                // bug report reached 25,504 from this pass alone — every one of them a
                // separate storage mutation downstream.
                var runStart = m.range.location
                var runLength = 0
                var runIsBracket = false
                for ch in ctx.ns.substring(with: m.range) {
                    let isBracket = ch == "[" || ch == "]" || ch == "(" || ch == ")"
                    let width = ch.utf16.count
                    if runLength > 0, isBracket != runIsBracket {
                        attrs.append((NSRange(location: runStart, length: runLength),
                                      [.foregroundColor: runIsBracket ? muted : faded]))
                        runStart += runLength
                        runLength = 0
                    }
                    runIsBracket = isBracket
                    runLength += width
                }
                if runLength > 0 {
                    attrs.append((NSRange(location: runStart, length: runLength),
                                  [.foregroundColor: runIsBracket ? muted : faded]))
                }
              }
            }
        }
    }

    /// Shared inputs threaded through the walk.
    /// Internal (not private) so per-construct styling can live in its own
    /// file — see `MarkdownASTStyler+Directives.swift`.
    struct Ctx {
        let ns: NSString
        let fontName: String
        let baseFont: NSFont
        let baseLineHeight: CGFloat
        let baseParagraphSpacing: CGFloat
        let codeFont: NSFont
        let codeBackground: NSColor
        let codeParagraphStyle: NSParagraphStyle
        let inlineMarkerFont: NSFont
        let caret: Int
        /// The full selected range (nil/empty when the selection is a bare
        /// caret). Token-based elements already reveal on selection via
        /// `activeTokenIndices(selection:)`; this brings the same signal to
        /// non-token elements (task checkboxes). Proven root cause: the
        /// caret-only reveal can hit at most ONE selected task line — every
        /// other selected line stayed hidden.
        let selection: NSRange?
        let config: MarkdownEditorConfiguration
        let extensionsByID: [String: any MarkdownExtension]
        let wikiLinkID: (NSRange) -> String?
        let scopedRanges: [NSRange]?
        let orderedDisplayNumbers: [Int: Int]

        /// True when a non-empty selection overlaps `range` — the selection
        /// counterpart of `isActive` for elements that reveal on select.
        func selectionIntersects(_ range: NSRange) -> Bool {
            guard let selection, selection.length > 0 else { return false }
            return NSIntersectionRange(selection, range).length > 0
        }

        /// Active (syntax revealed) when the caret is inside the range or at its end (minus a newline).
        func isActive(_ range: NSRange) -> Bool {
            if NSLocationInRange(caret, range) { return true }
            guard range.length > 0, caret == NSMaxRange(range) else { return false }
            let last = ns.character(at: caret - 1)
            return last != 0x0A && last != 0x0D
        }
        var theme: MarkdownEditorTheme { config.theme }
        var text: String { ns as String }
        var fullRange: NSRange { NSRange(location: 0, length: ns.length) }
        /// Whether a range falls in the styled region (nil scope = whole doc).
        func inScope(_ r: NSRange) -> Bool {
            guard let scopedRanges else { return true }
            return scopedRanges.contains { NSIntersectionRange($0, r).length > 0 }
        }
        /// Ranges the regex/text passes scan (edited paragraphs, or whole doc).
        var scanRanges: [NSRange] { scopedRanges ?? [fullRange] }
    }

    // MARK: - Blocks

    private static func styleBlock(_ block: BlockNode, font: NSFont, ctx: Ctx, into attrs: inout [StyledRange]) {
        switch block {
        case .paragraph(_, let inlines):
            styleInlines(inlines, font: font, ctx: ctx, into: &attrs)

        case .heading(let level, let range, let markers, let inlines):
            let multiplier = ctx.config.headings.fontMultiplier(for: level)
            let headingBase = NSFont(name: ctx.fontName, size: ctx.baseFont.pointSize * multiplier)
                ?? .systemFont(ofSize: ctx.baseFont.pointSize * multiplier)
            let headingFont = adding(.bold, to: headingBase)
            let lineHeight = ceil(headingFont.ascender - headingFont.descender + headingFont.leading) + 1
            let headingPara = NSMutableParagraphStyle()
            headingPara.minimumLineHeight = lineHeight
            headingPara.maximumLineHeight = lineHeight
            headingPara.paragraphSpacingBefore = headingFont.pointSize * ctx.config.headings.topSpacingEm(for: level)
            headingPara.paragraphSpacing = ctx.baseParagraphSpacing
            attrs.append((ctx.ns.paragraphRange(for: range), [.paragraphStyle: headingPara]))
            attrs.append((range, [.font: headingFont]))
            for marker in markers {
                attrs.append((marker, [.foregroundColor: ctx.theme.headingMarker]))
            }
            styleInlines(inlines, font: headingFont, ctx: ctx, into: &attrs)

        case .blockquote(let range, let inlines):
            styleBlockquote(range: range, ctx: ctx, into: &attrs)
            styleInlines(inlines, font: font, ctx: ctx, into: &attrs)

        case .list(_, let items):
            for item in items {
                styleListItem(item, displayNumber: ctx.orderedDisplayNumbers[item.marker.location],
                              ctx: ctx, into: &attrs)
                styleInlines(item.inlines, font: font, ctx: ctx, into: &attrs)
            }

        case .codeBlock(let range):
            styleCodeBlock(range: range, ctx: ctx, into: &attrs)
        case .thematicBreak(let range):
            styleThematicBreak(range: range, ctx: ctx, into: &attrs)
        case .ext(let node):
            styleExtensionBlock(node, font: font, ctx: ctx, into: &attrs)
        case .blockLatex, .table, .blank:
            break   // NSImage rendering ported next
        }
    }

    /// Extension fenced block: the extension supplies content ATTRIBUTES only;
    /// they cover the WHOLE block (fence lines included) so the block reads as
    /// one cohesive band — the hidden fences would otherwise sit as uncolored
    /// blank rows above and below the body. Fence lines then mute while the
    /// caret is inside the block and hide otherwise (mirroring code fences —
    /// clear color, unchanged font, so the line keeps its height and layout
    /// stays stable across the active flip).
    private static func styleExtensionBlock(_ node: ExtensionBlockNode, font: NSFont, ctx: Ctx, into attrs: inout [StyledRange]) {
        if let ext = ctx.extensionsByID[node.extensionID] {
            var block = node.range
            // Keep the block's trailing newline out, so the band doesn't
            // bleed a full-width background onto the following line.
            while block.length > 0 {
                let last = ctx.ns.character(at: NSMaxRange(block) - 1)
                guard last == 0x0A || last == 0x0D else { break }
                block.length -= 1
            }
            if block.length > 0 {
                attrs.append((block, ext.contentAttributes(theme: ctx.theme)))
            }
        }
        let markerAttrs: [NSAttributedString.Key: Any] = ctx.isActive(node.range)
            ? [.foregroundColor: ctx.theme.mutedText]
            : [.foregroundColor: NSColor.clear]
        attrs.append((node.openFence, markerAttrs))
        if let close = node.closeFence { attrs.append((close, markerAttrs)) }
        styleInlines(node.inlines, font: font, ctx: ctx, into: &attrs)
    }

    /// Per-line blockquote: indent, mute content, hide/show `>` markers, tag first char with bar level.
    private static func styleBlockquote(range: NSRange, ctx: Ctx, into attrs: inout [StyledRange]) {
        let indentPerLevel = MarkdownTextLayoutFragment.blockquoteIndentPerLevel
        var lineStart = range.location
        let end = NSMaxRange(range)
        while lineStart < end {
            let line = ctx.ns.lineRange(for: NSRange(location: lineStart, length: 0))
            let lineEnd = NSMaxRange(line)
            var i = line.location
            var indent = 0
            while i < lineEnd, indent < 3, ctx.ns.character(at: i) == 0x20 || ctx.ns.character(at: i) == 0x09 {
                i += 1; indent += 1
            }
            let markerStart = i
            var level = 0
            var j = i
            while j < lineEnd, ctx.ns.character(at: j) == 0x3E /* > */ {
                level += 1; j += 1
                if j < lineEnd, ctx.ns.character(at: j) == 0x20 || ctx.ns.character(at: j) == 0x09 { j += 1 }
            }
            defer { lineStart = lineEnd }
            guard level > 0 else { continue }

            var contentEnd = lineEnd
            if contentEnd > j {
                let last = ctx.ns.character(at: contentEnd - 1)
                if last == 0x0A || last == 0x0D { contentEnd -= 1 }
            }
            let markerRange = NSRange(location: markerStart, length: j - markerStart)
            let contentRange = NSRange(location: j, length: max(0, contentEnd - j))
            let tokenRange = NSRange(location: line.location, length: contentEnd - line.location)

            let textIndent = CGFloat(level) * indentPerLevel + indentPerLevel * 0.5
            let para = NSMutableParagraphStyle()
            para.firstLineHeadIndent = textIndent
            para.headIndent = textIndent
            let lineHeight = ctx.baseLineHeight + ctx.config.blockquote.extraLineHeight
            para.minimumLineHeight = lineHeight
            para.maximumLineHeight = lineHeight
            // Inner quote lines stay tight (0); the LAST line gets the normal
            para.paragraphSpacing = (lineEnd >= end) ? ctx.baseParagraphSpacing : 0
            para.paragraphSpacingBefore = 0
            attrs.append((ctx.ns.paragraphRange(for: tokenRange), [.paragraphStyle: para]))

            if contentRange.length > 0 {
                attrs.append((contentRange, [.foregroundColor: ctx.theme.mutedText]))
            }
            if ctx.isActive(tokenRange) {
                attrs.append((markerRange, [.foregroundColor: ctx.theme.mutedText]))
            } else {
                attrs.append((markerRange, [.foregroundColor: NSColor.clear, .font: ctx.inlineMarkerFont]))
            }
            // Whole line, not just the first char, so each soft-wrapped visual line
            attrs.append((tokenRange, [.blockquoteLevel: level]))
        }
    }

    private static func styleCodeBlock(range: NSRange, ctx: Ctx, into attrs: inout [StyledRange]) {
        let parts = codeBlockParts(range, ctx.ns)
        attrs.append((parts.codeRange, [
            .font: ctx.codeFont, .backgroundColor: ctx.codeBackground, .paragraphStyle: ctx.codeParagraphStyle,
        ]))
        // Suppress spell-check underlines on the whole fenced block — code is not prose.
        attrs.append((parts.codeRange, [.spellingState: 0]))
        let codeContent = ctx.ns.substring(with: parts.content)
        if !codeContent.isEmpty,
           let highlighted = ctx.config.services.syntaxHighlighter.highlight(code: codeContent, language: parts.language) {
            highlighted.enumerateAttributes(in: NSRange(location: 0, length: highlighted.length)) { a, r, _ in
                guard let fg = a[.foregroundColor] else { return }
                attrs.append((NSRange(location: parts.content.location + r.location, length: r.length), [.foregroundColor: fg]))
            }
        }
        // Use the whole block range (not codeRange): an incomplete fence collapses codeRange to the ```.
        let markerAttrs: [NSAttributedString.Key: Any] = ctx.isActive(range)
            ? [.foregroundColor: ctx.theme.mutedText, .font: ctx.codeFont]
            : [.foregroundColor: NSColor.clear, .font: ctx.codeFont]   // hiddenMarkerFont == codeFont
        attrs.append((parts.openFence, markerAttrs))
        attrs.append((parts.closeFence, markerAttrs))
    }

    /// Split a fenced-code range into open fence (+language), content, close fence, and language.
    private static func codeBlockParts(_ range: NSRange, _ ns: NSString)
        -> (codeRange: NSRange, openFence: NSRange, content: NSRange, closeFence: NSRange, language: String?) {
        let start = range.location
        let end = NSMaxRange(range)
        var openEnd = start
        while openEnd < end, ns.character(at: openEnd) != 0x0A { openEnd += 1 }
        if openEnd < end { openEnd += 1 }
        let openFence = NSRange(location: start, length: openEnd - start)

        let lastLine = ns.lineRange(for: NSRange(location: max(start, end - 1), length: 0))
        var bt = lastLine.location
        while bt < NSMaxRange(lastLine), ns.character(at: bt) == 0x60 { bt += 1 }
        let closeFence = NSRange(location: lastLine.location, length: bt - lastLine.location)
        let codeRange = NSRange(location: start, length: NSMaxRange(closeFence) - start)
        let content = NSRange(location: openEnd, length: max(0, lastLine.location - openEnd))

        var language: String?
        if openFence.length > 3 {
            let raw = ns.substring(with: NSRange(location: start + 3, length: openFence.length - 3))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            language = raw.isEmpty ? nil : raw
        }
        return (codeRange, openFence, content, closeFence, language)
    }

    // MARK: - Inlines (composing)

    private static func styleInlines(_ nodes: [InlineNode], font: NSFont, ctx: Ctx, into attrs: inout [StyledRange]) {
        for node in nodes {
            switch node {
            case .text:
                break

            case .emphasis(let kind, let range, let markers, let children):
                let composed = adding(traits(for: kind), to: font)
                attrs.append((content(of: markers), [.font: composed]))
                if ctx.isActive(range) {
                    for marker in markers { attrs.append((marker, [.foregroundColor: ctx.theme.mutedText])) }
                }
                styleInlines(children, font: composed, ctx: ctx, into: &attrs)

            case .ext(let node):
                // Directives come through the same node shape under a reserved
                // id namespace. They compose a font TRANSFORM over the
                // inherited font and hand it down, so emphasis nested in the
                // body keeps both (`@font(size: 18){**bold**}` is bold AND
                // 18pt). Non-directive nodes fall through unchanged.
                if let bodyFont = directiveBodyFont(for: node, font: font, ctx: ctx, into: &attrs) {
                    if ctx.isActive(node.range) {
                        for marker in node.markers { attrs.append((marker, [.foregroundColor: ctx.theme.mutedText])) }
                    }
                    styleInlines(node.children, font: bodyFont, ctx: ctx, into: &attrs)
                    break
                }
                // Extension-contributed span: the extension supplies content
                // ATTRIBUTES only; every range comes from the parser, so a
                // misbehaving extension can restyle its own span at worst.
                if let ext = ctx.extensionsByID[node.extensionID] {
                    attrs.append((node.contentRange, ext.contentAttributes(theme: ctx.theme)))
                }
                if ctx.isActive(node.range) {
                    for marker in node.markers { attrs.append((marker, [.foregroundColor: ctx.theme.mutedText])) }
                }
                styleInlines(node.children, font: font, ctx: ctx, into: &attrs)

            case .code(let range, let contentRange):
                attrs.append((contentRange, [.font: ctx.codeFont, .backgroundColor: ctx.codeBackground]))
                // Suppress spell-check underlines on inline `code` spans (markers + content).
                attrs.append((range, [.spellingState: 0]))
                let markerAttrs: [NSAttributedString.Key: Any] = ctx.isActive(range)
                    ? [.foregroundColor: ctx.theme.mutedText, .font: ctx.codeFont]
                    : [.foregroundColor: ctx.theme.mutedText.withAlphaComponent(ctx.config.markers.inlineCodeMarkerAlpha),
                       .font: ctx.inlineMarkerFont]
                for marker in markers(of: range, content: contentRange) { attrs.append((marker, markerAttrs)) }

            case .link(let range, let textRange, let url, let markers, let children):
                styleLink(range: range, textRange: textRange, url: url, markers: markers, children: children, font: font, ctx: ctx, into: &attrs)

            case .wikiLink(let range, let name, _, let markers):
                styleWikiLink(range: range, name: name, markers: markers, ctx: ctx, into: &attrs)

            case .image, .imageEmbed, .inlineLatex, .escape:
                break   // ported in later increments
            }
        }
    }

    private static func styleLink(
        range: NSRange, textRange: NSRange, url urlRange: NSRange, markers: [NSRange],
        children: [InlineNode], font: NSFont, ctx: Ctx, into attrs: inout [StyledRange]
    ) {
        attrs.append((range, [.spellingState: 0]))
        var urlString = ctx.ns.substring(with: urlRange)
        if !urlString.contains("://") { urlString = "https://\(urlString)" }
        let isActive = ctx.isActive(range)
        if let url = URL(string: urlString) {
            if isActive {
                attrs.append((textRange, [
                    .foregroundColor: ctx.theme.link.withAlphaComponent(ctx.config.link.activeLinkAlpha),
                ]))
            } else {
                attrs.append((textRange, [
                    .link: url,
                    .underlineStyle: NSUnderlineStyle.single.rawValue,
                    .foregroundColor: ctx.theme.link,
                ]))
            }
        }
        for marker in markers { attrs.append((marker, [.foregroundColor: ctx.theme.mutedText])) }
        // The target is syntax, revealed with its brackets and muted like them —
        // at body color it is louder than the label it belongs to.
        if isActive { attrs.append((urlRange, [.foregroundColor: ctx.theme.mutedText])) }
        styleInlines(children, font: font, ctx: ctx, into: &attrs)
    }

    private static func styleWikiLink(
        range: NSRange, name: NSRange, markers: [NSRange], ctx: Ctx, into attrs: inout [StyledRange]
    ) {
        attrs.append((range, [.spellingState: 0]))
        let nodeName = ctx.ns.substring(with: name)
        let linkID = ctx.wikiLinkID(range)
        var contentAttrs: [NSAttributedString.Key: Any] = [:]
        if let linkID { contentAttrs[.wikiLinkID] = linkID }
        if !ctx.isActive(range) {
            // Resolve by the stable UUID when present 
            let exists = ctx.config.services.wikiLinks.resolve(displayName: linkID ?? nodeName, range: name)?.exists ?? false
            if exists {
                contentAttrs[.link] = linkID ?? nodeName
            } else {
                contentAttrs[.foregroundColor] = ctx.theme.disabledText
            }
        }
        if !contentAttrs.isEmpty { attrs.append((name, contentAttrs)) }
        for marker in markers { attrs.append((marker, [.foregroundColor: ctx.theme.mutedText])) }
    }

    // MARK: - Marker shrinking (hide syntax of inactive nodes)

    /// Collapse inactive nodes' markers to a tiny kerned font so syntax vanishes; code/LaTeX skip themselves.
    private static func shrinkInactiveMarkers(in blocks: [BlockNode], ctx: Ctx, into attrs: inout [StyledRange]) {
        for block in blocks where ctx.inScope(block.range) {
            switch block {
            case .heading(_, let range, let markers, let inlines):
                if !ctx.isActive(range) { shrink(markers, ctx: ctx, into: &attrs) }
                shrinkInlineMarkers(inlines, ctx: ctx, into: &attrs)
            case .paragraph(_, let inlines), .blockquote(_, let inlines):
                shrinkInlineMarkers(inlines, ctx: ctx, into: &attrs)
            case .list(_, let items):
                // Phase A: shrink only inline markers; the list marker is hidden by the bullet/task pass.
                for item in items { shrinkInlineMarkers(item.inlines, ctx: ctx, into: &attrs) }
            case .ext(let node):
                shrinkInlineMarkers(node.inlines, ctx: ctx, into: &attrs)
            case .codeBlock, .blockLatex, .table, .thematicBreak, .blank:
                break
            }
        }
    }

    /// Shrink inactive markers; an active ancestor reveals its whole subtree via `forceReveal`.
    private static func shrinkInlineMarkers(_ nodes: [InlineNode], ctx: Ctx, forceReveal: Bool = false, into attrs: inout [StyledRange]) {
        for node in nodes {
            switch node {
            case .emphasis(_, let range, let markers, let children):
                let active = forceReveal || ctx.isActive(range)
                if !active { shrink(markers, ctx: ctx, into: &attrs) }
                shrinkInlineMarkers(children, ctx: ctx, forceReveal: active, into: &attrs)
            case .ext(let node):
                let active = forceReveal || ctx.isActive(node.range)
                if !active { shrink(node.markers, ctx: ctx, into: &attrs) }
                shrinkInlineMarkers(node.children, ctx: ctx, forceReveal: active, into: &attrs)
            case .link(let range, _, _, let markers, let children):
                let active = forceReveal || ctx.isActive(range)
                if !active {
                    shrink(markers, ctx: ctx, into: &attrs)
                    if markers.count >= 4 {   // also hide the "(url)" run
                        let hide = NSRange(location: markers[2].location,
                                           length: NSMaxRange(markers[3]) - markers[2].location)
                        attrs.append((hide, [.font: ctx.inlineMarkerFont, .foregroundColor: NSColor.clear]))
                    }
                }
                shrinkInlineMarkers(children, ctx: ctx, forceReveal: active, into: &attrs)
            case .wikiLink(let range, _, _, let markers):
                if !(forceReveal || ctx.isActive(range)) { shrink(markers, ctx: ctx, into: &attrs) }
            case .image(let range, _, _, let markers):
                if !(forceReveal || ctx.isActive(range)) { shrink(markers, ctx: ctx, into: &attrs) }
            case .escape(let range, _, let marker):
                if !(forceReveal || ctx.isActive(range)) { shrink([marker], ctx: ctx, into: &attrs) }
            case .text, .code, .imageEmbed, .inlineLatex:
                break   // own marker handling / not shrunk
            }
        }
    }

    private static func shrink(_ markers: [NSRange], ctx: Ctx, into attrs: inout [StyledRange]) {
        for marker in markers {
            attrs.append((marker, [.font: ctx.inlineMarkerFont, .kern: -ctx.inlineMarkerFont.pointSize]))
        }
    }

    // MARK: - Helpers

    private static func traits(for kind: EmphasisKind) -> NSFontDescriptor.SymbolicTraits {
        switch kind {
        case .italic: return .italic
        case .bold: return .bold
        case .boldItalic: return [.bold, .italic]
        }
    }

    private static func adding(_ extra: NSFontDescriptor.SymbolicTraits, to font: NSFont) -> NSFont {
        let merged = font.fontDescriptor.symbolicTraits.union(extra)
        return NSFont(descriptor: font.fontDescriptor.withSymbolicTraits(merged), size: font.pointSize) ?? font
    }

    private static func content(of markers: [NSRange]) -> NSRange {
        let start = NSMaxRange(markers[0])
        return NSRange(location: start, length: markers[1].location - start)
    }

    /// The two backtick marker ranges of an inline code span (range minus content).
    private static func markers(of range: NSRange, content: NSRange) -> [NSRange] {
        [
            NSRange(location: range.location, length: content.location - range.location),
            NSRange(location: NSMaxRange(content), length: NSMaxRange(range) - NSMaxRange(content)),
        ]
    }
}
