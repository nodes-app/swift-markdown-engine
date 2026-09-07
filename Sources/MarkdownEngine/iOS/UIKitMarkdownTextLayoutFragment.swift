#if os(iOS)
import UIKit

extension NSAttributedString.Key {
    static let taskCheckboxFont = NSAttributedString.Key("TaskCheckboxFont")
    static let taskCheckboxTint = NSAttributedString.Key("TaskCheckboxTint")
}

final class UIKitMarkdownTextLayoutFragment: NSTextLayoutFragment {
    private static let gap: CGFloat = 2

    override var renderingSurfaceBounds: CGRect {
        var bounds = super.renderingSurfaceBounds
        if hasTaskCheckbox {
            bounds.origin.x -= 24
            bounds.size.width += 24
        }
        return bounds
    }

    override func draw(at point: CGPoint, in context: CGContext) {
        super.draw(at: point, in: context)
        drawTaskCheckboxes(at: point, in: context)
    }

    private var fragmentRange: NSRange? {
        guard let storage = textLayoutManager?.textContentManager as? NSTextContentStorage else { return nil }
        let start = storage.offset(from: storage.documentRange.location, to: rangeInElement.location)
        let end = storage.offset(from: storage.documentRange.location, to: rangeInElement.endLocation)
        guard start != NSNotFound, end != NSNotFound, end > start else { return nil }
        return NSRange(location: start, length: end - start)
    }

    private var textStorage: NSTextStorage? {
        (textLayoutManager?.textContentManager as? NSTextContentStorage)?.textStorage
    }

    private var hasTaskCheckbox: Bool {
        guard let textStorage, let fragmentRange else { return false }
        var found = false
        textStorage.enumerateAttribute(.taskCheckbox, in: fragmentRange) { value, _, stop in
            if value is Bool {
                found = true
                stop.pointee = true
            }
        }
        return found
    }

    private func drawPosition(forDocumentCharacterAt index: Int, point: CGPoint) -> (x: CGFloat, baselineY: CGFloat)? {
        guard let fragmentRange else { return nil }
        let localIndex = index - fragmentRange.location
        guard localIndex >= 0 else { return nil }

        for lineFragment in textLineFragments {
            let range = lineFragment.characterRange
            guard localIndex >= range.location, localIndex < NSMaxRange(range) else { continue }
            let location = lineFragment.locationForCharacter(at: localIndex)
            let bounds = lineFragment.typographicBounds
            return (
                x: point.x + bounds.origin.x + location.x,
                baselineY: point.y + bounds.origin.y + location.y
            )
        }
        return nil
    }

    private func drawTaskCheckboxes(at point: CGPoint, in context: CGContext) {
        guard let textStorage, let fragmentRange else { return }

        textStorage.enumerateAttribute(.taskCheckbox, in: fragmentRange) { value, range, _ in
            guard let checked = value as? Bool,
                  let font = textStorage.attribute(.taskCheckboxFont, at: range.location, effectiveRange: nil) as? UIFont,
                  let tint = textStorage.attribute(.taskCheckboxTint, at: range.location, effectiveRange: nil) as? UIColor,
                  let position = drawPosition(forDocumentCharacterAt: range.location, point: point) else { return }

            let size = ceil(font.lineHeight)
            let rect = CGRect(
                x: position.x - size - Self.gap,
                y: position.baselineY - font.ascender + (font.lineHeight - size) / 2,
                width: size,
                height: size
            )
            let name = checked ? "checkmark.square.fill" : "square"
            let configuration = UIImage.SymbolConfiguration(pointSize: size, weight: .regular)
            guard let image = UIImage(systemName: name, withConfiguration: configuration)?
                .withTintColor(tint, renderingMode: .alwaysOriginal) else { return }

            UIGraphicsPushContext(context)
            image.draw(in: rect)
            UIGraphicsPopContext()
        }
    }
}
#endif
