//
//  MarkdownStyler+TextStyling.swift
//  MarkdownEngine
//
//  Heading and emphasis (bold / italic / bold+italic) attribute generation.
//

import Foundation
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

extension MarkdownStyler {

    // MARK: Headings

    static func styleHeadings(_ ctx: StylingContext) -> [StyledRange] {
        var attrs: [StyledRange] = []
        let headingTokens = ctx.tokens.filter { $0.kind == .heading }
        for token in headingTokens {
            let level = token.markerRanges.first?.length ?? 1
            let multiplier = ctx.configuration.headings.fontMultiplier(for: level)
            let fontSize = ctx.baseFont.pointSize * multiplier
            let headingFont = PlatformFont.markdownBold(name: ctx.fontName, size: fontSize)

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
        let len = ctx.nsText.length
        guard len > 0 else { return [] }

        var traits = [UInt8](repeating: 0, count: len)
        let boldBit: UInt8 = 1
        let italicBit: UInt8 = 2

        for token in ctx.tokens {
            let mask: UInt8
            switch token.kind {
            case .bold:       mask = boldBit
            case .italic:     mask = italicBit
            case .boldItalic: mask = boldBit | italicBit
            default: continue
            }
            if MarkdownDetection.isInsideCodeBlock(range: token.range, codeTokens: ctx.codeTokens) { continue }
            let r = token.contentRange
            let upper = min(r.location + r.length, len)
            for i in max(r.location, 0)..<upper { traits[i] |= mask }
        }

        let regularBold      = ctx.baseFont.markdownBold()
        let regularItalic    = ctx.baseFont.markdownItalic()
        let regularBoldItalic = ctx.baseFont.markdownBoldItalic()

        var attrs: [StyledRange] = []
        var i = 0
        while i < len {
            let t = traits[i]
            if t == 0 { i += 1; continue }
            var j = i + 1
            while j < len && traits[j] == t { j += 1 }
            let range = NSRange(location: i, length: j - i)
            let font: PlatformFont
            if t == boldBit | italicBit {
                font = headingAwareBoldItalic(in: ctx, contentLocation: i) ?? regularBoldItalic
            } else if t == boldBit {
                font = regularBold
            } else {
                font = headingAwareItalic(in: ctx, contentLocation: i) ?? regularItalic
            }
            attrs.append((range, [.font: font]))
            i = j
        }
        return attrs
    }

    private static func headingAwareBoldItalic(in ctx: StylingContext, contentLocation: Int) -> PlatformFont? {
        guard let headingToken = ctx.tokens.first(where: {
            $0.kind == .heading && NSLocationInRange(contentLocation, $0.contentRange)
        }) else { return nil }
        let level = headingToken.markerRanges.first?.length ?? 1
        let multiplier = ctx.configuration.headings.fontMultiplier(for: level)
        return PlatformFont.markdownFont(name: ctx.fontName, size: ctx.baseFont.pointSize * multiplier)
            .markdownBoldItalic()
    }

    private static func headingAwareItalic(in ctx: StylingContext, contentLocation: Int) -> PlatformFont? {
        guard let headingToken = ctx.tokens.first(where: {
            $0.kind == .heading && NSLocationInRange(contentLocation, $0.contentRange)
        }) else { return nil }
        let level = headingToken.markerRanges.first?.length ?? 1
        let multiplier = ctx.configuration.headings.fontMultiplier(for: level)
        return PlatformFont.markdownFont(name: ctx.fontName, size: ctx.baseFont.pointSize * multiplier)
            .markdownItalic()
    }
}
