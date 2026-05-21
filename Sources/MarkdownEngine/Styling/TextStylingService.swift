//
//  TextStylingService.swift
//  MarkdownEngine
//
//  Applies base text styling and refreshes only changed sections so editing
//  stays smooth while Markdown formatting updates.
//

import Foundation
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

struct TextStylingService {
    static func makeBaseTypingAttributes(
        font: PlatformFont,
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
    ) -> (font: PlatformFont, style: NSMutableParagraphStyle) {
        let baseFont = PlatformFont.markdownFont(name: fontName, size: fontSize)
        let defaultLineHeight = layoutBridgeDefaultLineHeight(for: baseFont, using: layoutBridge)
        let paragraph = NSMutableParagraphStyle()
        paragraph.minimumLineHeight = ceil(defaultLineHeight) + configuration.paragraph.lineHeightExtraSpacing
        paragraph.lineSpacing = 0
        let baseParagraphSpacing = ceil(defaultLineHeight * configuration.paragraph.spacingFactor)
        paragraph.paragraphSpacing = baseParagraphSpacing
        paragraph.paragraphSpacingBefore = 0
        paragraph.lineBreakMode = .byWordWrapping
        return (baseFont, paragraph)
    }

    static func restyle(
        textView: some MarkdownTextViewProtocol,
        layoutBridge: LayoutBridge?,
        paragraphCandidates: [NSRange],
        baseFont: PlatformFont,
        paragraphStyle: NSMutableParagraphStyle,
        caretLocation: Int,
        activeTokenIndices: Set<Int>,
        wikiLinkIDProvider: (NSRange) -> String?,
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
            textView.markdownInvalidateDisplay()
            return
        }

        let styledRanges = MarkdownStyler.styleAttributes(
            text: textView.markdownString,
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

        for disabledRange in spellingDisabledRanges {
            layoutBridge?.removeTemporaryAttribute(.spellingState, forCharacterRange: disabledRange)
        }

        textView.markdownTextStorage?.beginEditing()
        for disabledRange in spellingDisabledRanges {
            textView.markdownTextStorage?.addAttribute(.spellingState, value: 0, range: disabledRange)
        }
        for paragraph in paragraphs {
            textView.markdownTextStorage?.setAttributes([
                .font: baseFont,
                .foregroundColor: configuration.theme.bodyText,
                .paragraphStyle: paragraphStyle
            ], range: paragraph)
            textView.markdownTextStorage?.removeAttribute(.link, range: paragraph)
            for (range, attrs) in styledRanges where NSIntersectionRange(range, paragraph).length > 0 {
                let clippedRange = NSIntersectionRange(range, paragraph)
                for (key, value) in attrs {
                    textView.markdownTextStorage?.addAttribute(key, value: value, range: clippedRange)
                }
            }
        }
        textView.markdownTextStorage?.endEditing()
        textView.markdownInvalidateDisplay()
        #if os(macOS)
        (textView as? NativeTextView)?.ensureVisibleLayout()
        #endif
    }

    private static func normalize(_ candidates: [NSRange]) -> [NSRange] {
        var result: [NSRange] = []
        for candidate in candidates where candidate.location != NSNotFound && candidate.length > 0 {
            if result.contains(where: { $0.location == candidate.location && $0.length == candidate.length }) {
                continue
            }
            result.append(candidate)
        }
        return result
    }

    static func textRange(from range: NSRange, in contentStorage: NSTextContentStorage) -> NSTextRange? {
        let docStart = contentStorage.documentRange.location
        guard let start = contentStorage.location(docStart, offsetBy: range.location),
              let end = contentStorage.location(start, offsetBy: range.length) else {
            return nil
        }
        return NSTextRange(location: start, end: end)
    }
}
