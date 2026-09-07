#if os(iOS)
import UIKit

struct UIKitMarkdownStyler {
    let configuration: MarkdownEditorConfiguration
    let fontName: String
    let fontSize: CGFloat

    func attributedString(for text: String, selection: NSRange) -> NSAttributedString {
        let source = text as NSString
        let bodyFont = UIFont(name: fontName, size: fontSize) ?? .systemFont(ofSize: fontSize)
        let result = NSMutableAttributedString(
            string: text,
            attributes: [
                .font: bodyFont,
                .foregroundColor: configuration.theme.bodyText
            ]
        )

        guard !configuration.rawSourceMode, source.length > 0 else { return result }
        let tokens = MarkdownTokenizer.parseTokensViaAST(in: text)
        style(tokens: tokens, in: result, source: source, bodyFont: bodyFont, selection: selection)
        styleListsAndRules(in: result, source: source, bodyFont: bodyFont, selection: selection)
        styleStrikethrough(in: result, source: source, bodyFont: bodyFont, selection: selection)
        return result
    }

    private func style(
        tokens: [MarkdownToken],
        in result: NSMutableAttributedString,
        source: NSString,
        bodyFont: UIFont,
        selection: NSRange
    ) {
        for token in tokens {
            switch token.kind {
            case .italic:
                applyTraits(.traitItalic, range: token.contentRange, in: result, fallback: bodyFont)
            case .bold:
                applyTraits(.traitBold, range: token.contentRange, in: result, fallback: bodyFont)
            case .boldItalic:
                applyTraits([.traitBold, .traitItalic], range: token.contentRange, in: result, fallback: bodyFont)
            case .link, .wikiLink:
                result.addAttributes([
                    .foregroundColor: configuration.theme.link,
                    .underlineStyle: NSUnderlineStyle.single.rawValue
                ], range: token.contentRange)
            case .heading:
                let level = max(1, min(6, token.markerRanges.first?.length ?? 1))
                let scale: CGFloat = [1.72, 1.48, 1.28, 1.14, 1.05, 1.0][level - 1]
                result.addAttribute(.font, value: UIFont.systemFont(ofSize: fontSize * scale, weight: .bold), range: token.contentRange)
            case .blockquote:
                let paragraph = NSMutableParagraphStyle()
                paragraph.headIndent = fontSize
                paragraph.firstLineHeadIndent = fontSize
                result.addAttributes([
                    .foregroundColor: configuration.theme.quote,
                    .paragraphStyle: paragraph
                ], range: token.range)
            case .codeBlock:
                result.addAttributes([
                    .font: UIFont.monospacedSystemFont(ofSize: fontSize, weight: .regular),
                    .backgroundColor: configuration.theme.codeBackground
                ], range: token.range)
            case .inlineCode:
                result.addAttributes([
                    .font: UIFont.monospacedSystemFont(ofSize: fontSize * 0.94, weight: .regular),
                    .backgroundColor: configuration.theme.codeBackground
                ], range: token.contentRange)
            case .blockLatex, .inlineLatex:
                result.addAttributes([
                    .font: UIFont.monospacedSystemFont(ofSize: fontSize, weight: .regular),
                    .foregroundColor: configuration.theme.bodyText,
                    .backgroundColor: configuration.theme.codeBackground
                ], range: token.contentRange)
            case .imageEmbed, .imageLink:
                result.addAttributes([
                    .foregroundColor: configuration.theme.link,
                    .font: UIFont.systemFont(ofSize: fontSize, weight: .medium)
                ], range: token.contentRange)
            case .table:
                result.addAttributes([
                    .font: UIFont.monospacedSystemFont(ofSize: fontSize * 0.92, weight: .regular),
                    .backgroundColor: configuration.theme.codeBackground
                ], range: token.range)
            case .backslashEscape:
                break
            case .extensionSpan, .extensionBlock:
                break
            }

            let isActive = NSIntersectionRange(token.range, expandedSelection(selection)).length > 0
            for marker in token.markerRanges {
                if isActive {
                    result.addAttributes([.font: bodyFont, .foregroundColor: configuration.theme.mutedText], range: marker)
                } else {
                    hide(marker, in: result, unlessIntersecting: selection, bodyFont: bodyFont)
                }
            }
        }
    }

    private func styleListsAndRules(
        in result: NSMutableAttributedString,
        source: NSString,
        bodyFont: UIFont,
        selection: NSRange
    ) {
        for block in DocumentAST.parse(source as String) {
            switch block {
            case .list(_, let items):
                for item in items {
                    let paragraph = NSMutableParagraphStyle()
                    paragraph.headIndent = fontSize * 1.55
                    paragraph.firstLineHeadIndent = 0
                    result.addAttribute(.paragraphStyle, value: paragraph, range: item.range)
                    if let checkbox = item.checkbox {
                        let syntax = NSRange(
                            location: item.marker.location,
                            length: NSMaxRange(checkbox) - item.marker.location
                        )
                        let isActive = NSIntersectionRange(syntax, expandedSelection(selection)).length > 0
                        if isActive {
                            result.addAttribute(.foregroundColor, value: configuration.theme.mutedText, range: syntax)
                        } else {
                            result.addAttribute(.foregroundColor, value: UIColor.clear, range: item.marker)

                            let spacer = NSRange(
                                location: NSMaxRange(item.marker),
                                length: checkbox.location - NSMaxRange(item.marker)
                            )
                            if spacer.length > 0 {
                                result.addAttribute(.foregroundColor, value: UIColor.clear, range: spacer)
                            }

                            result.addAttributes([
                                .taskCheckbox: item.checked,
                                .taskCheckboxFont: bodyFont,
                                .taskCheckboxTint: item.checked
                                    ? configuration.theme.bodyText
                                    : configuration.theme.mutedText,
                                .font: UIFont.systemFont(ofSize: 0.01),
                                .foregroundColor: UIColor.clear
                            ], range: checkbox)

                            let postGap = NSRange(
                                location: NSMaxRange(checkbox),
                                length: item.contentRange.location - NSMaxRange(checkbox)
                            )
                            if postGap.length > 0 {
                                result.addAttributes([
                                    .font: UIFont.systemFont(ofSize: 0.01),
                                    .foregroundColor: UIColor.clear
                                ], range: postGap)
                            }
                        }
                    } else {
                        result.addAttribute(.foregroundColor, value: configuration.theme.mutedText, range: item.marker)
                    }
                    if item.checked {
                        result.addAttributes([
                            .strikethroughStyle: NSUnderlineStyle.single.rawValue,
                            .foregroundColor: configuration.theme.disabledText
                        ], range: item.contentRange)
                    }
                }
            case .thematicBreak(let range):
                result.addAttribute(.foregroundColor, value: configuration.theme.mutedText, range: range)
            default:
                break
            }
        }
    }

    private func styleStrikethrough(
        in result: NSMutableAttributedString,
        source: NSString,
        bodyFont: UIFont,
        selection: NSRange
    ) {
        applyDelimited(#"(?<!\\)(~~)(?=\S)(.+?)(?<=\S)\1"#, to: result, source: source, selection: selection, bodyFont: bodyFont) { range in
            result.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue, range: range)
        }
    }

    private func applyTraits(
        _ traits: UIFontDescriptor.SymbolicTraits,
        range: NSRange,
        in result: NSMutableAttributedString,
        fallback: UIFont
    ) {
        result.enumerateAttribute(.font, in: range) { value, run, _ in
            let font = value as? UIFont ?? fallback
            result.addAttribute(.font, value: font.withTraits(traits), range: run)
        }
    }

    private func styleBlocks(
        in result: NSMutableAttributedString,
        source: NSString,
        bodyFont: UIFont,
        selection: NSRange
    ) {
        var location = 0
        var insideFence = false
        while location < source.length {
            let lineRange = source.lineRange(for: NSRange(location: location, length: 0))
            let contentRange = lineContentRange(lineRange, source: source)
            let line = source.substring(with: contentRange)

            if let fence = firstMatch(#"^\s*```"#, in: line, offset: contentRange.location) {
                insideFence.toggle()
                result.addAttributes([
                    .font: UIFont.monospacedSystemFont(ofSize: fontSize, weight: .regular),
                    .foregroundColor: configuration.theme.mutedText,
                    .backgroundColor: configuration.theme.codeBackground
                ], range: lineRange)
                hide(fence, in: result, unlessIntersecting: selection, bodyFont: bodyFont)
            } else if insideFence {
                result.addAttributes([
                    .font: UIFont.monospacedSystemFont(ofSize: fontSize, weight: .regular),
                    .backgroundColor: configuration.theme.codeBackground
                ], range: lineRange)
            } else if let heading = firstMatch(#"^(#{1,6})[\t ]+"#, in: line, offset: contentRange.location) {
                let markerLength = markerLength(in: heading, source: source, characters: CharacterSet(charactersIn: "#"))
                let marker = NSRange(location: heading.location, length: markerLength)
                let level = max(1, min(6, markerLength))
                let scale: CGFloat = [1.72, 1.48, 1.28, 1.14, 1.05, 1.0][level - 1]
                result.addAttribute(.font, value: UIFont.systemFont(ofSize: fontSize * scale, weight: .bold), range: contentRange)
                result.addAttribute(.foregroundColor, value: configuration.theme.headingMarker, range: heading)
                hide(heading, in: result, unlessIntersecting: selection, bodyFont: bodyFont)
                revealContent(after: heading, lineRange: contentRange, in: result, font: UIFont.systemFont(ofSize: fontSize * scale, weight: .bold))
                _ = marker
            } else if let quote = firstMatch(#"^\s*>[\t ]?"#, in: line, offset: contentRange.location) {
                let paragraph = NSMutableParagraphStyle()
                paragraph.headIndent = fontSize
                paragraph.firstLineHeadIndent = fontSize
                result.addAttributes([.foregroundColor: configuration.theme.quote, .paragraphStyle: paragraph], range: contentRange)
                hide(quote, in: result, unlessIntersecting: selection, bodyFont: bodyFont)
            } else if isThematicBreak(line) {
                result.addAttributes([.foregroundColor: configuration.theme.mutedText], range: contentRange)
            }

            styleListLine(line, lineRange: contentRange, in: result, source: source, bodyFont: bodyFont, selection: selection)
            location = NSMaxRange(lineRange)
        }
    }

    private func styleListLine(
        _ line: String,
        lineRange: NSRange,
        in result: NSMutableAttributedString,
        source: NSString,
        bodyFont: UIFont,
        selection: NSRange
    ) {
        guard let marker = firstMatch(#"^\s*(?:[-+*]|\d+[.)])[\t ]+"#, in: line, offset: lineRange.location) else { return }
        let paragraph = NSMutableParagraphStyle()
        paragraph.headIndent = fontSize * 1.55
        paragraph.firstLineHeadIndent = 0
        paragraph.tabStops = [NSTextTab(textAlignment: .left, location: paragraph.headIndent)]
        result.addAttribute(.paragraphStyle, value: paragraph, range: lineRange)
        result.addAttribute(.foregroundColor, value: configuration.theme.mutedText, range: marker)

        if let task = firstMatch(#"^\s*[-+*][\t ]+\[([ xX])\][\t ]+"#, in: line, offset: lineRange.location) {
            let taskText = source.substring(with: task)
            let checked = taskText.range(of: "[x]", options: .caseInsensitive) != nil
            result.addAttribute(.foregroundColor, value: configuration.theme.mutedText, range: task)
            if checked {
                let contentStart = NSMaxRange(task)
                let content = NSRange(location: contentStart, length: max(0, NSMaxRange(lineRange) - contentStart))
                result.addAttributes([
                    .strikethroughStyle: NSUnderlineStyle.single.rawValue,
                    .foregroundColor: configuration.theme.disabledText
                ], range: content)
            }
        }
    }

    private func styleInline(
        in result: NSMutableAttributedString,
        source: NSString,
        bodyFont: UIFont,
        selection: NSRange
    ) {
        applyDelimited(#"(?<!\\)(\*\*\*|___)(?=\S)(.+?)(?<=\S)\1"#, to: result, source: source, selection: selection, bodyFont: bodyFont) { range in
            result.addAttribute(.font, value: UIFont.systemFont(ofSize: fontSize, weight: .bold).withTraits(.traitItalic), range: range)
        }
        applyDelimited(#"(?<!\\)(\*\*|__)(?=\S)(.+?)(?<=\S)\1"#, to: result, source: source, selection: selection, bodyFont: bodyFont) { range in
            result.addAttribute(.font, value: UIFont.systemFont(ofSize: fontSize, weight: .bold), range: range)
        }
        applyDelimited(#"(?<!\\)(\*|_)(?=\S)(.+?)(?<=\S)\1"#, to: result, source: source, selection: selection, bodyFont: bodyFont) { range in
            result.addAttribute(.font, value: bodyFont.withTraits(.traitItalic), range: range)
        }
        applyDelimited(#"(?<!\\)(~~)(?=\S)(.+?)(?<=\S)\1"#, to: result, source: source, selection: selection, bodyFont: bodyFont) { range in
            result.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue, range: range)
        }
        applyDelimited(#"(?<!\\)(`)([^`\n]+)\1"#, to: result, source: source, selection: selection, bodyFont: bodyFont) { range in
            result.addAttributes([
                .font: UIFont.monospacedSystemFont(ofSize: fontSize * 0.94, weight: .regular),
                .backgroundColor: configuration.theme.codeBackground
            ], range: range)
        }

        applyLinks(in: result, source: source, selection: selection, bodyFont: bodyFont)
    }

    private func applyDelimited(
        _ pattern: String,
        to result: NSMutableAttributedString,
        source: NSString,
        selection: NSRange,
        bodyFont: UIFont,
        style: (NSRange) -> Void
    ) {
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return }
        let matches = expression.matches(in: source as String, range: NSRange(location: 0, length: source.length))
        for match in matches where match.numberOfRanges >= 3 {
            let content = match.range(at: 2)
            style(content)
            let delimiterLength = match.range(at: 1).length
            hide(NSRange(location: match.range.location, length: delimiterLength), in: result, unlessIntersecting: selection, bodyFont: bodyFont)
            hide(NSRange(location: NSMaxRange(match.range) - delimiterLength, length: delimiterLength), in: result, unlessIntersecting: selection, bodyFont: bodyFont)
        }
    }

    private func applyLinks(
        in result: NSMutableAttributedString,
        source: NSString,
        selection: NSRange,
        bodyFont: UIFont
    ) {
        guard let expression = try? NSRegularExpression(pattern: #"(?<!!)\[([^\]\n]+)\]\(([^)\n]+)\)"#) else { return }
        for match in expression.matches(in: source as String, range: NSRange(location: 0, length: source.length)) where match.numberOfRanges >= 3 {
            let label = match.range(at: 1)
            let destination = source.substring(with: match.range(at: 2))
            result.addAttributes([.foregroundColor: configuration.theme.link, .underlineStyle: NSUnderlineStyle.single.rawValue], range: label)
            if let url = URL(string: destination) {
                result.addAttribute(.link, value: url, range: label)
            }
            let open = NSRange(location: match.range.location, length: 1)
            let suffix = NSRange(location: NSMaxRange(label), length: NSMaxRange(match.range) - NSMaxRange(label))
            hide(open, in: result, unlessIntersecting: selection, bodyFont: bodyFont)
            hide(suffix, in: result, unlessIntersecting: selection, bodyFont: bodyFont)
        }
    }

    private func hide(_ range: NSRange, in result: NSMutableAttributedString, unlessIntersecting selection: NSRange, bodyFont: UIFont) {
        guard NSIntersectionRange(range, expandedSelection(selection)).length == 0 else {
            result.addAttributes([.font: bodyFont, .foregroundColor: configuration.theme.mutedText], range: range)
            return
        }
        result.addAttributes([.font: UIFont.systemFont(ofSize: 0.01), .foregroundColor: UIColor.clear], range: range)
    }

    private func expandedSelection(_ selection: NSRange) -> NSRange {
        selection.length == 0 ? NSRange(location: max(0, selection.location - 1), length: 2) : selection
    }

    private func revealContent(after marker: NSRange, lineRange: NSRange, in result: NSMutableAttributedString, font: UIFont) {
        let start = NSMaxRange(marker)
        guard start < NSMaxRange(lineRange) else { return }
        result.addAttribute(.font, value: font, range: NSRange(location: start, length: NSMaxRange(lineRange) - start))
    }

    private func lineContentRange(_ lineRange: NSRange, source: NSString) -> NSRange {
        var length = lineRange.length
        while length > 0, CharacterSet.newlines.contains(UnicodeScalar(source.character(at: lineRange.location + length - 1))!) {
            length -= 1
        }
        return NSRange(location: lineRange.location, length: length)
    }

    private func firstMatch(_ pattern: String, in line: String, offset: Int) -> NSRange? {
        guard let expression = try? NSRegularExpression(pattern: pattern),
              let match = expression.firstMatch(in: line, range: NSRange(location: 0, length: (line as NSString).length)) else { return nil }
        return NSRange(location: offset + match.range.location, length: match.range.length)
    }

    private func markerLength(in range: NSRange, source: NSString, characters: CharacterSet) -> Int {
        var count = 0
        while count < range.length {
            let scalar = UnicodeScalar(source.character(at: range.location + count))!
            guard characters.contains(scalar) else { break }
            count += 1
        }
        return count
    }

    private func isThematicBreak(_ line: String) -> Bool {
        line.range(of: #"^\s{0,3}((\*\s*){3,}|(-\s*){3,}|(_\s*){3,})$"#, options: .regularExpression) != nil
    }
}

private extension UIFont {
    func withTraits(_ traits: UIFontDescriptor.SymbolicTraits) -> UIFont {
        guard let descriptor = fontDescriptor.withSymbolicTraits(fontDescriptor.symbolicTraits.union(traits)) else { return self }
        return UIFont(descriptor: descriptor, size: pointSize)
    }
}
#endif
