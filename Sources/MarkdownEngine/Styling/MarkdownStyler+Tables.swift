//
//  MarkdownStyler+Tables.swift
//  MarkdownEngine
//
//  GFM tables. The block is rendered to a single NSImage and emitted via
//  the same collapsedSource path block-LaTeX uses, so the source stays
//  in sync with the document but the user only sees the rendered grid
//  when the caret is outside the table.
//

import AppKit
import Foundation

extension MarkdownStyler {

    enum TableAlignment {
        case left
        case center
        case right
    }

    struct ParsedTable {
        let header: [String]
        let alignments: [TableAlignment]
        let rows: [[String]]
    }

    /// Rendered-table image cache. A table's pixels depend only on its source,
    /// font, colors, and appearance — so identical keys can reuse the NSImage
    /// instead of re-rendering every inactive table on every keystroke.
    private static let tableImageCache: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        // Must exceed a document's unique-table count or a full restyle (load /
        // theme / font change) re-renders every table (same thrash class as the
        // metadata cap). NSCache still auto-evicts under memory pressure.
        cache.countLimit = 2048
        return cache
    }()

    /// Pixel-level fingerprint of a theme color: its sRGB components resolved
    /// under `appearance`. NSColor descriptions are not sound identities —
    /// named dynamic colors describe by name only (two providers collide),
    /// unnamed ones by per-instance UUID (never hit) — so key on what actually
    /// reaches the bitmap.
    private static func colorKey(_ color: NSColor, under appearance: NSAppearance) -> String {
        var srgb: NSColor?
        appearance.performAsCurrentDrawingAppearance {
            srgb = color.usingColorSpace(.sRGB)
        }
        guard let c = srgb else { return "\(color)" }
        return String(format: "%.4f,%.4f,%.4f,%.4f",
                      c.redComponent, c.greenComponent, c.blueComponent, c.alphaComponent)
    }

    /// Resolving six colors per table per keystroke is measurable (10 tables ×
    /// 6 appearance-scoped resolutions). The resolved prefix depends only on
    /// the color INSTANCES + appearance + font, so memoize it by identity —
    /// theme copies keep the same NSColor references across keystrokes.
    private static let themeKeyLock = NSLock()
    private static var themeKeyCache: [String: String] = [:]

    private static func themeKeyPrefix(ctx: StylingContext, appearance: NSAppearance) -> String {
        let theme = ctx.configuration.theme
        let identity = "\(ctx.baseFont.fontName)|\(ctx.baseFont.pointSize)|\(appearance.name.rawValue)|"
            + "\(ObjectIdentifier(theme.bodyText))|\(ObjectIdentifier(theme.mutedText))|"
            + "\(ObjectIdentifier(theme.highlightColor))|\(ObjectIdentifier(ctx.codeBackgroundColor))|"
            + "\(ObjectIdentifier(theme.latexLightModeText))|\(ObjectIdentifier(theme.latexDarkModeText))|"
            + "\(ObjectIdentifier(type(of: ctx.services.latex)))"

        themeKeyLock.lock()
        if let cached = themeKeyCache[identity] {
            themeKeyLock.unlock()
            return cached
        }
        themeKeyLock.unlock()

        // Every input renderTable reads must be in the key: fonts, all theme
        // colors it draws with, and the latex renderer (by type — a NoOp and a
        // real renderer must not share entries).
        let prefix = [
            ctx.baseFont.fontName,
            "\(ctx.baseFont.pointSize)",
            appearance.name.rawValue,
            colorKey(theme.bodyText, under: appearance),
            colorKey(theme.mutedText, under: appearance),
            colorKey(theme.highlightColor, under: appearance),
            colorKey(ctx.codeBackgroundColor, under: appearance),
            colorKey(theme.latexLightModeText, under: appearance),
            colorKey(theme.latexDarkModeText, under: appearance),
            "\(ObjectIdentifier(type(of: ctx.services.latex)))",
        ].joined(separator: "|")

        themeKeyLock.lock()
        if themeKeyCache.count > 32 { themeKeyCache.removeAll() }
        themeKeyCache[identity] = prefix
        themeKeyLock.unlock()
        return prefix
    }

    /// Parse + content-hash for a table source, memoized: both are pure in
    /// the source text but were recomputed for every table on every keystroke
    /// (the non-render share of styleTables). FIFO-capped like the block token
    /// memo — the cap MUST exceed a document's table count, else cyclic access
    /// over the full table set is Bélády-pessimal under FIFO (~100% miss) and
    /// every table re-parses+re-hashes every keystroke.
    private static let tableMetaCap = 8192
    private static let tableMetaLock = NSLock()
    private static var tableMetaCache: [String: (parsed: ParsedTable?, hash: Int)] = [:]
    private static var tableMetaOrder: [String] = []

    static func tableMeta(for source: String) -> (parsed: ParsedTable?, hash: Int) {
        tableMetaLock.lock()
        if let cached = tableMetaCache[source] {
            tableMetaLock.unlock()
            return cached
        }
        tableMetaLock.unlock()

        let computed = (parseTableSource(source), stableTableContentHash(for: source))

        tableMetaLock.lock()
        if tableMetaCache[source] == nil {
            tableMetaCache[source] = computed
            tableMetaOrder.append(source)
            if tableMetaOrder.count > tableMetaCap {
                tableMetaCache[tableMetaOrder.removeFirst()] = nil
            }
        }
        tableMetaLock.unlock()
        return computed
    }

    /// Returns the rendered image for `source`, from cache when possible.
    /// `rendered` is true only when a fresh render actually happened.
    /// `availableWidth` caps the table's width (cells wrap onto extra lines);
    /// it is part of the cache key because the layout depends on it.
    static func tableImage(
        for source: String,
        parsed: ParsedTable,
        ctx: StylingContext,
        appearance: NSAppearance,
        availableWidth: CGFloat
    ) -> (image: NSImage, rendered: Bool) {
        let widthKey = Int(availableWidth.rounded())
        // The extension registry is part of the key: `==x==` in a cell renders
        // highlighted under one config and literal under another — those must
        // never share a cached image.
        let extensionKey = ctx.configuration.extensionRegistry.fingerprint
        let key = (themeKeyPrefix(ctx: ctx, appearance: appearance) + "|x\(extensionKey)|w\(widthKey)|" + source) as NSString
        if let cached = tableImageCache.object(forKey: key) {
            return (cached, false)
        }
        let image = renderTable(
            parsed,
            baseFont: ctx.baseFont,
            theme: ctx.configuration.theme,
            codeBackgroundColor: ctx.codeBackgroundColor,
            latex: ctx.services.latex,
            appearance: appearance,
            availableWidth: availableWidth,
            extensions: ctx.configuration.extensions
        )
        tableImageCache.setObject(image, forKey: key)
        return (image, true)
    }

    static func styleTables(_ ctx: StylingContext) -> [StyledRange] {
        var attrs: [StyledRange] = []
        // Per-content occurrence counter so identical tables get distinct sourceIDs.
        var occurrenceByContentHash: [Int: Int] = [:]
        var tableCount = 0
        var renderedCount = 0
        let tablesT0 = DispatchTime.now().uptimeNanoseconds
        // Iterate the pre-classified table array (not all document tokens).
        // The occurrence counter exists for stable duplicate-table sourceIDs,
        // and a sourceID is only CONSUMED by a table that renders this pass
        // (inactive + in scope). Equal content implies equal source length,
        // so only tables sharing a length with a rendering table can affect
        // its occurrence index — every other inactive table skips the
        // substring + parse/hash AND the .spellingState write (applied
        // UNCLIPPED, it used to touch every table in the document on every
        // keystroke). Typing prose renders no table → all tables skip.
        let tableIndexed = ctx.tableIndexed
        var neededLengths: Set<Int> = []
        for (idx, token) in tableIndexed
        where !ctx.activeTokenIndices.contains(idx) && !ctx.outsideScope(token.range) {
            neededLengths.insert(token.range.length)
        }
        var skippedCount = 0
        var metaNanos: UInt64 = 0
        for (idx, token) in tableIndexed {
            tableCount += 1
            if !ctx.activeTokenIndices.contains(idx),
               !neededLengths.contains(token.range.length) {
                skippedCount += 1
                continue
            }
            // Tokenizer already drops tables overlapping fenced code, so no re-check here.
            attrs.append((token.range, [.spellingState: 0]))

            let metaT0 = DispatchTime.now().uptimeNanoseconds
            let source = ctx.nsText.substring(with: token.range)
            let meta = tableMeta(for: source)
            metaNanos &+= DispatchTime.now().uptimeNanoseconds - metaT0
            guard let parsed = meta.parsed else { continue }

            // Advance occurrence index even for active/out-of-scope tables so
            // inactive duplicates keep stable sourceIDs.
            let occurrenceIndex = occurrenceByContentHash[meta.hash, default: 0]
            occurrenceByContentHash[meta.hash] = occurrenceIndex + 1

            let isActive = ctx.activeTokenIndices.contains(idx)
            if isActive {
                // Caret inside the table — show editable source, pipes muted like other syntax.
                let muted = ctx.configuration.theme.mutedText
                let body = ctx.configuration.theme.bodyText
                attrs.append((token.range, [.foregroundColor: body, .font: ctx.baseFont]))
                // Mute each `|` so the structure stays legible while editing.
                let end = NSMaxRange(token.range)
                var i = token.range.location
                while i < end {
                    if ctx.nsText.character(at: i) == 0x7C {   // '|'
                        attrs.append((NSRange(location: i, length: 1), [.foregroundColor: muted]))
                    }
                    i += 1
                }
                continue
            }

            // Outside the restyle scope the anchor attrs would be clipped away
            // at application time — skip the render lookup and anchor build
            // (occurrence bookkeeping above already ran, keeping IDs stable).
            if ctx.outsideScope(token.range) { continue }

            // See renderTable: resolve table colors under the text view's real appearance.
            let renderAppearance = ctx.layoutBridge?.firstTextContainer?.textView?.effectiveAppearance
                ?? NSApp.effectiveAppearance
            // Cells wrap to the container width (Obsidian-style); the render
            // only exceeds it when the per-column floors genuinely don't fit,
            // in which case the scrollable overlay below takes over.
            let containerWidth = effectiveContainerWidth(for: ctx)
            let (image, rendered) = tableImage(
                for: source,
                parsed: parsed,
                ctx: ctx,
                appearance: renderAppearance,
                availableWidth: containerWidth
            )
            if rendered { renderedCount += 1 }
            let imageBounds = CGRect(x: 0, y: 0, width: image.size.width, height: image.size.height)
            // Wide tables → scrollable mode (NSScrollView overlay); narrow → collapsed.
            let isWide = image.size.width > containerWidth + 0.5
            let computedSourceID = stableTableSourceID(
                for: source,
                occurrenceIndex: occurrenceIndex
            )
            let mode: RenderedStandaloneBlockMode = isWide
                ? .collapsedSourceScrollable(
                    markerTexts: [],
                    displayWidth: containerWidth,
                    sourceID: computedSourceID
                )
                : .collapsedSource(markerTexts: [])
            _ = appendRenderedStandaloneBlock(
                for: token,
                rawContent: source,
                image: image,
                imageBounds: imageBounds,
                paragraphSpacingBefore: ctx.baseDefaultLineHeight * 0.5,
                paragraphSpacing: ctx.baseDefaultLineHeight * 0.5,
                alignment: .left,
                mode: mode,
                ctx: ctx,
                attrs: &attrs
            )
        }
        if tableCount > 0 {
            let ms = Double(DispatchTime.now().uptimeNanoseconds - tablesT0) / 1_000_000
            let metaMs = Double(metaNanos) / 1_000_000
            PerfTrace.note { "styleTables scanned=\(tableCount) tables (skipped=\(skippedCount)), re-rendered=\(renderedCount) NSImage in \(String(format: "%.2f", ms))ms (substring+meta=\(String(format: "%.2f", metaMs))ms)" }
        }
        return attrs
    }

    // MARK: - Parsing

    static func parseTableSource(_ source: String) -> ParsedTable? {
        let rawLines = source.components(separatedBy: CharacterSet.newlines)
        let lines = rawLines.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        guard lines.count >= 2 else { return nil }

        let header = parseTableRow(lines[0])
        let alignments = parseTableAlignments(lines[1])
        guard !header.isEmpty, !alignments.isEmpty else { return nil }

        let columnCount = max(header.count, alignments.count)
        let bodyLines = Array(lines.dropFirst(2))

        func pad<T>(_ array: [T], to count: Int, with fill: T) -> [T] {
            if array.count == count { return array }
            if array.count > count { return Array(array.prefix(count)) }
            return array + Array(repeating: fill, count: count - array.count)
        }

        let paddedHeader = pad(header, to: columnCount, with: "")
        let paddedAlign = pad(alignments, to: columnCount, with: .left)
        let rows = bodyLines.map { pad(parseTableRow($0), to: columnCount, with: "") }

        return ParsedTable(header: paddedHeader, alignments: paddedAlign, rows: rows)
    }

    private static func parseTableRow(_ line: String) -> [String] {
        var s = line.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("|") { s.removeFirst() }
        if s.hasSuffix("|") { s.removeLast() }
        return s.split(separator: "|", omittingEmptySubsequences: false).map {
            $0.trimmingCharacters(in: .whitespaces)
        }
    }

    private static func parseTableAlignments(_ line: String) -> [TableAlignment] {
        let cells = parseTableRow(line)
        return cells.map { cell in
            let trimmed = cell.trimmingCharacters(in: .whitespaces)
            let leading = trimmed.hasPrefix(":")
            let trailing = trimmed.hasSuffix(":")
            switch (leading, trailing) {
            case (true, true): return .center
            case (false, true): return .right
            default: return .left
            }
        }
    }

    // MARK: - Inline-formatted cell strings

    /// Raw cell → `NSAttributedString`: inline markdown applied, markers stripped, LaTeX as attachments.
    static func formattedCellString(
        _ raw: String,
        baseFont: NSFont,
        header: Bool,
        theme: MarkdownEditorTheme,
        codeBackgroundColor: NSColor,
        latex: any LatexRenderer,
        extensions: [any MarkdownExtension] = []
    ) -> NSAttributedString {
        let descriptor = baseFont.fontDescriptor
        let pointSize = baseFont.pointSize
        let codeFont = NSFont.monospacedSystemFont(ofSize: pointSize, weight: .regular)
        let startFont = header
            ? (NSFont(descriptor: descriptor.withSymbolicTraits(.bold), size: pointSize) ?? baseFont)
            : baseFont
        let out = NSMutableAttributedString()
        var extensionsByID: [String: any MarkdownExtension] = [:]
        for ext in extensions { extensionsByID[ext.id] = ext }
        appendInlineCell(
            InlineParser.parse(raw, registry: ExtensionRegistry(extensions: extensions)),
            in: raw as NSString, into: out,
            font: startFont, baseDescriptor: descriptor, pointSize: pointSize,
            codeFont: codeFont, theme: theme, codeBackgroundColor: codeBackgroundColor, latex: latex,
            extensionsByID: extensionsByID
        )
        return out
    }

    /// Compose `current`'s bold/italic traits with `kind` so nested emphasis stacks (italic+bold).
    private static func composeEmphasis(
        _ current: NSFont, _ kind: EmphasisKind,
        baseDescriptor: NSFontDescriptor, pointSize: CGFloat
    ) -> NSFont {
        var traits = current.fontDescriptor.symbolicTraits.intersection([.bold, .italic])
        switch kind {
        case .bold: traits.insert(.bold)
        case .italic: traits.insert(.italic)
        case .boldItalic: traits.formUnion([.bold, .italic])
        }
        return NSFont(descriptor: baseDescriptor.withSymbolicTraits(traits), size: pointSize) ?? current
    }

    /// Walk the inline AST into marker-stripped runs; LaTeX as attachments, links/embeds emitted raw.
    private static func appendInlineCell(
        _ nodes: [InlineNode],
        in ns: NSString,
        into out: NSMutableAttributedString,
        font: NSFont,
        baseDescriptor: NSFontDescriptor,
        pointSize: CGFloat,
        codeFont: NSFont,
        theme: MarkdownEditorTheme,
        codeBackgroundColor: NSColor,
        latex: any LatexRenderer,
        extensionsByID: [String: any MarkdownExtension] = [:]
    ) {
        func recurse(_ children: [InlineNode], _ f: NSFont) {
            appendInlineCell(children, in: ns, into: out, font: f, baseDescriptor: baseDescriptor,
                             pointSize: pointSize, codeFont: codeFont, theme: theme,
                             codeBackgroundColor: codeBackgroundColor, latex: latex,
                             extensionsByID: extensionsByID)
        }
        func appendPlain(_ range: NSRange, _ f: NSFont) {
            out.append(NSAttributedString(string: ns.substring(with: range),
                                          attributes: [.font: f, .foregroundColor: theme.bodyText]))
        }
        for node in nodes {
            switch node {
            case .text(let r):
                appendPlain(r, font)
            case .escape(_, let character, _):
                appendPlain(character, font)
            case .emphasis(let kind, _, _, let children):
                recurse(children, composeEmphasis(font, kind, baseDescriptor: baseDescriptor, pointSize: pointSize))
            case .ext(let extNode):
                let start = out.length
                if extNode.children.isEmpty {
                    appendPlain(extNode.contentRange, font)
                } else {
                    recurse(extNode.children, font)
                }
                if out.length > start, let ext = extensionsByID[extNode.extensionID] {
                    out.addAttributes(ext.contentAttributes(theme: theme),
                                      range: NSRange(location: start, length: out.length - start))
                }
            case .code(_, let content):
                out.append(NSAttributedString(string: ns.substring(with: content), attributes: [
                    .font: codeFont, .backgroundColor: codeBackgroundColor, .foregroundColor: theme.bodyText
                ]))
            case .inlineLatex(let range, let content, _):
                if let entry = latex.render(latex: ns.substring(with: content), fontSize: pointSize, theme: theme) {
                    let attachment = NSTextAttachment()
                    attachment.image = entry.image
                    attachment.bounds = CGRect(x: 0, y: entry.baselineOffset,
                                               width: entry.size.width, height: entry.size.height)
                    out.append(NSAttributedString(attachment: attachment))
                } else {
                    appendPlain(range, font)   // renderer unavailable → keep raw `$…$`
                }
            case .link(let range, _, _, _, _),
                 .image(let range, _, _, _),
                 .wikiLink(let range, _, _, _),
                 .imageEmbed(let range, _, _):
                appendPlain(range, font)
            }
        }
    }

    // MARK: - Rendering

    private static func renderTable(
        _ table: ParsedTable,
        baseFont: NSFont,
        theme: MarkdownEditorTheme,
        codeBackgroundColor: NSColor,
        latex: any LatexRenderer,
        appearance: NSAppearance,
        availableWidth: CGFloat,
        extensions: [any MarkdownExtension] = []
    ) -> NSImage {
        let columnCount = table.alignments.count
        let cellHPadding: CGFloat = 12
        let cellVPadding: CGFloat = 6
        let borderWidth: CGFloat = 1
        // Resolve under the real appearance: `.withAlphaComponent()` freezes a dynamic color otherwise.
        func mutedColor(alpha: CGFloat) -> NSColor {
            var resolved: NSColor = theme.mutedText
            appearance.performAsCurrentDrawingAppearance {
                resolved = theme.mutedText.usingColorSpace(.sRGB) ?? theme.mutedText
            }
            return resolved.withAlphaComponent(alpha)
        }
        let borderColor = mutedColor(alpha: 0.5)
        let baseLineHeight: CGFloat = ceil(baseFont.ascender - baseFont.descender + baseFont.leading)
        let minColumnContentWidth: CGFloat = 16

        // Pre-format every cell so width measurement and drawing share one NSAttributedString.
        let headerCells = table.header.map {
            formattedCellString(
                $0, baseFont: baseFont, header: true, theme: theme,
                codeBackgroundColor: codeBackgroundColor, latex: latex,
                extensions: extensions
            )
        }
        let bodyCells = table.rows.map { row in
            row.map {
                formattedCellString(
                    $0, baseFont: baseFont, header: false, theme: theme,
                    codeBackgroundColor: codeBackgroundColor, latex: latex,
                    extensions: extensions
                )
            }
        }

        // CSS automatic table layout (W3C 17.5.2.2), which is what browser-based
        // editors like Obsidian get for free: each column has a MAXIMUM width
        // (content on one line) and a MINIMUM width (MCW — content may wrap but
        // must not overflow, i.e. the widest unbreakable whitespace-separated
        // segment). Measured segment-by-segment: a too-narrow boundingRect
        // would emergency-break INSIDE words and understate the minimum.
        func widestUnbreakableSegment(_ cell: NSAttributedString) -> CGFloat {
            let str = cell.string as NSString
            let whitespace = CharacterSet.whitespacesAndNewlines
            var widest: CGFloat = 0
            var segStart = -1
            for i in 0...str.length {
                let isBreak = i == str.length || {
                    guard let scalar = Unicode.Scalar(str.character(at: i)) else { return false }
                    return whitespace.contains(scalar)
                }()
                if isBreak {
                    if segStart >= 0 {
                        let segment = cell.attributedSubstring(from: NSRange(location: segStart, length: i - segStart))
                        widest = max(widest, ceil(segment.size().width))
                        segStart = -1
                    }
                } else if segStart < 0 {
                    segStart = i
                }
            }
            return widest
        }
        var maxWidths = [CGFloat](repeating: minColumnContentWidth, count: columnCount)
        var minWidths = [CGFloat](repeating: minColumnContentWidth, count: columnCount)
        func considerCell(_ cell: NSAttributedString, col: Int) {
            maxWidths[col] = max(maxWidths[col], ceil(cell.size().width))
            minWidths[col] = max(minWidths[col], widestUnbreakableSegment(cell))
        }
        for (i, cell) in headerCells.enumerated() where i < columnCount {
            considerCell(cell, col: i)
        }
        for row in bodyCells {
            for (i, cell) in row.enumerated() where i < columnCount {
                considerCell(cell, col: i)
            }
        }

        // Distribute the available width:
        // - everything fits on one line → natural (maximum) widths;
        // - too wide → shrink to the available width, but never below a
        //   column's longest unbreakable word; the slack above the minimums is
        //   distributed proportionally to each column's (max − min) stretch;
        // - even the minimums don't fit (many-column tables) → columns stay at
        //   their minimums, the table renders wider than the container, and
        //   the horizontal-scroll overlay takes over as before.
        let chrome = CGFloat(columnCount) * 2 * cellHPadding
            + CGFloat(columnCount + 1) * borderWidth
        let contentAvailable = availableWidth - chrome
        let sumMax = maxWidths.reduce(0, +)
        let sumMin = minWidths.reduce(0, +)
        var columnWidths = maxWidths
        if contentAvailable > 0, sumMax > contentAvailable {
            if sumMin >= contentAvailable {
                columnWidths = minWidths
            } else {
                let extra = contentAvailable - sumMin
                let totalStretch = sumMax - sumMin
                columnWidths = zip(minWidths, maxWidths).map { mn, mx in
                    mn + ((mx - mn) / totalStretch * extra).rounded(.down)
                }
            }
        }

        // Per-row heights: each row is as tall as its tallest (wrapped) cell.
        func cellHeight(_ cell: NSAttributedString, col: Int) -> CGFloat {
            let bounds = cell.boundingRect(
                with: NSSize(width: columnWidths[col], height: .greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin]
            )
            return ceil(bounds.height)
        }
        let rowCount = 1 + table.rows.count // header + body rows
        var rowContentHeights = [CGFloat](repeating: baseLineHeight, count: rowCount)
        for (i, cell) in headerCells.enumerated() where i < columnCount {
            rowContentHeights[0] = max(rowContentHeights[0], cellHeight(cell, col: i))
        }
        for (rowIdx, row) in bodyCells.enumerated() {
            for (i, cell) in row.enumerated() where i < columnCount {
                rowContentHeights[rowIdx + 1] = max(rowContentHeights[rowIdx + 1], cellHeight(cell, col: i))
            }
        }

        let totalWidth = columnWidths.reduce(0, +)
            + CGFloat(columnCount) * 2 * cellHPadding
            + CGFloat(columnCount + 1) * borderWidth
        let totalHeight = rowContentHeights.reduce(0) { $0 + $1 + 2 * cellVPadding }
            + CGFloat(rowCount + 1) * borderWidth

        let size = NSSize(width: totalWidth, height: totalHeight)

        // Pre-compute layout offsets (top-down coords; drawing runs flipped).
        var columnLeft = [CGFloat](repeating: 0, count: columnCount + 1)
        columnLeft[0] = borderWidth
        for i in 0..<columnCount {
            columnLeft[i + 1] = columnLeft[i] + columnWidths[i] + 2 * cellHPadding + borderWidth
        }
        var rowTop = [CGFloat](repeating: 0, count: rowCount + 1)
        rowTop[0] = borderWidth
        for i in 0..<rowCount {
            rowTop[i + 1] = rowTop[i] + rowContentHeights[i] + 2 * cellVPadding + borderWidth
        }

        let alignments = table.alignments
        let headerFill = mutedColor(alpha: 0.08)

        // Flipped image so AppKit handles the y-flip; a manual transform mirror would flip glyphs too.
        return NSImage(size: size, flipped: true) { _ in
            // Header row fill
            headerFill.setFill()
            NSBezierPath(rect: NSRect(
                x: borderWidth,
                y: borderWidth,
                width: size.width - 2 * borderWidth,
                height: rowContentHeights[0] + 2 * cellVPadding
            )).fill()

            // Outer border
            borderColor.setStroke()
            let outer = NSBezierPath(rect: NSRect(
                x: borderWidth / 2,
                y: borderWidth / 2,
                width: size.width - borderWidth,
                height: size.height - borderWidth
            ))
            outer.lineWidth = borderWidth
            outer.stroke()

            // Internal separators
            let separators = NSBezierPath()
            separators.lineWidth = borderWidth
            for i in 1..<columnCount {
                let x = columnLeft[i] - borderWidth / 2
                separators.move(to: NSPoint(x: x, y: 0))
                separators.line(to: NSPoint(x: x, y: size.height))
            }
            for i in 1..<rowCount {
                let y = rowTop[i] - borderWidth / 2
                separators.move(to: NSPoint(x: 0, y: y))
                separators.line(to: NSPoint(x: size.width, y: y))
            }
            separators.stroke()

            func drawCell(_ s: NSAttributedString, col: Int, row: Int) {
                guard col < columnCount else { return }
                let cellLeft = columnLeft[col] + cellHPadding
                let cellRight = columnLeft[col + 1] - borderWidth - cellHPadding
                let cellContentWidth = cellRight - cellLeft
                // Align via NSParagraphStyle; word-wrap fills the row height
                // measured above (long words fall back to character breaks).
                let paragraph = NSMutableParagraphStyle()
                switch alignments[col] {
                case .left:   paragraph.alignment = .left
                case .center: paragraph.alignment = .center
                case .right:  paragraph.alignment = .right
                }
                paragraph.lineBreakMode = .byWordWrapping
                let aligned = NSMutableAttributedString(attributedString: s)
                aligned.addAttribute(
                    .paragraphStyle,
                    value: paragraph,
                    range: NSRange(location: 0, length: aligned.length)
                )
                let drawRect = NSRect(
                    x: cellLeft,
                    y: rowTop[row] + cellVPadding,
                    width: cellContentWidth,
                    height: rowContentHeights[row]
                )
                aligned.draw(with: drawRect, options: [.usesLineFragmentOrigin], context: nil)
            }

            for (col, cell) in headerCells.enumerated() {
                drawCell(cell, col: col, row: 0)
            }
            for (rowIdx, row) in bodyCells.enumerated() {
                for (col, cell) in row.enumerated() {
                    drawCell(cell, col: col, row: rowIdx + 1)
                }
            }
            return true
        }
    }

    // MARK: - Scrollable table helpers

    /// Container width with fallback chain for "styler runs before layout" case.
    static func effectiveContainerWidth(for ctx: StylingContext) -> CGFloat {
        if let container = ctx.layoutBridge?.firstTextContainer {
            let raw = container.size.width
            if raw.isFinite, raw > 0, raw < 100_000 { return raw }
            if let textView = container.textView {
                let inset = textView.textContainerInset
                let usable = textView.bounds.width - inset.width * 2
                if usable.isFinite, usable > 0 { return usable }
                let frameUsable = textView.frame.width - inset.width * 2
                if frameUsable.isFinite, frameUsable > 0 { return frameUsable }
            }
        }
        return 500
    }

    /// Content-only hash; intentionally collides for identical tables — disambiguated by occurrence index.
    static func stableTableContentHash(for source: String) -> Int {
        var hasher = Hasher()
        hasher.combine("table-overlay-v1")
        hasher.combine(source)
        return hasher.finalize()
    }

    /// Per-instance ID = (content, nth-occurrence); stable across re-styles so scroll offsets persist.
    static func stableTableSourceID(for source: String, occurrenceIndex: Int) -> Int {
        var hasher = Hasher()
        hasher.combine("table-overlay-v2")
        hasher.combine(source)
        hasher.combine(occurrenceIndex)
        return hasher.finalize()
    }
}
