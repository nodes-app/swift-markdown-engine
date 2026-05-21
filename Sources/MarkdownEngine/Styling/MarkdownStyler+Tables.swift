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
        for (idx, token) in ctx.tokens.enumerated() where token.kind == .table {
            // The tokenizer already drops table matches that overlap a
            // fenced code block, so we don't re-check that here. (The
            // generic isInsideCodeBlock helper also flags overlap with
            // inline code, which would falsely reject any table that
            // contains a `…` cell.)
            attrs.append((token.range, [.spellingState: 0]))

            let source = ctx.nsText.substring(with: token.range)
            guard let parsed = parseTableSource(source) else { continue }

            let isActive = ctx.activeTokenIndices.contains(idx)
            if isActive {
                // Caret inside the table — show source so the user can
                // edit. We mute pipes so the structure stays legible
                // without dominating, matching how the rest of the engine
                // dims syntax characters.
                let muted = ctx.configuration.theme.mutedText
                let body = ctx.configuration.theme.bodyText
                attrs.append((token.range, [.foregroundColor: body, .font: ctx.baseFont]))
                if let pipeRegex = try? NSRegularExpression(pattern: "\\|") {
                    for m in pipeRegex.matches(in: ctx.text, options: [], range: token.range) {
                        attrs.append((m.range, [.foregroundColor: muted]))
                    }
                }
                continue
            }

            let image = renderTable(
                parsed,
                baseFont: ctx.baseFont,
                theme: ctx.configuration.theme,
                codeBackgroundColor: ctx.codeBackgroundColor,
                latex: ctx.services.latex
            )
            let imageBounds = CGRect(x: 0, y: 0, width: image.size.width, height: image.size.height)
            _ = appendRenderedStandaloneBlock(
                for: token,
                rawContent: source,
                image: image,
                imageBounds: imageBounds,
                paragraphSpacingBefore: ctx.baseDefaultLineHeight * 0.5,
                paragraphSpacing: ctx.baseDefaultLineHeight * 0.5,
                alignment: .left,
                mode: .collapsedSource(markerTexts: []),
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

    /// Convert a raw cell string (which may contain inline markdown like
    /// `**bold**`, `*italic*`, `` `code` ``, `~~strike~~`, `$math$`) into an
    /// `NSAttributedString`. Markers themselves are stripped so the rendered
    /// table image only shows the formatted result. LaTeX spans become
    /// `NSTextAttachment` images so the math metrics flow through to
    /// column-width measurement. Header cells start out bold.
    private static func formattedCellString(
        _ raw: String,
        baseFont: NSFont,
        header: Bool,
        theme: MarkdownEditorTheme,
        codeBackgroundColor: NSColor,
        latex: any LatexRenderer
    ) -> NSAttributedString {
        let descriptor = baseFont.fontDescriptor
        let pointSize = baseFont.pointSize
        let regularFont = baseFont
        let boldFont = NSFont(descriptor: descriptor.withSymbolicTraits(.bold), size: pointSize) ?? baseFont
        let italicFont = NSFont(descriptor: descriptor.withSymbolicTraits(.italic), size: pointSize) ?? baseFont
        let boldItalicFont = NSFont(descriptor: descriptor.withSymbolicTraits([.bold, .italic]), size: pointSize) ?? boldFont
        let codeFont = NSFont.monospacedSystemFont(ofSize: pointSize, weight: .regular)

        let baseAttrs: [NSAttributedString.Key: Any] = [
            .font: header ? boldFont : regularFont,
            .foregroundColor: theme.bodyText
        ]

        let result = NSMutableAttributedString(string: raw, attributes: baseAttrs)

        // For each pattern: find matches, and for each match (in reverse so
        // earlier offsets stay stable), strip the markers and apply attrs
        // on the inner content. The `attrsForCurrentFont` closure receives
        // the font already set on the inner range so we can compose
        // bold-on-italic, italic-on-bold, etc.
        func applyPattern(
            _ pattern: String,
            prefix: Int,
            suffix: Int,
            attrsForCurrentFont: (NSFont) -> [NSAttributedString.Key: Any]
        ) {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { return }
            let scan = result.string as NSString
            let matches = regex.matches(in: result.string, range: NSRange(location: 0, length: scan.length))
            for m in matches.reversed() {
                let full = m.range
                let inner = NSRange(location: full.location + prefix, length: full.length - prefix - suffix)
                guard inner.length > 0,
                      inner.location >= 0,
                      inner.location + inner.length <= result.length else { continue }
                let currentFont = (result.attribute(.font, at: inner.location, effectiveRange: nil) as? NSFont) ?? regularFont
                let innerString = (result.string as NSString).substring(with: inner)
                let replacement = NSMutableAttributedString(string: innerString)
                // Carry over existing attributes on the inner range so
                // already-applied formatting (e.g. inline-code processed
                // earlier) survives the marker strip.
                result.enumerateAttributes(in: inner, options: []) { existing, range, _ in
                    let local = NSRange(location: range.location - inner.location, length: range.length)
                    replacement.addAttributes(existing, range: local)
                }
                replacement.addAttributes(
                    attrsForCurrentFont(currentFont),
                    range: NSRange(location: 0, length: replacement.length)
                )
                result.replaceCharacters(in: full, with: replacement)
            }
        }

        // LaTeX first — replace each `$...$` with an inline image so the
        // markers and content disappear from later passes. We use
        // `NSTextAttachment` so column-width measurement and drawing both
        // pick up the image's intrinsic size and baseline offset.
        if let latexRegex = try? NSRegularExpression(pattern: #"\$([^$]+)\$"#) {
            let scan = result.string as NSString
            let matches = latexRegex.matches(in: result.string, range: NSRange(location: 0, length: scan.length))
            for m in matches.reversed() {
                let full = m.range
                let inner = NSRange(location: full.location + 1, length: full.length - 2)
                guard inner.length > 0 else { continue }
                let latexContent = (result.string as NSString).substring(with: inner)
                guard let entry = latex.render(latex: latexContent, fontSize: pointSize, theme: theme) else { continue }
                let attachment = NSTextAttachment()
                attachment.image = entry.image
                attachment.bounds = CGRect(
                    x: 0,
                    y: entry.baselineOffset,
                    width: entry.size.width,
                    height: entry.size.height
                )
                let replacement = NSAttributedString(attachment: attachment)
                result.replaceCharacters(in: full, with: replacement)
            }
        }

        // Inline code next so its content can't be re-interpreted.
        applyPattern(#"`([^`]+)`"#, prefix: 1, suffix: 1) { _ in
            [
                .font: codeFont,
                .backgroundColor: codeBackgroundColor
            ]
        }
        applyPattern(#"~~([^~]+)~~"#, prefix: 2, suffix: 2) { _ in
            [
                .strikethroughStyle: NSUnderlineStyle.single.rawValue,
                .strikethroughColor: theme.bodyText
            ]
        }
        applyPattern(#"\*\*\*([^*]+)\*\*\*"#, prefix: 3, suffix: 3) { _ in
            [.font: boldItalicFont]
        }
        applyPattern(#"\*\*([^*]+)\*\*"#, prefix: 2, suffix: 2) { current in
            current.fontDescriptor.symbolicTraits.contains(.italic)
                ? [.font: boldItalicFont]
                : [.font: boldFont]
        }
        applyPattern(#"\*([^*]+)\*"#, prefix: 1, suffix: 1) { current in
            current.fontDescriptor.symbolicTraits.contains(.bold)
                ? [.font: boldItalicFont]
                : [.font: italicFont]
        }
        return result
    }

    // MARK: - Rendering

    private static func renderTable(
        _ table: ParsedTable,
        baseFont: NSFont,
        theme: MarkdownEditorTheme,
        codeBackgroundColor: NSColor,
        latex: any LatexRenderer
    ) -> NSImage {
        let columnCount = table.alignments.count
        let cellHPadding: CGFloat = 12
        let cellVPadding: CGFloat = 6
        let borderWidth: CGFloat = 1
        let borderColor = theme.mutedText.withAlphaComponent(0.5)
        let baseLineHeight: CGFloat = ceil(baseFont.ascender - baseFont.descender + baseFont.leading)
        let minColumnContentWidth: CGFloat = 16

        // Pre-format every cell so column-width measurement and drawing
        // both use the same NSAttributedString (incl. bold/italic/code
        // metrics + LaTeX attachment sizes).
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

        // Pre-compute layout offsets (top-down coords; the drawing handler
        // runs in a flipped context so this reads naturally).
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
        let headerFill = theme.mutedText.withAlphaComponent(0.08)

        // Use a flipped image so AppKit drawing routines (NSBezierPath,
        // NSAttributedString.draw) handle the y-flip themselves; manually
        // applying an NSAffineTransform mirror flips the glyphs as well.
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
                // Use NSParagraphStyle's alignment within the cell-content
                // rect rather than computing the x-offset manually. The
                // text engine then handles ellipsis/clipping consistently
                // and we don't have to second-guess where the line origin
                // ends up in flipped coords.
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
}
