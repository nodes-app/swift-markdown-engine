//
//  NativeTextView+Placeholder.swift
//  MarkdownEngine
//
//  Created by Luca Chen on 11.06.26.
//
//  Embedder-supplied ghost text shown while the document is empty. Lives inside
//  the text view, so it sits below the scroll-away header band, tracks its
//  animation, and scrolls with the content.
//

import AppKit

/// Transparent, click-through label drawing the placeholder at the text
/// container origin. A plain NSView — overriding `draw(_:)` here is safe
/// (unlike on the TextKit-2 backed `NativeTextView` itself).
final class PlaceholderLabelView: NSView {
    var attributedText: NSAttributedString? {
        didSet { needsDisplay = true }
    }

    /// Top-left origin to match the flipped text view's first-line position.
    override var isFlipped: Bool { true }

    /// Clicks fall through to the text view (focus + caret placement).
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        attributedText?.draw(
            with: bounds,
            options: [.usesLineFragmentOrigin, .usesFontLeading]
        )
    }
}

extension NativeTextView {
    /// Install, refresh, or remove the placeholder. Cheap when nothing changed —
    /// called from every `updateNSView`.
    func setPlaceholder(_ attributed: NSAttributedString?) {
        if let attributed {
            let view: PlaceholderLabelView
            if let existing = placeholderView {
                view = existing
                if existing.attributedText?.isEqual(to: attributed) != true {
                    existing.attributedText = attributed
                }
            } else {
                view = PlaceholderLabelView()
                view.attributedText = attributed
                view.autoresizingMask = [.width, .height]
                addSubview(view)
                placeholderView = view
            }
            let target = placeholderFrame()
            if !view.frame.isApproximatelyEqual(to: target) {
                view.frame = target
            }
        } else if let placeholderView {
            placeholderView.removeFromSuperview()
            self.placeholderView = nil
        }
        refreshPlaceholderVisibility()
    }

    /// Visible only while the document is truly empty: the first typed character
    /// hides it, deleting everything brings it back.
    func refreshPlaceholderVisibility() {
        guard let placeholderView else { return }
        let shouldHide = (textStorage?.length ?? 0) > 0
        if placeholderView.isHidden != shouldHide {
            placeholderView.isHidden = shouldHide
        }
    }

    /// The text container's content area: where TextKit places the first line.
    private func placeholderFrame() -> NSRect {
        NSRect(
            x: textContainerInset.width,
            y: textContainerInset.height,
            width: max(bounds.width - textContainerInset.width * 2, 0),
            height: max(bounds.height - textContainerInset.height, 0)
        )
    }
}

private extension NSRect {
    func isApproximatelyEqual(to other: NSRect) -> Bool {
        abs(origin.x - other.origin.x) < 0.5
            && abs(origin.y - other.origin.y) < 0.5
            && abs(size.width - other.size.width) < 0.5
            && abs(size.height - other.size.height) < 0.5
    }
}
