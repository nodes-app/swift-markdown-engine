#if os(macOS)
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

    /// Memoized string-width measurement. `size(withAttributes:)` is a full CoreText
    /// measure (~31µs); the styler calls this thousands of times per open on a small set
    /// of repeated strings — list markers (`- `, `1. `), the `$`/`$$` latex markers, per
    /// formula/char slices. Only 2 distinct inline formulas × 4 calls each, 372 list
    /// items with ~5 distinct markers, etc. Same (text, font) → same width, so the cache
    /// is byte-identical to the direct call. `NSCache` bounds memory and is thread-safe.
    private static let widthCache: NSCache<NSString, NSNumber> = {
        let c = NSCache<NSString, NSNumber>()
        c.countLimit = 4096
        return c
    }()

    static func textWidth(_ text: String, font: NSFont) -> CGFloat {
        let key = "\(font.fontName)|\(font.pointSize)|\(text)" as NSString
        if let cached = widthCache.object(forKey: key) {
            return CGFloat(cached.doubleValue)
        }
        let width = (text as NSString).size(withAttributes: [.font: font]).width
        widthCache.setObject(NSNumber(value: Double(width)), forKey: key)
        return width
    }
}
#endif
