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
        guard layoutBridge != nil, let storage = textStorage else { return nil }
        let localPoint = convert(event.locationInWindow, from: nil)
        let containerPoint = CGPoint(
            x: localPoint.x - textContainerOrigin.x,
            y: localPoint.y - textContainerOrigin.y
        )

        guard let (effectiveRange, hitIsChecked) = taskCheckboxHit(at: containerPoint) else { return nil }

        let nsText = storage.string as NSString
        let checkboxText = nsText.substring(with: effectiveRange)
        guard checkboxText.range(of: #"\[[ xX]\]"#, options: .regularExpression) != nil else { return nil }

        _ = applyTaskCheckboxState(!hitIsChecked, in: effectiveRange)
        return true
    }

    @discardableResult
    private func applyTaskCheckboxState(_ isChecked: Bool, in range: NSRange) -> Bool {
        guard let bridge = layoutBridge,
              let storage = textStorage,
              NSMaxRange(range) <= storage.length else { return false }
        let checkboxText = (storage.string as NSString).substring(with: range)
        let checkedPattern = #"\[[xX]\]"#
        let previousIsChecked = checkboxText.range(of: checkedPattern, options: .regularExpression) != nil
        guard previousIsChecked != isChecked else { return false }

        let replacement = isChecked ? "[x]" : "[ ]"
        let isReadOnlyOptIn = !isEditable && allowsTaskCheckboxInteractionWhenReadOnly
        let shouldToggle: Bool
        if isEditable {
            shouldToggle = shouldChangeText(in: range, replacementString: replacement)
        } else if isReadOnlyOptIn {
            // NSTextView rejects shouldChangeText while read-only. Consult the
            // coordinator directly so its exact-edit bookkeeping and binding
            // synchronization still run, without briefly enabling text input.
            if let coordinator = delegate as? NativeTextViewCoordinator {
                coordinator.isProgrammaticEdit = true
                defer { coordinator.isProgrammaticEdit = false }
                shouldToggle = coordinator.textView(
                    self,
                    shouldChangeTextIn: range,
                    replacementString: replacement
                )
            } else {
                shouldToggle = true
            }
        } else {
            shouldToggle = false
        }
        guard shouldToggle else { return false }

        if isReadOnlyOptIn,
           let readOnlyUndoManager = (delegate as? NativeTextViewCoordinator)?.undoManager(for: self)
                ?? undoManager {
            readOnlyUndoManager.registerUndo(withTarget: self) { textView in
                textView.applyTaskCheckboxState(previousIsChecked, in: range)
            }
            readOnlyUndoManager.setActionName("Toggle Task Checkbox")
        }

        storage.replaceCharacters(in: range, with: replacement)
        storage.addAttribute(.taskCheckbox, value: isChecked, range: range)
        storage.addAttribute(.foregroundColor, value: NSColor.clear, range: range)
        didChangeText()
        bridge.invalidateDisplay(forCharacterRange: range)
        if let coord = delegate as? NativeTextViewCoordinator {
            let paragraph = (storage.string as NSString).paragraphRange(for: range)
            coord.restyleParagraphs([paragraph], in: self)
        }
        return true
    }
}
