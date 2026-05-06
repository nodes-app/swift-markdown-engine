//
//  MarkdownStyler+TextStyling.swift
//  MarkdownEngine
//
//  Heading and emphasis (bold / italic / bold+italic) attribute generation.
//

import AppKit
import Foundation

extension MarkdownStyler {

    // MARK: Headings

    static func styleHeadings(_ ctx: StylingContext) -> [StyledRange] {
        var attrs: [StyledRange] = []
        let headingTokens = ctx.tokens.filter { $0.kind == .heading }
        for token in headingTokens {
            let level = token.markerRanges.first?.length ?? 1
            let multiplier = ctx.configuration.headings.fontMultiplier(for: level)
            let fontSize = ctx.baseFont.pointSize * multiplier
            let headingBase = NSFont(name: ctx.fontName, size: fontSize) ?? NSFont.systemFont(ofSize: fontSize)
            let headingFont = NSFontManager.shared.convert(headingBase, toHaveTrait: .boldFontMask)

            let paraRange = ctx.nsText.paragraphRange(for: token.range)
            let headingLineHeight = ceil(layoutBridgeDefaultLineHeight(for: headingFont, using: ctx.layoutBridge)) + 1
            let headingPara = NSMutableParagraphStyle()
            headingPara.minimumLineHeight = headingLineHeight
            headingPara.maximumLineHeight = headingLineHeight
            let beforeEm = ctx.configuration.headings.topSpacingEm(for: level)
            headingPara.paragraphSpacingBefore = headingFont.pointSize * beforeEm
            headingPara.paragraphSpacing = ctx.baseParagraphSpacing
            attrs.append((paraRange, [.paragraphStyle: headingPara]))

            for markerRange in token.markerRanges {
                attrs.append((markerRange, [
                    .font: headingFont,
                    .foregroundColor: ctx.configuration.theme.headingMarker
                ]))
            }
            attrs.append((token.contentRange, [.font: headingFont]))
        }
        return attrs
    }

    // MARK: Bold / Italic / Bold+Italic

    static func styleEmphasis(_ ctx: StylingContext) -> [StyledRange] {
        var attrs: [StyledRange] = []

        // Bold+Italic
        for token in ctx.tokens where token.kind == .boldItalic {
            if MarkdownDetection.isInsideCodeBlock(range: token.range, codeTokens: ctx.codeTokens) { continue }
            let biDescriptor = ctx.baseDescriptor.withSymbolicTraits([.bold, .italic])
            let biFont = NSFont(descriptor: biDescriptor, size: ctx.baseFont.pointSize)
                ?? NSFontManager.shared.convert(ctx.baseFont, toHaveTrait: [.boldFontMask, .italicFontMask])
            attrs.append((token.contentRange, [.font: biFont]))
        }

        // Bold
        for token in ctx.tokens where token.kind == .bold {
            if MarkdownDetection.isInsideCodeBlock(range: token.range, codeTokens: ctx.codeTokens) { continue }
            let boldDesc = ctx.baseDescriptor.withSymbolicTraits(.bold)
            let boldFont = NSFont(descriptor: boldDesc, size: ctx.baseFont.pointSize)
                ?? NSFontManager.shared.convert(ctx.baseFont, toHaveTrait: .boldFontMask)
            attrs.append((token.contentRange, [.font: boldFont]))
        }

        // Strikethrough ~~text~~
        for token in ctx.tokens where token.kind == .strikethrough {
            if MarkdownDetection.isInsideCodeBlock(range: token.range, codeTokens: ctx.codeTokens) { continue }
            attrs.append((token.contentRange, [
                .strikethroughStyle: NSUnderlineStyle.single.rawValue,
                .strikethroughColor: ctx.configuration.theme.strikethroughColor
            ]))
        }

        // Italic
        for token in ctx.tokens where token.kind == .italic {
            if MarkdownDetection.isInsideCodeBlock(range: token.range, codeTokens: ctx.codeTokens) { continue }
            if let headingToken = ctx.tokens.first(where: { $0.kind == .heading && NSLocationInRange(token.contentRange.location, $0.contentRange) }) {
                let level = headingToken.markerRanges.first?.length ?? 1
                let multiplier = ctx.configuration.headings.fontMultiplier(for: level)
                let headingBase = NSFont(name: ctx.fontName, size: ctx.baseFont.pointSize * multiplier)
                    ?? NSFont.systemFont(ofSize: ctx.baseFont.pointSize * multiplier)
                let biDescriptor = headingBase.fontDescriptor.withSymbolicTraits([.bold, .italic])
                let fontIt = NSFont(descriptor: biDescriptor, size: headingBase.pointSize)
                    ?? NSFontManager.shared.convert(headingBase, toHaveTrait: [.boldFontMask, .italicFontMask])
                attrs.append((token.contentRange, [.font: fontIt]))
            } else {
                let italicDesc = ctx.baseDescriptor.withSymbolicTraits(.italic)
                let italicFont = NSFont(descriptor: italicDesc, size: ctx.baseFont.pointSize)
                    ?? NSFontManager.shared.convert(ctx.baseFont, toHaveTrait: .italicFontMask)
                attrs.append((token.contentRange, [.font: italicFont]))
            }
        }

        return attrs
    }
}
