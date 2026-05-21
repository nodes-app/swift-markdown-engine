//
//  LayoutBridge.swift
//  MarkdownEngine
//
//  Thin helper around TextKit 2's NSTextLayoutManager. NSTextLayoutManager
//  is available on both macOS 12+ and iOS 16+.
//

#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// Line height from the bridge, or a font-metric fallback when no bridge is available.
func layoutBridgeDefaultLineHeight(for font: PlatformFont, using bridge: LayoutBridge? = nil) -> CGFloat {
    bridge?.defaultLineHeight(for: font)
        ?? (font.ascender - font.descender + font.leading)
}

final class LayoutBridge {
    private let textLayoutManager: NSTextLayoutManager

    init(_ textLayoutManager: NSTextLayoutManager) {
        self.textLayoutManager = textLayoutManager
    }

    private var textContentStorage: NSTextContentStorage? {
        textLayoutManager.textContentManager as? NSTextContentStorage
    }

    private func textRange(for range: NSRange) -> NSTextRange? {
        guard let tcs = textContentStorage,
              let start = tcs.location(tcs.documentRange.location, offsetBy: range.location),
              let end = tcs.location(start, offsetBy: range.length) else { return nil }
        return NSTextRange(location: start, end: end)
    }

    func defaultLineHeight(for font: PlatformFont) -> CGFloat {
        font.ascender - font.descender + font.leading
    }

    func boundingRect(forCharacterRange range: NSRange, in textContainer: NSTextContainer) -> CGRect {
        guard let textRange = textRange(for: range) else { return .zero }
        var result = CGRect.null
        textLayoutManager.enumerateTextSegments(
            in: textRange, type: .standard, options: []
        ) { _, rect, _, _ in
            result = result.isNull ? rect : result.union(rect)
            return true
        }
        return result.isNull ? .zero : result
    }

    func characterIndex(
        for point: CGPoint,
        in textContainer: NSTextContainer,
        fractionOfDistanceBetweenInsertionPoints fraction: inout CGFloat
    ) -> Int {
        guard let tcs = textContentStorage else {
            fraction = 0
            return NSNotFound
        }
        guard let fragment = textLayoutManager.textLayoutFragment(for: point) else {
            fraction = 0
            return NSNotFound
        }
        let fragFrame = fragment.layoutFragmentFrame
        let localPoint = CGPoint(
            x: point.x - fragFrame.origin.x,
            y: point.y - fragFrame.origin.y
        )
        var lineY: CGFloat = 0
        for lineFragment in fragment.textLineFragments {
            let lineBounds = lineFragment.typographicBounds
            if localPoint.y < lineY + lineBounds.height || lineFragment === fragment.textLineFragments.last {
                let lineLocalPoint = CGPoint(x: localPoint.x - lineFragment.glyphOrigin.x,
                                             y: localPoint.y - lineY)
                let charIndex = lineFragment.characterIndex(for: lineLocalPoint)
                let fragmentStart = tcs.offset(
                    from: tcs.documentRange.location,
                    to: fragment.rangeInElement.location
                )
                fraction = lineFragment.fractionOfDistanceThroughGlyph(for: lineLocalPoint)
                return fragmentStart + lineFragment.characterRange.location + charIndex
            }
            lineY += lineBounds.height
        }
        fraction = 0
        return NSNotFound
    }

    func invalidateDisplay(forCharacterRange range: NSRange) {
        guard textRange(for: range) != nil else { return }
        textLayoutManager.textViewportLayoutController.layoutViewport()
    }

    func removeTemporaryAttribute(_ attrName: NSAttributedString.Key, forCharacterRange range: NSRange) {
        guard let textRange = textRange(for: range) else { return }
        textLayoutManager.removeRenderingAttribute(attrName, for: textRange)
    }

    var firstTextContainer: NSTextContainer? {
        textLayoutManager.textContainer
    }
}
