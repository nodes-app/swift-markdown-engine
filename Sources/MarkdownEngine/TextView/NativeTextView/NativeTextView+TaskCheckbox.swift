//
//  NativeTextView+TaskCheckbox.swift
//  MarkdownEngine
//
//  Created by Luca Chen on 16.03.26.
//
//  Hit-test for `[ ]` / `[x]` checkbox glyphs and toggle the underlying text
//  + `.taskCheckbox` attribute, then nudge the coordinator to restyle the
//  enclosing paragraph.
//

import AppKit

extension NativeTextView {

    /// The drawn checkbox square under `containerPoint`, if any.
    ///
    /// The `[ ]` chars are collapsed to ~zero width, so their bounding rect sits
    /// at the content edge; reconstruct the DRAWN square from the shared
    /// `TaskCheckboxGeometry` (right-aligned to it). `baseFont`, not
    /// NSTextView.font (see the draw site). `searchRange` bounds the scan —
    /// the hovered line for cursor checks, nil (whole doc) for clicks.
    func taskCheckboxHit(at containerPoint: CGPoint, in searchRange: NSRange? = nil) -> (range: NSRange, isChecked: Bool)? {
        guard let textContainer = textContainer,
              let bridge = layoutBridge,
              let storage = textStorage, storage.length > 0 else { return nil }
        let boxSize = TaskCheckboxGeometry.size(for: baseFont)
        let scan = searchRange ?? NSRange(location: 0, length: storage.length)
        var hit: (range: NSRange, isChecked: Bool)?
        storage.enumerateAttribute(.taskCheckbox, in: scan, options: []) { value, attrRange, stop in
            guard let isChecked = value as? Bool else { return }
            let anchor = bridge.boundingRect(forCharacterRange: attrRange, in: textContainer)
            let rect = CGRect(
                x: TaskCheckboxGeometry.boxX(contentX: anchor.minX, size: boxSize),
                y: anchor.minY,
                width: boxSize,
                height: max(anchor.height, boxSize)
            )
            if rect.contains(containerPoint) {
                hit = (attrRange, isChecked)
                stop.pointee = true
            }
        }
        return hit
    }

    func toggleTaskCheckboxIfHit(event: NSEvent) -> Bool? {
        guard let bridge = layoutBridge,
              let storage = textStorage else { return nil }
        let localPoint = convert(event.locationInWindow, from: nil)
        let containerPoint = CGPoint(
            x: localPoint.x - textContainerOrigin.x,
            y: localPoint.y - textContainerOrigin.y
        )

        guard let (effectiveRange, hitIsChecked) = taskCheckboxHit(at: containerPoint) else { return nil }

        let nsText = storage.string as NSString
        let checkboxText = nsText.substring(with: effectiveRange)
        guard checkboxText.range(of: #"\[[ xX]\]"#, options: .regularExpression) != nil else { return nil }

        let replacement = hitIsChecked ? "[ ]" : "[x]"
        let shouldToggle: Bool
        if isEditable {
            shouldToggle = shouldChangeText(in: effectiveRange, replacementString: replacement)
        } else if allowsTaskCheckboxInteractionWhenReadOnly {
            // NSTextView rejects shouldChangeText while read-only. Consult the
            // coordinator directly so its exact-edit bookkeeping and binding
            // synchronization still run, without briefly enabling text input.
            if let coordinator = delegate as? NativeTextViewCoordinator {
                coordinator.isProgrammaticEdit = true
                defer { coordinator.isProgrammaticEdit = false }
                shouldToggle = coordinator.textView(
                    self,
                    shouldChangeTextIn: effectiveRange,
                    replacementString: replacement
                )
            } else {
                shouldToggle = true
            }
        } else {
            shouldToggle = false
        }
        if shouldToggle {
            storage.replaceCharacters(in: effectiveRange, with: replacement)
            storage.addAttribute(.taskCheckbox, value: !hitIsChecked, range: effectiveRange)
            storage.addAttribute(.foregroundColor, value: NSColor.clear, range: effectiveRange)
            didChangeText()
            bridge.invalidateDisplay(forCharacterRange: effectiveRange)
            if let coord = delegate as? NativeTextViewCoordinator {
                let paragraph = (storage.string as NSString).paragraphRange(for: effectiveRange)
                coord.restyleParagraphs([paragraph], in: self)
            }
        }
        return true
    }
}
