//
//  HeadingHelpers.swift
//  MarkdownEngine
//
//  Small helper values for heading size/spacing, plus shared text measurements.
//

import Foundation

enum HeadingHelpers {

    static func headingFontMultiplier(
        for level: Int,
        configuration: HeadingStyle = .default
    ) -> CGFloat {
        configuration.fontMultiplier(for: level)
    }

    static func headingTopSpacingEm(
        for level: Int,
        configuration: HeadingStyle = .default
    ) -> CGFloat {
        configuration.topSpacingEm(for: level)
    }

    static func latexFontSize(
        for token: MarkdownToken,
        tokens: [MarkdownToken],
        baseFont: PlatformFont,
        configuration: HeadingStyle = .default
    ) -> CGFloat {
        if let headingToken = tokens.first(where: {
            $0.kind == .heading && NSLocationInRange(token.contentRange.location, $0.contentRange)
        }) {
            let level = headingToken.markerRanges.first?.length ?? 1
            return baseFont.pointSize * configuration.fontMultiplier(for: level)
        }
        return baseFont.pointSize
    }

    static func textWidth(_ text: String, font: PlatformFont) -> CGFloat {
        (text as NSString).size(withAttributes: [.font: font]).width
    }

    static func checkboxExtraSpacing(
        font: PlatformFont,
        configuration: CheckboxStyle = .default
    ) -> CGFloat {
        max(
            configuration.minimumExtraSpacing,
            ceil(font.pointSize * configuration.extraSpacingPerFontPointFraction)
        )
    }
}
