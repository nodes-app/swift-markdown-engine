//
//  MarkdownStyler+Latex.swift
//  MarkdownEngine
//
//  Created by Luca Chen on 16.03.26.
//
//  Block ($$...$$) and inline ($...$) LaTeX formula rendering.
//

import AppKit
import Foundation

extension MarkdownStyler {

    // MARK: Block LaTeX $$...$$

    static func styleBlockLatex(_ ctx: StylingContext) -> [StyledRange] {
        var attrs: [StyledRange] = []
        let blockLatexTokens = ctx.tokens.enumerated().filter { $0.element.kind == .blockLatex }
        for (idx, token) in blockLatexTokens {
            if MarkdownDetection.isInsideCodeBlock(range: token.range, codeTokens: ctx.codeTokens) { continue }
            let isActive = ctx.activeTokenIndices.contains(idx)
            let rawLatexContent = ctx.nsText.substring(with: token.contentRange)
            let latexContent = rawLatexContent.trimmingCharacters(in: .whitespacesAndNewlines)

            attrs.append((token.range, [NSAttributedString.Key.spellingState: 0]))

            guard token.standaloneParagraphRange(in: ctx.nsText) != nil else { continue }

            let latexFontSize = HeadingHelpers.latexFontSize(for: token, tokens: ctx.tokens, baseFont: ctx.baseFont)
                * ctx.configuration.blockLatex.fontScale

            if isActive {
                appendSecondaryMarkers(for: token, to: &attrs, theme: ctx.configuration.theme)
                // Dress the revealed raw source like a fenced code block: the
                // theme code-block background (which the layout fragment turns into
                // a full-width fill + border), code paragraph indent, and the mono
                // code font.
                if let paraRange = token.standaloneParagraphRange(in: ctx.nsText) {
                    let codeFont = ctx.configuration.services.syntaxHighlighter.codeFont(size: ctx.baseFont.pointSize)
                    let indent = ctx.configuration.codeBlock.horizontalIndent
                    let para = NSMutableParagraphStyle()
                    para.firstLineHeadIndent = indent
                    para.headIndent = indent
                    para.tailIndent = -indent
                    para.paragraphSpacingBefore = ctx.configuration.codeBlock.paragraphSpacing
                    para.paragraphSpacing = ctx.configuration.codeBlock.paragraphSpacing
                    attrs.append((paraRange, [
                        .backgroundColor: ctx.configuration.theme.codeBlockBackground,
                        .paragraphStyle: para,
                    ]))
                    attrs.append((token.contentRange, [.font: codeFont]))
                }
            } else if !latexContent.isEmpty,
                      let entry = ctx.services.latex.render(latex: latexContent, fontSize: latexFontSize, theme: ctx.configuration.theme) {
                _ = appendRenderedStandaloneBlock(
                    for: token,
                    rawContent: rawLatexContent,
                    image: entry.image,
                    imageBounds: CGRect(
                        x: 0,
                        y: entry.baselineOffset,
                        width: entry.size.width,
                        height: entry.size.height
                    ),
                    paragraphSpacingBefore: ctx.configuration.blockLatex.paragraphSpacingBefore,
                    paragraphSpacing: ctx.configuration.blockLatex.paragraphSpacing,
                    alignment: .center,
                    mode: .collapsedSource(markerTexts: ["$$", "$$"]),
                    ctx: ctx,
                    attrs: &attrs
                )
            } else {
                appendSecondaryMarkers(for: token, to: &attrs, theme: ctx.configuration.theme)
            }
        }
        return attrs
    }

    // MARK: Inline LaTeX $formula$

    static func styleInlineLatex(_ ctx: StylingContext) -> [StyledRange] {
        var attrs: [StyledRange] = []
        // Tables render their own cell contents (including `$…$`) into a single
        // image via `formattedCellString` + `collapsedSource`. If we also tag
        // the source-text `$x^2$` with a `.latexImage` attribute, the renderer
        // draws that tiny inline image on the collapsed 1pt source line under
        // the table — visible as a stray dot. Skip inline LaTeX inside a
        // table; the table image already covers it.
        let tableRanges = ctx.tokens.filter { $0.kind == .table }.map(\.range)
        // Quote lines mute their text via foregroundColor, which the LaTeX *image* ignores — render it in mutedText instead so it matches the grey.
        let blockquoteRanges = ctx.tokens.filter { $0.kind == .blockquote }.map(\.range)
        for (idx, token) in ctx.tokens.enumerated() where token.kind == .inlineLatex {
            if MarkdownDetection.isInsideCodeBlock(range: token.range, codeTokens: ctx.codeTokens) { continue }
            if tableRanges.contains(where: { tableRange in
                token.range.location >= tableRange.location
                    && NSMaxRange(token.range) <= NSMaxRange(tableRange)
            }) { continue }

            attrs.append((token.range, [NSAttributedString.Key.spellingState: 0]))

            let isActive = ctx.activeTokenIndices.contains(idx)
            let latexContent = ctx.nsText.substring(with: token.contentRange)
            let latexFontSize = HeadingHelpers.latexFontSize(for: token, tokens: ctx.tokens, baseFont: ctx.baseFont)
                * ctx.configuration.inlineLatex.fontScale

            if isActive {
                for markerRange in token.markerRanges {
                    attrs.append((markerRange, [.foregroundColor: ctx.configuration.theme.mutedText]))
                }
                // Revealed inline source reads like an inline `code` span.
                let codeFont = ctx.configuration.services.syntaxHighlighter.codeFont(size: ctx.baseFont.pointSize)
                attrs.append((token.range, [
                    .backgroundColor: ctx.configuration.theme.inlineCodeBackground,
                    .font: codeFont,
                ]))
            } else {
                var renderTheme = ctx.configuration.theme
                if blockquoteRanges.contains(where: { NSLocationInRange(token.range.location, $0) }) {
                    renderTheme.latexLightModeText = renderTheme.mutedText
                    renderTheme.latexDarkModeText = renderTheme.mutedText
                }
                if let entry = ctx.services.latex.render(latex: latexContent, fontSize: latexFontSize, theme: renderTheme) {
                    let imageBounds = CGRect(x: 0, y: entry.baselineOffset, width: entry.size.width, height: entry.size.height)
                    let contentLength = token.contentRange.length
                    let tinyDollarWidth = HeadingHelpers.textWidth("$", font: ctx.latexMarkerFont)
                    let baseDollarWidth = HeadingHelpers.textWidth("$", font: ctx.baseFont)

                    if contentLength > 0 {
                        let firstCharRange = NSRange(location: token.contentRange.location, length: 1)
                        let firstChar = ctx.nsText.substring(with: firstCharRange)
                        attrs.append((firstCharRange, [
                            .latexImage: entry.image,
                            .latexBounds: NSValue(rect: imageBounds),
                            .foregroundColor: NSColor.clear,
                            .font: ctx.latexMarkerFont,
                            .kern: entry.size.width - HeadingHelpers.textWidth(firstChar, font: ctx.latexMarkerFont)
                        ]))

                        if contentLength > 1 {
                            let restRange = NSRange(location: token.contentRange.location + 1, length: contentLength - 1)
                            let restText = ctx.nsText.substring(with: restRange)
                            attrs.append((restRange, [
                                .foregroundColor: NSColor.clear,
                                .font: ctx.latexMarkerFont,
                                .kern: -HeadingHelpers.textWidth(restText, font: ctx.latexMarkerFont)
                            ]))
                        }
                    }

                    let openMarker = token.markerRanges[0]
                    attrs.append((openMarker, [
                        .font: ctx.latexMarkerFont,
                        .foregroundColor: NSColor.clear,
                        .kern: -tinyDollarWidth
                    ]))
                    let closeMarker = token.markerRanges[1]
                    attrs.append((closeMarker, [
                        .foregroundColor: NSColor.clear,
                        .kern: -baseDollarWidth
                    ]))
                } else {
                    for markerRange in token.markerRanges {
                        attrs.append((markerRange, [.foregroundColor: ctx.configuration.theme.mutedText]))
                    }
                }
            }
        }
        return attrs
    }
}
