//
//  IOSMarkdownTextLayoutFragment.swift
//  MarkdownEngine
//
//  Custom NSTextLayoutFragment for iOS — draws task checkboxes on top of the
//  hidden [ ] / [x] markers. Code-block backgrounds and LaTeX are handled
//  by UITextView's native .backgroundColor attribute rendering on iOS, so
//  only checkbox drawing needs custom fragment logic here.
//

#if os(iOS)
import UIKit

final class IOSMarkdownTextLayoutFragment: NSTextLayoutFragment {

    var theme: MarkdownEditorTheme = .default

    override func draw(at point: CGPoint, in context: CGContext) {
        super.draw(at: point, in: context)
        drawTaskCheckboxes(at: point, in: context)
    }

    // MARK: - Helpers (mirrored from macOS MarkdownTextLayoutFragment)

    private var fragmentNSRange: NSRange? {
        guard let tcs = textLayoutManager?.textContentManager as? NSTextContentStorage else { return nil }
        let start = tcs.offset(from: tcs.documentRange.location, to: rangeInElement.location)
        let end   = tcs.offset(from: tcs.documentRange.location, to: rangeInElement.endLocation)
        guard start != NSNotFound, end != NSNotFound, end > start else { return nil }
        return NSRange(location: start, length: end - start)
    }

    private var textStorage: NSTextStorage? {
        (textLayoutManager?.textContentManager as? NSTextContentStorage)?.textStorage
    }

    private func drawPosition(
        forDocumentCharAt docIndex: Int,
        point: CGPoint
    ) -> (x: CGFloat, baselineY: CGFloat, lineHeight: CGFloat)? {
        guard let fragRange = fragmentNSRange else { return nil }
        let localIndex = docIndex - fragRange.location
        guard localIndex >= 0 else { return nil }
        for lineFragment in textLineFragments {
            let lr = lineFragment.characterRange
            if localIndex >= lr.location && localIndex < lr.location + lr.length {
                let charPos = lineFragment.locationForCharacter(at: localIndex)
                let tb = lineFragment.typographicBounds
                return (
                    x: point.x + tb.origin.x + charPos.x,
                    baselineY: point.y + tb.origin.y + charPos.y,
                    lineHeight: tb.height
                )
            }
        }
        return nil
    }

    // MARK: - Checkbox Drawing

    private func drawTaskCheckboxes(at point: CGPoint, in context: CGContext) {
        guard let ts = textStorage, let range = fragmentNSRange, range.length > 0 else { return }

        UIGraphicsPushContext(context)
        defer { UIGraphicsPopContext() }

        ts.enumerateAttribute(.taskCheckbox, in: range, options: []) { [weak self] value, attrRange, _ in
            guard let self, let isChecked = value as? Bool else { return }
            guard let pos = drawPosition(forDocumentCharAt: attrRange.location, point: point) else { return }

            let font = (ts.attribute(.font, at: attrRange.location, effectiveRange: nil) as? UIFont)
                ?? UIFont.systemFont(ofSize: UIFont.systemFontSize)
            let ascent  = max(0, font.ascender)
            let descent = max(0, -font.descender)
            let fontHeight = max(1, ceil(ascent + descent))
            let markerWidth = ("[ ]" as NSString).size(withAttributes: [.font: font]).width
            let size = max(1.0, min(floor(fontHeight * 1.2), floor(markerWidth * 1.2)))
            let boxX    = pos.x + max(0, (markerWidth - size) / 2)
            let centerY = pos.baselineY + (descent - ascent) / 2
            let boxY    = centerY - size / 2
            let boxRect = CGRect(x: boxX, y: boxY, width: size, height: size)
            guard !boxRect.isEmpty, !boxRect.isNull else { return }

            let tint = isChecked ? theme.bodyText : theme.mutedText
            let symbolName = isChecked ? "checkmark.square.fill" : "square"
            let config = UIImage.SymbolConfiguration(pointSize: size, weight: .regular)
            if let image = UIImage(systemName: symbolName, withConfiguration: config)?
                .withTintColor(tint, renderingMode: .alwaysOriginal) {
                image.draw(in: boxRect)
            }
        }
    }
}

// MARK: - Layout Manager Delegate

final class IOSMarkdownLayoutManagerDelegate: NSObject, NSTextLayoutManagerDelegate {
    var theme: MarkdownEditorTheme = .default

    func textLayoutManager(
        _ textLayoutManager: NSTextLayoutManager,
        textLayoutFragmentFor location: any NSTextLocation,
        in textElement: NSTextElement
    ) -> NSTextLayoutFragment {
        let fragment = IOSMarkdownTextLayoutFragment(textElement: textElement, range: textElement.elementRange)
        fragment.theme = theme
        return fragment
    }
}

#endif
