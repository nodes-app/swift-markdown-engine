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
        for (idx, token) in ctx.scoped(ctx.blockLatexIndexed) {
            if MarkdownDetection.isInsideCodeBlock(range: token.range, codeTokens: ctx.codeTokens) { continue }
            let isActive = ctx.activeTokenIndices.contains(idx)
            let rawLatexContent = ctx.nsText.substring(with: token.contentRange)
            let latexContent = rawLatexContent.trimmingCharacters(in: .whitespacesAndNewlines)

            attrs.append((token.range, [NSAttributedString.Key.spellingState: 0]))

            guard token.standaloneParagraphRange(in: ctx.nsText) != nil else { continue }

            let latexFontSize = HeadingHelpers.latexFontSize(for: token, headings: [], baseFont: ctx.baseFont)  // block $$ is never inside a heading

            if isActive {
                appendSecondaryMarkers(for: token, to: &attrs, theme: ctx.configuration.theme)
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
        let scopedLatex = ctx.scoped(ctx.inlineLatexIndexed)
        guard !scopedLatex.isEmpty else { return attrs }
        // Containers that ENCLOSE an in-scope formula must overlap the scope, so
        // scope-slicing these is exact; built once, not per formula.
        let tableRanges = ctx.scoped(ctx.tableIndexed).map { $0.token.range }
        // Quote lines mute their text via foregroundColor, which the LaTeX *image* ignores — render it in mutedText instead so it matches the grey.
        let blockquoteRanges = MarkdownStyler.StylingContext.indexed(ctx.tokens, .blockquote).map { $0.token.range }
        // Built once, not re-scanned per formula (latexFontSize was O(#latex × #tokens)).
        let headings = ctx.scoped(MarkdownStyler.StylingContext.indexed(ctx.tokens, .heading)).map { $0.token }
        for (idx, token) in scopedLatex {
            if MarkdownDetection.isInsideCodeBlock(range: token.range, codeTokens: ctx.codeTokens) { continue }
            if tableRanges.contains(where: { tableRange in
                token.range.location >= tableRange.location
                    && NSMaxRange(token.range) <= NSMaxRange(tableRange)
            }) { continue }

            attrs.append((token.range, [NSAttributedString.Key.spellingState: 0]))

            let isActive = ctx.activeTokenIndices.contains(idx)
            let latexContent = ctx.nsText.substring(with: token.contentRange)
            let latexFontSize = HeadingHelpers.latexFontSize(for: token, headings: headings, baseFont: ctx.baseFont)

            if isActive {
                for markerRange in token.markerRanges {
                    attrs.append((markerRange, [.foregroundColor: ctx.configuration.theme.mutedText]))
                }
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
