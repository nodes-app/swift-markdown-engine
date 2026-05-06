//
//  MarkdownStyler+TextStyling.swift
//  MarkdownEngine
//
//  Created by Luca Chen on 16.03.26.
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
        // Per-char trait map collapsed into contiguous font runs so nested emphasis combines instead of overwriting.
        let len = ctx.nsText.length
        guard len > 0 else { return [] }

        var traits = [UInt8](repeating: 0, count: len)
        let boldBit: UInt8 = 1
        let italicBit: UInt8 = 2

        for token in ctx.tokens {
            let mask: UInt8
            switch token.kind {
            case .bold: mask = boldBit
            case .italic: mask = italicBit
            case .boldItalic: mask = boldBit | italicBit
            default: continue
            }
            if MarkdownDetection.isInsideCodeBlock(range: token.range, codeTokens: ctx.codeTokens) { continue }
            let r = token.contentRange
            let upper = min(r.location + r.length, len)
            for i in max(r.location, 0)..<upper {
                traits[i] |= mask
            }
        }

        let regularItalic = italicFont(in: ctx)
        let regularBold = boldFont(in: ctx)
        let regularBoldItalic = boldItalicFont(in: ctx)

        var attrs: [StyledRange] = []
        var i = 0
        while i < len {
            let t = traits[i]
            if t == 0 { i += 1; continue }
            var j = i + 1
            while j < len && traits[j] == t { j += 1 }
            let range = NSRange(location: i, length: j - i)
            let font: NSFont
            if t == boldBit | italicBit {
                font = headingAwareBoldItalic(in: ctx, contentLocation: i) ?? regularBoldItalic
            } else if t == boldBit {
                font = regularBold
            } else {
                font = headingAwareBoldItalic(in: ctx, contentLocation: i) ?? regularItalic
            }
            attrs.append((range, [.font: font]))
            i = j
        }
        return attrs
    }

    private static func boldFont(in ctx: StylingContext) -> NSFont {
        let desc = ctx.baseDescriptor.withSymbolicTraits(.bold)
        return NSFont(descriptor: desc, size: ctx.baseFont.pointSize)
            ?? NSFontManager.shared.convert(ctx.baseFont, toHaveTrait: .boldFontMask)
    }

    private static func italicFont(in ctx: StylingContext) -> NSFont {
        let desc = ctx.baseDescriptor.withSymbolicTraits(.italic)
        return NSFont(descriptor: desc, size: ctx.baseFont.pointSize)
            ?? NSFontManager.shared.convert(ctx.baseFont, toHaveTrait: .italicFontMask)
    }

    private static func boldItalicFont(in ctx: StylingContext) -> NSFont {
        let desc = ctx.baseDescriptor.withSymbolicTraits([.bold, .italic])
        return NSFont(descriptor: desc, size: ctx.baseFont.pointSize)
            ?? NSFontManager.shared.convert(ctx.baseFont, toHaveTrait: [.boldFontMask, .italicFontMask])
    }

    /// Returns a heading-sized bold+italic font when the location sits inside a heading, else `nil` so emphasis doesn't shrink mid-line.
    private static func headingAwareBoldItalic(in ctx: StylingContext, contentLocation: Int) -> NSFont? {
        guard let headingToken = ctx.tokens.first(where: {
            $0.kind == .heading && NSLocationInRange(contentLocation, $0.contentRange)
        }) else { return nil }
        let level = headingToken.markerRanges.first?.length ?? 1
        let multiplier = ctx.configuration.headings.fontMultiplier(for: level)
        let headingBase = NSFont(name: ctx.fontName, size: ctx.baseFont.pointSize * multiplier)
            ?? NSFont.systemFont(ofSize: ctx.baseFont.pointSize * multiplier)
        let desc = headingBase.fontDescriptor.withSymbolicTraits([.bold, .italic])
        return NSFont(descriptor: desc, size: headingBase.pointSize)
            ?? NSFontManager.shared.convert(headingBase, toHaveTrait: [.boldFontMask, .italicFontMask])
    }
}
