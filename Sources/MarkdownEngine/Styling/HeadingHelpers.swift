//
//  HeadingHelpers.swift
//  MarkdownEngine
//
//  Created by Luca Chen on 18.02.26.
//

// Small helper values for heading size/spacing, plus shared text measurements.
import AppKit

enum HeadingHelpers {

    /// Use heading context to scale LaTeX font size consistently with surrounding text.
    /// `headings` is the document's heading tokens, built once per styling pass —
    /// scanning all tokens per LaTeX token here was O(#latex × #tokens).
    static func latexFontSize(
        for token: MarkdownToken,
        headings: [MarkdownToken],
        baseFont: NSFont,
        configuration: HeadingStyle = .default
    ) -> CGFloat {
        if let headingToken = headings.first(where: { NSLocationInRange(token.contentRange.location, $0.contentRange) }) {
            let level = headingToken.markerRanges.first?.length ?? 1
            return baseFont.pointSize * configuration.fontMultiplier(for: level)
        }
        return baseFont.pointSize
    }

    static func textWidth(_ text: String, font: NSFont) -> CGFloat {
        (text as NSString).size(withAttributes: [.font: font]).width
    }
}
