//
//  MarkdownStyler.swift
//  MarkdownEngine
//
//  Created by Luca Chen on 18.02.26.
//

// Applies the Markdown look (bold, links, code, headings, etc.) based on
// the current text and cursor position.
//
// Token-class–specific styling lives in extension files:
//   - MarkdownStyler+TextStyling.swift   (headings, emphasis)
//   - MarkdownStyler+Links.swift         (auto / markdown / wiki links)
//   - MarkdownStyler+Code.swift          (fenced + inline code)
//   - MarkdownStyler+Latex.swift         (block + inline LaTeX)
//   - MarkdownStyler+Images.swift        (image embeds)
//   - MarkdownStyler+TaskCheckboxes.swift
import Foundation
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

// MARK: - Regexes used only by styling

extension MarkdownStyler {
    static let linkDataDetector: NSDataDetector? = try? NSDataDetector(
        types: NSTextCheckingResult.CheckingType.link.rawValue
    )
    static let incompleteLinkRegexes: [NSRegularExpression] = [
        "\\[\\]",
        "\\[\\[\\]\\]",
        "\\[[^\\]\\r\\n]*$",
        "\\[[^\\]\\r\\n]+\\](?!\\()",
        "\\[[^\\]\\r\\n]+\\]\\([^)\\r\\n]*$",
        "\\[[^\\]\\r\\n]+\\]\\(\\)"
    ].map { try! NSRegularExpression(pattern: $0) }
    static let taskListRegex: NSRegularExpression = try! NSRegularExpression(
        pattern: #"^([ \t]*)([-•]|\d+\.)([ \t]+)(\[[ xX]\])(?=[ \t])"#,
        options: [.anchorsMatchLines]
    )
}

// MARK: - Styling Context

extension MarkdownStyler {
    struct StylingContext {
        let text: String
        let nsText: NSString
        let fullRange: NSRange
        // When non-nil, scan-based sub-methods only scan these ranges.
        let scopedRanges: [NSRange]?
        let tokens: [MarkdownToken]
        let codeTokens: [MarkdownToken]
        let activeTokenIndices: Set<Int>
        let baseFont: PlatformFont
        let fontName: String
        let caretLocation: Int
        let layoutBridge: LayoutBridge?
        let baseDefaultLineHeight: CGFloat
        let baseParagraphSpacing: CGFloat
        let codeFont: PlatformFont
        let codeBackgroundColor: PlatformColor
        let codeParagraphStyle: NSParagraphStyle
        let hiddenMarkerFont: PlatformFont
        let inlineMarkerFont: PlatformFont
        let latexMarkerFont: PlatformFont
        let configuration: MarkdownEditorConfiguration

        var services: MarkdownEditorServices { configuration.services }
    }
}

typealias StyledRange = (range: NSRange, attributes: [NSAttributedString.Key: Any])

// MARK: - Public API

enum MarkdownStyler {

    static func styleAttributes(
        text: String,
        fontName: String,
        fontSize: CGFloat,
        layoutBridge: LayoutBridge? = nil,
        caretLocation: Int,
        activeTokenIndices: Set<Int>,
        wikiLinkIDProvider: (NSRange) -> String? = { _ in nil },
        precomputedTokens: [MarkdownToken]? = nil,
        scopedRanges: [NSRange]? = nil,
        configuration: MarkdownEditorConfiguration = .default
    ) -> [StyledRange] {
        let tokens = precomputedTokens ?? MarkdownTokenizer.parseTokens(in: text)
        let nsText = text as NSString
        let fullRange = NSRange(location: 0, length: nsText.length)
        let codeTokens = tokens.filter { $0.kind == .codeBlock || $0.kind == .inlineCode }
        let baseFont = PlatformFont.markdownFont(name: fontName, size: fontSize)
        let baseDefaultLineHeight = ceil(
            layoutBridge?.defaultLineHeight(for: baseFont)
            ?? (baseFont.ascender - baseFont.descender + baseFont.leading)
        )
        let baseParagraphSpacing = ceil(baseDefaultLineHeight * configuration.paragraph.spacingFactor)

        let codeFontSize = round(fontSize * configuration.codeBlock.fontSizeScale)
        let codeFont = configuration.services.syntaxHighlighter.codeFont(size: codeFontSize)
        let codeBackgroundColor = configuration.services.syntaxHighlighter.backgroundColor()
        let codeLineHeight: CGFloat = layoutBridge?.defaultLineHeight(for: codeFont)
            ?? (codeFont.ascender - codeFont.descender + codeFont.leading)
        let codeParagraphStyle: NSParagraphStyle = {
            let style = NSMutableParagraphStyle()
            style.lineBreakMode = .byCharWrapping
            style.lineSpacing = 0
            let codeBlockSpacing = configuration.codeBlock.paragraphSpacing
            let codeBlockIndent = configuration.codeBlock.horizontalIndent
            style.paragraphSpacingBefore = codeBlockSpacing
            style.paragraphSpacing = codeBlockSpacing
            style.headIndent = codeBlockIndent
            style.firstLineHeadIndent = codeBlockIndent
            style.tailIndent = -codeBlockIndent
            style.minimumLineHeight = ceil(codeLineHeight)
            style.maximumLineHeight = ceil(codeLineHeight)
            return style
        }()

        let hiddenMarkerSize = configuration.markers.hiddenMarkerFontSize
        let ctx = StylingContext(
            text: text,
            nsText: nsText,
            fullRange: fullRange,
            scopedRanges: scopedRanges,
            tokens: tokens,
            codeTokens: codeTokens,
            activeTokenIndices: activeTokenIndices,
            baseFont: baseFont,
            fontName: fontName,
            caretLocation: caretLocation,
            layoutBridge: layoutBridge,
            baseDefaultLineHeight: baseDefaultLineHeight,
            baseParagraphSpacing: baseParagraphSpacing,
            codeFont: codeFont,
            codeBackgroundColor: codeBackgroundColor,
            codeParagraphStyle: codeParagraphStyle,
            hiddenMarkerFont: codeFont,
            inlineMarkerFont: .systemFont(ofSize: hiddenMarkerSize),
            latexMarkerFont: PlatformFont.markdownFont(name: fontName, size: hiddenMarkerSize),
            configuration: configuration
        )

        var result: [StyledRange] = []
        let listsEnabled = configuration.lists.helpersEnabled
        result += MarkdownLists.paragraphAttributes(
            for: text,
            baseFont: baseFont,
            nsText: nsText,
            fullRange: fullRange,
            listsEnabled: listsEnabled,
            defaultLineHeight: baseDefaultLineHeight,
            defaultParagraphSpacing: baseParagraphSpacing,
            configuration: configuration
        )
        result += styleHeadings(ctx)
        result += styleEmphasis(ctx)
        result += styleAutoLinks(ctx)
        result += styleWikiLinks(ctx, wikiLinkIDProvider: wikiLinkIDProvider)
        result += styleImageEmbeds(ctx)
        result += styleMarkdownLinks(ctx)
        result += styleCodeBlocks(ctx)
        result += styleInlineCode(ctx)
        result += styleBlockLatex(ctx)
        result += styleInlineLatex(ctx)
        result += styleHorizontalRules(ctx)
        result += styleIncompleteLinkBrackets(ctx)
        result += styleTaskCheckboxes(ctx)
        result += shrinkInactiveMarkers(ctx)
        return result
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
    }

    static func appendRenderedStandaloneBlock(
        for token: MarkdownToken,
        rawContent: String,
        image: PlatformImage,
        imageBounds: CGRect,
        paragraphSpacingBefore: CGFloat,
        paragraphSpacing: CGFloat,
        alignment: NSTextAlignment,
        mode: RenderedStandaloneBlockMode,
        ctx: StylingContext,
        attrs: inout [StyledRange]
    ) -> Bool {
        guard let paraRange = token.standaloneParagraphRange(in: ctx.nsText) else { return false }

        let para = NSMutableParagraphStyle()
        let baseLineHeight = layoutBridgeDefaultLineHeight(for: ctx.baseFont, using: ctx.layoutBridge)
        para.paragraphSpacingBefore = max(para.paragraphSpacingBefore, paragraphSpacingBefore)
        para.alignment = alignment

        switch mode {
        case .collapsedSource(let markerTexts):
            let neededHeight = max(para.minimumLineHeight, imageBounds.height, baseLineHeight)
            para.minimumLineHeight = neededHeight
            para.maximumLineHeight = max(para.maximumLineHeight, neededHeight)
            para.paragraphSpacing = max(para.paragraphSpacing, paragraphSpacing)

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
                    .foregroundColor: PlatformColor.clear,
                    .font: ctx.latexMarkerFont,
                    .kern: -HeadingHelpers.textWidth(leadingText, font: ctx.latexMarkerFont)
                ]))
            }

            let anchorRange = NSRange(location: anchorLocation, length: 1)
            let anchorChar = ctx.nsText.substring(with: anchorRange)
            attrs.append((anchorRange, [
                .latexImage: image,
                .latexBounds: {
                        #if os(macOS)
                        NSValue(rect: imageBounds)
                        #else
                        NSValue(cgRect: imageBounds)
                        #endif
                    }(),
                .latexIsBlock: true,
                .foregroundColor: PlatformColor.clear,
                .font: ctx.latexMarkerFont,
                .kern: imageBounds.width - HeadingHelpers.textWidth(anchorChar, font: ctx.latexMarkerFont)
            ]))

            let trailingStart = anchorLocation + 1
            let trailingLength = contentEnd - trailingStart
            if trailingLength > 0 {
                let trailingRange = NSRange(location: trailingStart, length: trailingLength)
                let trailingText = ctx.nsText.substring(with: trailingRange)
                attrs.append((trailingRange, [
                    .foregroundColor: PlatformColor.clear,
                    .font: ctx.latexMarkerFont,
                    .kern: -HeadingHelpers.textWidth(trailingText, font: ctx.latexMarkerFont)
                ]))
            }

            for (index, markerRange) in token.markerRanges.enumerated() {
                let markerText = markerTexts.indices.contains(index)
                    ? markerTexts[index]
                    : ctx.nsText.substring(with: markerRange)
                attrs.append((markerRange, [
                    .foregroundColor: PlatformColor.clear,
                    .font: ctx.latexMarkerFont,
                    .kern: -HeadingHelpers.textWidth(markerText, font: ctx.latexMarkerFont)
                ]))
            }

            // Hide whitespace between paragraph start and token start
            // (e.g. a space before "![[") so it doesn't affect line layout.
            let preTokenLength = token.range.location - paraRange.location
            if preTokenLength > 0 {
                let preTokenRange = NSRange(location: paraRange.location, length: preTokenLength)
                let preTokenText = ctx.nsText.substring(with: preTokenRange)
                attrs.append((preTokenRange, [
                    .foregroundColor: PlatformColor.clear,
                    .font: ctx.latexMarkerFont,
                    .kern: -HeadingHelpers.textWidth(preTokenText, font: ctx.latexMarkerFont)
                ]))
            }

        case .visibleSource(let imageGap):
            para.minimumLineHeight = max(para.minimumLineHeight, baseLineHeight)
            para.maximumLineHeight = max(para.maximumLineHeight, baseLineHeight)
            para.paragraphSpacing = max(para.paragraphSpacing, imageBounds.height + imageGap + paragraphSpacing)

            attrs.append((paraRange, [.paragraphStyle: para]))
            attrs.append((token.range, [
                .latexImage: image,
                .latexBounds: {
                        #if os(macOS)
                        NSValue(rect: imageBounds)
                        #else
                        NSValue(cgRect: imageBounds)
                        #endif
                    }(),
                .latexIsBlock: true,
                .latexBlockOffsetY: baseLineHeight + imageGap
            ]))
            appendSecondaryMarkers(for: token, to: &attrs, theme: ctx.configuration.theme)
        }

        return true
    }
}

// MARK: - Whole-document & inline-only styling kept inline (small helpers)

extension MarkdownStyler {

    // MARK: Horizontal Rules ---

    static func styleHorizontalRules(_ ctx: StylingContext) -> [StyledRange] {
        var attrs: [StyledRange] = []
        let hrPattern = "^[ \\t]*-{3,}[ \\t]*$"
        if let hrRegex = try? NSRegularExpression(pattern: hrPattern, options: [.anchorsMatchLines]) {
            for hrMatch in hrRegex.matches(in: ctx.text, range: ctx.fullRange) {
                attrs.append((hrMatch.range, [.foregroundColor: PlatformColor.clear]))
                attrs.append((hrMatch.range, [
                    .strikethroughStyle: NSUnderlineStyle.thick.rawValue,
                    .strikethroughColor: ctx.configuration.theme.strikethroughColor
                ]))
                let rulePara = NSMutableParagraphStyle()
                attrs.append((hrMatch.range, [.paragraphStyle: rulePara]))
            }
        }
        return attrs
    }

    // MARK: Incomplete Link Brackets

    static func styleIncompleteLinkBrackets(_ ctx: StylingContext) -> [StyledRange] {
        var attrs: [StyledRange] = []
        for regex in MarkdownStyler.incompleteLinkRegexes {
            for match in regex.matches(in: ctx.text, options: [], range: ctx.fullRange) {
                let matchRange = match.range
                if MarkdownDetection.isInsideCodeBlock(range: matchRange, codeTokens: ctx.codeTokens) { continue }
                let substring = ctx.nsText.substring(with: matchRange)
                for (i, char) in substring.enumerated() {
                    let location = matchRange.location + i
                    if char == "[" || char == "]" || char == "(" || char == ")" {
                        let markerRange = NSRange(location: location, length: 1)
                        attrs.append((markerRange, [.foregroundColor: ctx.configuration.theme.mutedText]))
                    } else {
                        let contentRange = NSRange(location: location, length: 1)
                        attrs.append((contentRange, [.foregroundColor: ctx.configuration.theme.incompleteLink.withAlphaComponent(ctx.configuration.link.incompleteLinkAlpha)]))
                    }
                }
            }
        }
        return attrs
    }

    // MARK: Shrink / Hide Inactive Markers

    static func shrinkInactiveMarkers(_ ctx: StylingContext) -> [StyledRange] {
        var attrs: [StyledRange] = []
        for (i, token) in ctx.tokens.enumerated() where !ctx.activeTokenIndices.contains(i) {
            if token.kind == .codeBlock || token.kind == .inlineCode || token.kind == .inlineLatex || token.kind == .imageEmbed {
                continue
            }
            if MarkdownDetection.isInsideCodeBlock(range: token.range, codeTokens: ctx.codeTokens) {
                continue
            }
            let smallSize = ctx.configuration.markers.hiddenMarkerFontSize
            let smallFont = PlatformFont.markdownFont(name: ctx.fontName, size: smallSize)
            if token.kind == .link && token.markerRanges.count >= 4 {
                let openParen = token.markerRanges[2]
                let closeParen = token.markerRanges[3]
                let hideRange = NSRange(
                    location: openParen.location,
                    length: (closeParen.location + closeParen.length) - openParen.location
                )
                attrs.append((hideRange, [
                    .font: smallFont,
                    .foregroundColor: PlatformColor.clear
                ]))
            }
            for m in token.markerRanges {
                attrs.append((m, [
                    .font: smallFont,
                    .kern: -smallFont.pointSize
                ]))
            }
        }
        return attrs
    }
}
