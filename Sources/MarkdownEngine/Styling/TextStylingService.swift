//
//  TextStylingService.swift
//  MarkdownEngine
//
//  Created by Luca Chen on 18.02.26.
//

// Applies base text styling and refreshes only changed sections so editing
// stays smooth while Markdown formatting updates.
import AppKit
import Foundation

struct TextStylingService {
    static func makeBaseTypingAttributes(
        font: NSFont,
        paragraphStyle: NSParagraphStyle,
        theme: MarkdownEditorTheme = .default
    ) -> [NSAttributedString.Key: Any] {
        [
            .font: font,
            .foregroundColor: theme.bodyText,
            .paragraphStyle: paragraphStyle
        ]
    }

    static func makeBaseFontAndStyle(
        fontName: String,
        fontSize: CGFloat,
        layoutBridge: LayoutBridge? = nil,
        configuration: MarkdownEditorConfiguration = .default
    ) -> (font: NSFont, style: NSMutableParagraphStyle) {
        let baseFont = NSFont(name: fontName, size: fontSize) ?? NSFont.systemFont(ofSize: fontSize)
        let defaultLineHeight = layoutBridgeDefaultLineHeight(for: baseFont, using: layoutBridge)
        let paragraph = NSMutableParagraphStyle()
        paragraph.minimumLineHeight = ceil(defaultLineHeight) + configuration.paragraph.lineHeightExtraSpacing
        paragraph.lineSpacing = 0
        let baseParagraphSpacing = ceil(defaultLineHeight * configuration.paragraph.spacingFactor)
        paragraph.paragraphSpacing = baseParagraphSpacing
        paragraph.paragraphSpacingBefore = 0
        paragraph.lineBreakMode = .byWordWrapping
        // 24 explicit tab stops at indentPerLevel intervals, then natural wrap.
        let perLevel = configuration.lists.indentPerLevel
        paragraph.tabStops = (1...24).map { NSTextTab(textAlignment: .left, location: CGFloat($0) * perLevel) }
        paragraph.defaultTabInterval = 0
        return (baseFont, paragraph)
    }

    static func restyle(
        textView: NSTextView,
        layoutBridge: LayoutBridge?,
        paragraphCandidates: [NSRange],
        baseFont: NSFont,
        paragraphStyle: NSMutableParagraphStyle,
        caretLocation: Int,
        activeTokenIndices: Set<Int>,
        wikiLinkIDProvider: @escaping (NSRange) -> String?,
        precomputedTokens: [MarkdownToken]? = nil,
        configuration: MarkdownEditorConfiguration = .default
    ) {
        let paragraphs = normalize(paragraphCandidates)

        textView.typingAttributes = makeBaseTypingAttributes(
            font: baseFont,
            paragraphStyle: paragraphStyle,
            theme: configuration.theme
        )

        guard !paragraphs.isEmpty else {
            textView.setNeedsDisplay(textView.visibleRect)
            return
        }

        let styledRanges = MarkdownStyler.styleAttributes(
            text: textView.string,
            fontName: baseFont.fontName,
            fontSize: baseFont.pointSize,
            layoutBridge: layoutBridge,
            caretLocation: caretLocation,
            activeTokenIndices: activeTokenIndices,
            wikiLinkIDProvider: wikiLinkIDProvider,
            precomputedTokens: precomputedTokens,
            scopedRanges: paragraphs,
            configuration: configuration
        )

        let spellingDisabledRanges = styledRanges.compactMap { (range, attrs) -> NSRange? in
            attrs[.spellingState] as? Int == 0 ? range : nil
        }

        // Remove existing spelling markers before reapplying disabled ranges.
        for disabledRange in spellingDisabledRanges {
            layoutBridge?.removeTemporaryAttribute(.spellingState, forCharacterRange: disabledRange)
        }

        textView.textStorage?.beginEditing()
#if DEBUG
        // Flicker diagnosis: how much of the document does this pass rewrite?
        let appliedSpan = paragraphs.reduce(0) { $0 + $1.length }
        if paragraphs.count > 10 || appliedSpan > 2500 {
            print("🎨 BIG-APPLY paragraphs=\(paragraphs.count) span=\(appliedSpan) of \(textView.textStorage?.length ?? -1)")
        }
#endif
        for disabledRange in spellingDisabledRanges {
            textView.textStorage?.addAttribute(.spellingState, value: 0, range: disabledRange)
        }
        for paragraph in paragraphs {
            textView.textStorage?.setAttributes([
                .font: baseFont,
                .foregroundColor: configuration.theme.bodyText,
                .paragraphStyle: paragraphStyle
            ], range: paragraph)
            textView.textStorage?.removeAttribute(.link, range: paragraph)
            for (range, attrs) in styledRanges where NSIntersectionRange(range, paragraph).length > 0 {
                let clippedRange = NSIntersectionRange(range, paragraph)
                for (key, value) in attrs {
                    textView.textStorage?.addAttribute(key, value: value, range: clippedRange)
                }
            }
        }
        textView.textStorage?.endEditing()
        // No ensureLayout here:
        textView.setNeedsDisplay(textView.visibleRect)
        (textView as? NativeTextView)?.ensureVisibleLayout()
    }

    private static func normalize(_ candidates: [NSRange]) -> [NSRange] {
        // Exact-duplicate drop in one pass (was O(n²) via contains); order and
        // overlapping-but-unequal ranges are preserved exactly as before.
        var seen = Set<Int>()
        seen.reserveCapacity(candidates.count)
        var result: [NSRange] = []
        for candidate in candidates where candidate.location != NSNotFound && candidate.length > 0 {
            let key = candidate.location &* 1_000_003 &+ candidate.length
            if seen.insert(key).inserted { result.append(candidate) }
        }
        return result
    }

    /// Convert an NSRange into an NSTextRange for use with NSTextLayoutManager.
    static func textRange(from range: NSRange, in contentStorage: NSTextContentStorage) -> NSTextRange? {
        let docStart = contentStorage.documentRange.location
        guard let start = contentStorage.location(docStart, offsetBy: range.location),
              let end = contentStorage.location(start, offsetBy: range.length) else {
            return nil
        }
        return NSTextRange(location: start, end: end)
    }
}
