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

    static func styleTables(_ ctx: StylingContext) -> [StyledRange] {
        var attrs: [StyledRange] = []
        // Per-content occurrence counter so identical tables get distinct sourceIDs.
        var occurrenceByContentHash: [Int: Int] = [:]
        for (idx, token) in ctx.tokens.enumerated() where token.kind == .table {
            // Tokenizer already drops tables overlapping fenced code, so no re-check here.
            attrs.append((token.range, [.spellingState: 0]))

            let source = ctx.nsText.substring(with: token.range)
            guard let parsed = parseTableSource(source) else { continue }

            // Advance occurrence index even for active tables so inactive duplicates stay stable.
            let contentHash = stableTableContentHash(for: source)
            let occurrenceIndex = occurrenceByContentHash[contentHash, default: 0]
            occurrenceByContentHash[contentHash] = occurrenceIndex + 1

            // In the reading view (all markers concealed) the table stays rendered
            // even when the caret is in it — editing structure is a Code-view job,
            // and keeping it rendered makes copy/paste of rows cleaner.
            let isActive = ctx.activeTokenIndices.contains(idx)
                && ctx.configuration.markerVisibility != .allHidden
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

            // See renderTable: resolve table colors under the text view's real appearance.
            let renderAppearance = ctx.layoutBridge?.firstTextContainer?.textView?.effectiveAppearance
                ?? NSApp.effectiveAppearance
            let image = renderTable(
                parsed,
                baseFont: ctx.baseFont,
                theme: ctx.configuration.theme,
                codeBackgroundColor: ctx.codeBackgroundColor,
                latex: ctx.services.latex,
                appearance: renderAppearance
            )
            let imageBounds = CGRect(x: 0, y: 0, width: image.size.width, height: image.size.height)
            // Wide tables → scrollable mode (NSScrollView overlay); narrow → collapsed.
            let containerWidth = effectiveContainerWidth(for: ctx)
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
        latex: any LatexRenderer
    ) -> NSAttributedString {
        let descriptor = baseFont.fontDescriptor
        let pointSize = baseFont.pointSize
        let codeFont = NSFont.monospacedSystemFont(ofSize: pointSize, weight: .regular)
        let startFont = header
            ? (NSFont(descriptor: descriptor.withSymbolicTraits(.bold), size: pointSize) ?? baseFont)
            : baseFont
        let out = NSMutableAttributedString()
        appendInlineCell(
            InlineParser.parse(raw), in: raw as NSString, into: out,
            font: startFont, baseDescriptor: descriptor, pointSize: pointSize,
            codeFont: codeFont, theme: theme, codeBackgroundColor: codeBackgroundColor, latex: latex
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
        latex: any LatexRenderer
    ) {
        func recurse(_ children: [InlineNode], _ f: NSFont) {
            appendInlineCell(children, in: ns, into: out, font: f, baseDescriptor: baseDescriptor,
                             pointSize: pointSize, codeFont: codeFont, theme: theme,
                             codeBackgroundColor: codeBackgroundColor, latex: latex)
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
            case .strikethrough(_, _, let children):
                let start = out.length
                recurse(children, font)
                if out.length > start {
                    out.addAttributes([
                        .strikethroughStyle: NSUnderlineStyle.single.rawValue,
                        .strikethroughColor: theme.bodyText
                    ], range: NSRange(location: start, length: out.length - start))
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
        appearance: NSAppearance
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
                codeBackgroundColor: codeBackgroundColor, latex: latex
            )
        }
        let bodyCells = table.rows.map { row in
            row.map {
                formattedCellString(
                    $0, baseFont: baseFont, header: false, theme: theme,
                    codeBackgroundColor: codeBackgroundColor, latex: latex
                )
            }
        }

        var columnWidths = [CGFloat](repeating: minColumnContentWidth, count: columnCount)
        var maxCellHeight: CGFloat = baseLineHeight
        func considerCell(_ cell: NSAttributedString, col: Int) {
            let size = cell.size()
            columnWidths[col] = max(columnWidths[col], ceil(size.width))
            maxCellHeight = max(maxCellHeight, ceil(size.height))
        }
        for (i, cell) in headerCells.enumerated() where i < columnCount {
            considerCell(cell, col: i)
        }
        for row in bodyCells {
            for (i, cell) in row.enumerated() where i < columnCount {
                considerCell(cell, col: i)
            }
        }

        let lineHeight = max(baseLineHeight, maxCellHeight)
        let rowCount = 1 + table.rows.count // header + body rows
        let totalWidth = columnWidths.reduce(0, +)
            + CGFloat(columnCount) * 2 * cellHPadding
            + CGFloat(columnCount + 1) * borderWidth
        let rowHeight = lineHeight + 2 * cellVPadding
        let totalHeight = CGFloat(rowCount) * rowHeight + CGFloat(rowCount + 1) * borderWidth

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
            rowTop[i + 1] = rowTop[i] + rowHeight + borderWidth
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
                height: rowHeight
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
                let availableWidth = cellRight - cellLeft
                // Align via NSParagraphStyle in the content rect so the text engine handles clipping.
                let paragraph = NSMutableParagraphStyle()
                switch alignments[col] {
                case .left:   paragraph.alignment = .left
                case .center: paragraph.alignment = .center
                case .right:  paragraph.alignment = .right
                }
                paragraph.lineBreakMode = .byClipping
                let aligned = NSMutableAttributedString(attributedString: s)
                aligned.addAttribute(
                    .paragraphStyle,
                    value: paragraph,
                    range: NSRange(location: 0, length: aligned.length)
                )
                let cellInnerTop = rowTop[row] + max(0, (rowHeight - lineHeight) / 2)
                let drawRect = NSRect(
                    x: cellLeft,
                    y: cellInnerTop,
                    width: availableWidth,
                    height: lineHeight
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
