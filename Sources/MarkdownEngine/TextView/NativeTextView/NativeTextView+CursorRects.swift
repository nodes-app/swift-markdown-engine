//
//  NativeTextView+CursorRects.swift
//  MarkdownEngine
//
//  Created by Luca Chen on 27.05.26.
//
//  Read-only cursor handling: arrow over text, pointing hand over links.
//

import AppKit

extension NativeTextView {

    override func mouseMoved(with event: NSEvent) {
        if isInCursorExclusionZone(event) {
            // Editable+excluded = a panel over the editor (#81): own the arrow.
            // Read-only+excluded = a full-window overlay (search/transfer) owns
            // the cursor; stay silent — our tracking areas fire beneath it and
            // any set here fights the overlay's cursor (flicker).
            if isEditable { NSCursor.arrow.set() }
        } else if isOverInlineBox(event) {
            // A box is an embedder-drawn control sitting in the line. Its own
            // view sets the cursor it wants; ours must not fight it, and super
            // sets the I-beam on every move.
            NSCursor.pointingHand.set()
        } else if isEditable, isOverTaskCheckboxBox(event) {
            // The box is a clickable control, not text. super sets the I-beam
            // on every move, so setting the arrow after it flickers — skip
            // super entirely, like the exclusion-zone branch.
            NSCursor.arrow.set()
        } else if isEditable, isOverWideTableOverlay(event) {
            // Same treatment for wide-table scroll overlays: the overlay is a
            // control surface (rendered image + horizontal scroller), not
            // text, but the text view's tracking areas are not occlusion-aware
            // and super keeps setting the I-beam through it.
            NSCursor.arrow.set()
        } else {
            super.mouseMoved(with: event)
            applyReadOnlyCursor(for: event)
            applyInvertedIBeamIfNeeded(for: event)
        }
    }

    override func mouseEntered(with event: NSEvent) {
        if isInCursorExclusionZone(event) {
            if isEditable { NSCursor.arrow.set() }
        } else if isOverInlineBox(event) {
            NSCursor.pointingHand.set()
        } else if isEditable, isOverTaskCheckboxBox(event) {
            NSCursor.arrow.set()
        } else if isEditable, isOverWideTableOverlay(event) {
            NSCursor.arrow.set()
        } else {
            super.mouseEntered(with: event)
            applyReadOnlyCursor(for: event)
            applyInvertedIBeamIfNeeded(for: event)
        }
    }

    /// True when the pointer is over a wide-table overlay's HORIZONTAL
    /// SCROLLER (mirrors the task-checkbox suppression above; read-only mode
    /// already shows the arrow via `applyReadOnlyCursor`). Only the scroller
    /// strip is a control surface — over the rendered table image itself the
    /// normal text cursor behavior stays.
    private func isOverWideTableOverlay(_ event: NSEvent) -> Bool {
        guard !wideTableOverlays.isEmpty else { return false }
        for (_, overlay) in wideTableOverlays where overlay.superview != nil && !overlay.isHidden {
            guard let scroller = overlay.horizontalScroller, !scroller.isHidden else { continue }
            let point = scroller.convert(event.locationInWindow, from: nil)
            if scroller.bounds.contains(point) { return true }
        }
        return false
    }

    /// True inside an embedder exclusion zone — a panel over the editor or a
    /// full-window overlay (search/transfer) that owns the cursor. NOT gated on
    /// `isEditable`: overlays make the editor read-only, and gating let its
    /// cursor path keep firing beneath them (flicker in search).
    private func isInCursorExclusionZone(_ event: NSEvent) -> Bool {
        guard let excluded = isCursorExcluded else { return false }
        return excluded(event.locationInWindow)
    }

    /// In read-only mode, override NSTextView's I-beam: pointing hand over a
    /// `.link` range, arrow everywhere else.
    private func applyReadOnlyCursor(for event: NSEvent) {
        guard isSelectable, !isEditable else { return }      // edit mode: keep I-beam
        let viewPoint = convert(event.locationInWindow, from: nil)
        if isOverLink(at: viewPoint) {
            NSCursor.pointingHand.set()
        } else {
            NSCursor.arrow.set()
        }
    }

    /// True when the pointer is over a drawn task-checkbox square (edit mode
    /// suppresses the I-beam there — the box is a clickable control, not text;
    /// read-only mode already shows the arrow via `applyReadOnlyCursor`).
    private func isOverTaskCheckboxBox(_ event: NSEvent) -> Bool {
        let viewPoint = convert(event.locationInWindow, from: nil)
        let containerPoint = CGPoint(x: viewPoint.x - textContainerOrigin.x,
                                     y: viewPoint.y - textContainerOrigin.y)
        // Bound the attribute scan to the hovered line's fragment — a full-
        // document scan per mouse-move would be O(doc).
        guard let tlm = textLayoutManager,
              let tcs = tlm.textContentManager as? NSTextContentStorage,
              let fragment = tlm.textLayoutFragment(for: containerPoint) else { return false }
        let start = tcs.offset(from: tcs.documentRange.location, to: fragment.rangeInElement.location)
        let end = tcs.offset(from: tcs.documentRange.location, to: fragment.rangeInElement.endLocation)
        guard start != NSNotFound, end > start else { return false }
        let lineRange = NSRange(location: start, length: end - start)
        return taskCheckboxHit(at: containerPoint, in: lineRange) != nil
    }

    /// True when a clickable `.link` attribute exists under the given point
    /// (view coordinates). `.link` is what drives `clickedOnLink`, so this
    /// matches exactly what is clickable.
    private func isOverLink(at viewPoint: CGPoint) -> Bool {
        attributes(at: viewPoint)?[.link] != nil
    }

    /// Attributes of the character under `viewPoint`, or nil when the point is
    /// past the end of a line / outside any fragment.
    private func attributes(at viewPoint: CGPoint) -> [NSAttributedString.Key: Any]? {
        guard let tlm = textLayoutManager,
              let textStorage = textStorage, textStorage.length > 0 else { return nil }

        let containerPoint = CGPoint(x: viewPoint.x - textContainerOrigin.x,
                                     y: viewPoint.y - textContainerOrigin.y)
        guard let fragment = tlm.textLayoutFragment(for: containerPoint) else { return nil }

        let fragFrame = fragment.layoutFragmentFrame
        let pInFrag = CGPoint(x: containerPoint.x - fragFrame.minX,
                              y: containerPoint.y - fragFrame.minY)
        // Only accept a line fragment that actually contains the point — guards
        // against clicks in trailing padding / past the end of a line.
        guard let line = fragment.textLineFragments.first(where: { $0.typographicBounds.contains(pInFrag) }) else { return nil }

        let pInLine = CGPoint(x: pInFrag.x - line.typographicBounds.minX,
                              y: pInFrag.y - line.typographicBounds.minY)
        let idx = line.characterIndex(for: pInLine)
        let lineString = line.attributedString
        guard idx >= 0, idx < lineString.length else { return nil }
        return lineString.attributes(at: idx, effectiveRange: nil)
    }

    /// Ink + block of a span that repaints its foreground under `event`, or nil.
    /// Same rule as the caret color: only a run that carries BOTH a background
    /// and a foreground of its own is inverted — inline code and find matches
    /// paint a background but keep the body ink, and the system I-beam is
    /// already right on those.
    func invertedRunColors(at event: NSEvent) -> (ink: NSColor, block: NSColor)? {
        guard configuration.cursorFollowsSpanInk else { return nil }
        let attrs = attributes(at: convert(event.locationInWindow, from: nil))
        guard let attrs,
              let block = attrs[.backgroundColor] as? NSColor,
              let ink = attrs[.foregroundColor] as? NSColor else { return nil }
        // Resolve inside the view's appearance: these are dynamic colors, and
        // `NSAppearance.current` during a mouse event is not necessarily ours —
        // a dark editor would otherwise get the light-mode pair.
        var resolved: (ink: NSColor, block: NSColor, body: NSColor)?
        effectiveAppearance.performAsCurrentDrawingAppearance {
            guard let ink = ink.usingColorSpace(.deviceRGB),
                  let block = block.usingColorSpace(.deviceRGB),
                  let body = configuration.theme.bodyText.usingColorSpace(.deviceRGB) else { return }
            resolved = (ink, block, body)
        }
        guard let resolved else { return nil }
        // Body ink on a background is inline code or a find match — the system
        // I-beam is already right there; only a run that repaints its ink needs us.
        guard resolved.ink != resolved.body else { return nil }
        return (resolved.ink, resolved.block)
    }

    /// Over an inverted span the system I-beam is drawn in the block's own
    /// color (macOS inverts it against the editor's backdrop, not against the
    /// run under it), so it disappears. Swap in the same glyph recolored to the
    /// span's own ink; anywhere else `super` keeps the system cursor.
    func applyInvertedIBeamIfNeeded(for event: NSEvent) {
        guard isEditable,
              let colors = invertedRunColors(at: event),
              let cursor = InvertedIBeamCursor.cursor(ink: colors.ink, block: colors.block)
        else { return }
        cursor.set()
    }
}
