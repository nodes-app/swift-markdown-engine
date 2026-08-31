//
//  NativeTextView+InlineBox.swift
//  MarkdownEngine
//
//  Where the text view meets a span laid out as a box
//  (`InlineSyntax.inlineBoxWidth`): the caret stays out of it and the pointer
//  reads it as a control.
//
//  Every selection the view takes goes through `setSelectedRanges`, so
//  normalizing there covers arrow keys, shift-arrows, clicks, drags, and
//  double-click word selection in one place — a box is either fully selected or
//  not selected at all, and the caret only ever rests on its edges.
//

import AppKit

extension NativeTextView {

    override func setSelectedRanges(
        _ ranges: [NSValue],
        affinity: NSSelectionAffinity,
        stillSelecting: Bool
    ) {
        guard let storage = textStorage, storage.length > 0 else {
            super.setSelectedRanges(ranges, affinity: affinity, stillSelecting: stillSelecting)
            return
        }
        let previous = selectedRange().location
        let normalized = ranges.map { value in
            NSValue(range: InlineBoxCaret.normalized(value.rangeValue, movingFrom: previous, in: storage))
        }
        super.setSelectedRanges(normalized, affinity: affinity, stillSelecting: stillSelecting)
    }

    /// True when the pointer is over a box. The box is an embedder-drawn
    /// control, not text, so the edit-mode I-beam has no business there — the
    /// same reasoning as the drawn task checkbox, and read-only mode included,
    /// because a box is a control in both.
    func isOverInlineBox(_ event: NSEvent) -> Bool {
        isOverInlineBox(atViewPoint: convert(event.locationInWindow, from: nil))
    }

    /// The pointer test itself, in the view's own coordinates.
    func isOverInlineBox(atViewPoint viewPoint: CGPoint) -> Bool {
        guard let storage = textStorage, storage.length > 0,
              let container = textContainer,
              let bridge = layoutBridge else { return false }
        let containerPoint = CGPoint(
            x: viewPoint.x - textContainerOrigin.x,
            y: viewPoint.y - textContainerOrigin.y
        )
        guard let line = lineRange(forContainerPoint: containerPoint) else { return false }
        var isOver = false
        storage.enumerateAttribute(.inlineExtensionBox, in: line, options: []) { value, range, stop in
            guard value != nil else { return }
            // The reserved space rides on the span's first character, so its
            // own bounding rect IS the box.
            if bridge.boundingRect(forCharacterRange: range, in: container).contains(containerPoint) {
                isOver = true
                stop.pointee = true
            }
        }
        return isOver
    }

    /// Character range of the line fragment under a point in container
    /// coordinates. Bounds the attribute scan to the hovered line, so a
    /// mouse-move never walks the whole document.
    private func lineRange(forContainerPoint point: CGPoint) -> NSRange? {
        guard let layoutManager = textLayoutManager,
              let contentStorage = layoutManager.textContentManager as? NSTextContentStorage,
              let fragment = layoutManager.textLayoutFragment(for: point) else { return nil }
        let start = contentStorage.offset(
            from: contentStorage.documentRange.location,
            to: fragment.rangeInElement.location
        )
        let end = contentStorage.offset(
            from: contentStorage.documentRange.location,
            to: fragment.rangeInElement.endLocation
        )
        guard start != NSNotFound, end > start else { return nil }
        return NSRange(location: start, length: end - start)
    }
}
