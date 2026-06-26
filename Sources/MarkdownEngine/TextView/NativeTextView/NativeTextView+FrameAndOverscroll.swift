//
//  NativeTextView+FrameAndOverscroll.swift
//  MarkdownEngine
//
//  Created by Luca Chen on 16.03.26.
//
//  Frame-size management, content-height measurement (TextKit-2 last-fragment
//  + end-segment pattern), bottom-overscroll application, and transient-shrink
//  scroll-position restoration.
//

import AppKit

extension NativeTextView {
    /// Real content height including overscroll, excluding the click-below-text inflation.
    var scrollableContentHeight: CGFloat {
        max(ceil(baseContentHeight + activeBottomOverscroll), 0)
    }

    func recalcOverscroll(
        for scrollView: NSScrollView,
        targetWidth: CGFloat? = nil,
        debugTag: String = "?"
    ) {
        scrollView.contentInsets.bottom = 0

        let lineHeight = layoutBridgeDefaultLineHeight(for: self.baseFont, using: layoutBridge)
        // File switch/resize forces full layout until height settles; typing stays O(edit).
        if debugTag == "?" { pendingFullLayoutMeasure = true }
        let measured = measuredBaseContentHeight(
            minimumHeight: lineHeight,
            forceFullLayout: pendingFullLayoutMeasure
        )
        let visibleHeight = scrollView.contentView.bounds.height
        let resolvedOverscroll = resolvedOverscroll(
            baseContentHeight: measured,
            visibleHeight: visibleHeight,
            lineHeight: lineHeight
        )

        let baseHeightChanged = abs(measured - baseContentHeight) > 0.5
        let overscrollChanged = abs(resolvedOverscroll - activeBottomOverscroll) > 0.5
        // Height settled → stop forcing full layout (until the next switch/resize).
        if !(baseHeightChanged || overscrollChanged) { pendingFullLayoutMeasure = false }
        guard baseHeightChanged || overscrollChanged else { return }
        baseContentHeight = measured
        activeBottomOverscroll = resolvedOverscroll
        applyManagedFrameSize(width: targetWidth ?? frame.size.width)
    }

    /// Re-run the policy with the CURRENT base content height — no TextKit
    /// re-measure. For header-band changes (runs per animation frame).
    func reapplyOverscrollPolicy(for scrollView: NSScrollView) {
        let lineHeight = layoutBridgeDefaultLineHeight(for: self.baseFont, using: layoutBridge)
        let resolved = resolvedOverscroll(
            baseContentHeight: baseContentHeight,
            visibleHeight: scrollView.contentView.bounds.height,
            lineHeight: lineHeight
        )
        guard abs(resolved - activeBottomOverscroll) > 0.5 else { return }
        activeBottomOverscroll = resolved
        applyManagedFrameSize(width: frame.size.width)
    }

    /// Shared policy evaluation, including the header band stacked above the text —
    /// without it, a short text under an expanded band gets no slack.
    private func resolvedOverscroll(
        baseContentHeight: CGFloat,
        visibleHeight: CGFloat,
        lineHeight: CGFloat
    ) -> CGFloat {
        // Overscroll is a scroll-comfort affordance; meaningless without internal scrolling.
        guard configuration.heightBehavior == .scrolls else { return 0 }
        let headerHeight = (superview as? NativeTextViewContainer)?.headerHeight ?? 0
        let policy = BottomOverscrollPolicy(
            overscrollPercent: overscrollPercent,
            minOverscrollPoints: minOverscrollPoints,
            maxOverscrollPoints: maxOverscrollPoints,
            activationStartFraction: configuration.overscroll.activationStartFraction,
            activationRangeFraction: configuration.overscroll.activationRangeFraction
        )
        return policy.activeOverscroll(
            baseContentHeight: baseContentHeight,
            headerHeight: headerHeight,
            visibleHeight: visibleHeight,
            lineHeight: lineHeight
        )
    }

    func measuredBaseContentHeight(minimumHeight: CGFloat, forceFullLayout: Bool = false) -> CGFloat {
        let minimumContentHeight = ceil(max(minimumHeight, 0) + (textContainerInset.height * 2))
        guard let textLayoutManager else { return minimumContentHeight }

        // Partial TextKit-2 layout under-measures and oscillates; force full layout only on switch/resize.
        if forceFullLayout {
            textLayoutManager.ensureLayout(for: textLayoutManager.documentRange)
        }

        let documentEnd = textLayoutManager.documentRange.endLocation

        // Lay out the last fragment; gives a max-Y fallback if enumerateTextSegments misses it.
        var fragmentMaxY: CGFloat = 0
        var visited = 0
        // Geometry of the fragment containing the document end — the extra line
        // fragment normalization below needs its frame and line boxes.
        var lastFragmentFrame: NSRect = .zero
        var lastFragmentLineBoxes: [CGRect] = []
        textLayoutManager.enumerateTextLayoutFragments(
            from: documentEnd,
            options: [.reverse, .ensuresLayout, .ensuresExtraLineFragment]
        ) { fragment in
            let frame = fragment.layoutFragmentFrame
            if visited == 0 {
                lastFragmentFrame = frame
                lastFragmentLineBoxes = fragment.textLineFragments.map { $0.typographicBounds }
            }
            fragmentMaxY = max(fragmentMaxY, frame.maxY)
            // Trailing block image draws below TextKit's height; count its surface extent so it scrolls.
            let surfaceMaxY = frame.origin.y + fragment.renderingSurfaceBounds.maxY
            if surfaceMaxY > frame.maxY + 8 { fragmentMaxY = max(fragmentMaxY, surfaceMaxY) }
            visited += 1
            return visited < 3
        }

        // End-segment maxY = authoritative document height in TextKit 2.
        let segmentRange = NSTextRange(location: documentEnd)
        textLayoutManager.ensureLayout(for: segmentRange)
        var segmentMaxY: CGFloat = 0
        var segmentMinY: CGFloat = 0
        textLayoutManager.enumerateTextSegments(
            in: segmentRange,
            type: .standard,
            options: .middleFragmentsExcluded
        ) { _, rect, _, _ in
            if rect.maxY >= segmentMaxY {
                segmentMaxY = rect.maxY
                segmentMinY = rect.minY
            }
            return true
        }

        var rawHeight = max(segmentMaxY, fragmentMaxY)

        // With a trailing "\n", the last line is TextKit's extra line fragment.
        // Its metrics follow the final newline's attributes — not the body style a
        // typed line would get — so the measured height would jump on the first
        // typed character. Normalize the empty last line to body metrics.
        if segmentMaxY > 0, let storage = textStorage, storage.mutableString.hasSuffix("\n") {
            let bodyLineHeight = ceil(layoutBridgeDefaultLineHeight(for: baseFont, using: layoutBridge))
                + configuration.paragraph.lineHeightExtraSpacing

            // TextKit omits the final paragraph's paragraphSpacing above the extra
            // line fragment but inserts it once a real character follows — add the
            // missing gap so typing stays height-neutral.
            let ns = storage.mutableString
            let lastParaRange = ns.paragraphRange(for: NSRange(location: ns.length - 1, length: 0))
            let lastParaStyle = storage.attribute(
                .paragraphStyle, at: lastParaRange.location, effectiveRange: nil
            ) as? NSParagraphStyle
            let paragraphSpacing = lastParaStyle?.paragraphSpacing ?? 0
            let prevLineBottom: CGFloat
            if lastFragmentLineBoxes.count >= 2 {
                let secondToLast = lastFragmentLineBoxes[lastFragmentLineBoxes.count - 2]
                prevLineBottom = lastFragmentFrame.minY + secondToLast.maxY
            } else {
                prevLineBottom = lastFragmentFrame.minY
            }
            let appliedGap = max(segmentMinY - prevLineBottom, 0)
            let missingSpacing = max(paragraphSpacing - appliedGap, 0)
            let normalizedEnd = segmentMinY + missingSpacing + bodyLineHeight
            if abs(rawHeight - segmentMaxY) < 0.5 {
                // The extra line itself is the bottom-most content — replace it.
                rawHeight = normalizedEnd
            } else {
                // Something else (e.g. a trailing image surface) reaches lower — keep it.
                rawHeight = max(rawHeight, normalizedEnd)
            }
        }

        return max(ceil(rawHeight + (textContainerInset.height * 2)), minimumContentHeight)
    }

    /// Fixed reading-column width = wrap width + horizontal insets on both sides.
    var readingColumnWidth: CGFloat {
        (configuration.readingWidth ?? 0) + configuration.textInsets.horizontal * 2
    }

    func applyManagedFrameSize(width: CGFloat) {
        let contentHeight = max(ceil(baseContentHeight + activeBottomOverscroll), 0)
        let height: CGFloat
        switch configuration.heightBehavior {
        case .scrolls:
            // The container stacks a header band ABOVE this text view, so the text view only
            // needs to fill the viewport MINUS that band for the whole document view to fill
            // the viewport on short docs (header + textView ≥ viewport).
            let headerH = (superview as? NativeTextViewContainer)?.headerHeight ?? 0
            let scrollViewHeight = max((enclosingScrollView?.contentView.bounds.height ?? 0) - headerH, 0)
            height = max(contentHeight, scrollViewHeight)
        case .fitsContent:
            height = contentHeight
        }
        // Reading column: the column keeps its fixed wrap width; its centered X is
        // owned by `centerReadingColumn` (driven from the container's restack).
        let targetWidth = configuration.readingWidth != nil ? readingColumnWidth : max(width, 0)
        let targetSize = NSSize(
            width: targetWidth,
            height: height
        )
        guard abs(targetSize.width - frame.size.width) > 0.5 || abs(targetSize.height - frame.size.height) > 0.5 else {
            return
        }
        isApplyingManagedFrameSize = true
        super.setFrameSize(targetSize)
        isApplyingManagedFrameSize = false
        // Tell the container our height changed so it can re-stack (move us below the
        // header) and size itself. Re-entrancy is guarded inside the container.
        (superview as? NativeTextViewContainer)?.textViewDidResize()

        // Nudge SwiftUI to re-query sizeThatFits when content height changes outside
        // the text binding (e.g. image/LaTeX load, font-size change, header band).
        if configuration.heightBehavior == .fitsContent {
            enclosingScrollView?.invalidateIntrinsicContentSize()
        }
    }

    /// Re-center the column by moving its X (not resizing it) so it stays smooth during live resize.
    func centerReadingColumn(forClipWidth clipWidth: CGFloat) {
        guard configuration.readingWidth != nil,
              let container = superview as? NativeTextViewContainer else { return }
        if abs(container.frame.size.width - clipWidth) > 0.5 {
            var f = container.frame
            f.size.width = max(clipWidth, 0)
            container.frame = f
        }
        let originX = floor(max(0, (clipWidth - readingColumnWidth) / 2))
        let delta = originX - frame.origin.x
        if abs(delta) > 0.5 {
            setFrameOrigin(NSPoint(x: originX, y: frame.origin.y))
            repositionWideTableOverlaysForWidthChange(insetDelta: delta)
        }
    }

    override func setFrameSize(_ newSize: NSSize) {
        if isApplyingManagedFrameSize {
            super.setFrameSize(newSize)
            return
        }

        guard let scrollView = enclosingScrollView else {
            baseContentHeight = max(newSize.height, 0)
            super.setFrameSize(newSize)
            return
        }

        let widthChanged = abs(newSize.width - frame.size.width) > 0.5
        if widthChanged {
            pendingFullLayoutMeasure = true   // re-wrap → re-measure height against a full layout
            isApplyingManagedFrameSize = true
            super.setFrameSize(NSSize(width: newSize.width, height: frame.size.height))
            isApplyingManagedFrameSize = false
        }

        recalcOverscroll(for: scrollView, targetWidth: newSize.width, debugTag: "setFrameSize")

        // Width change → only wide-table paragraphs need restyling (their kern bakes in displayWidth).
        if widthChanged {
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                if self.configuration.readingWidth == nil {
                    self.restyleWideTableParagraphsForWidthChange()
                }
                self.updateWideTableOverlays()
            }
        }
    }

    /// Restyle only wide-table paragraphs via stamped anchor ranges; avoids re-tokenizing the doc.
    private func restyleWideTableParagraphsForWidthChange() {
        guard let storage = textStorage,
              let coord = delegate as? NativeTextViewCoordinator else { return }
        var ranges: [NSRange] = []
        var seen: Set<String> = []
        let fullRange = NSRange(location: 0, length: storage.length)
        storage.enumerateAttribute(.scrollableBlockFullRange, in: fullRange, options: []) { value, _, _ in
            guard let v = value as? NSValue else { return }
            let r = v.rangeValue
            let key = "\(r.location):\(r.length)"
            if seen.insert(key).inserted { ranges.append(r) }
        }
        guard !ranges.isEmpty else { return }
        coord.restyleParagraphs(ranges, in: self)
    }

    override func scrollRangeToVisible(_ range: NSRange) {
        if suppressAutoRevealOnce {
            suppressAutoRevealOnce = false
            return
        }
        if configuration.heightBehavior == .fitsContent {
            // The inner scroll view has no scrollable range, so the default
            // scrollRangeToVisible does nothing useful. Propagate the caret rect
            // to the enclosing (page-level) scroll view so it keeps the caret
            // on-screen. AppKit's scrollRectToVisible propagation can stall at
            // a nested NSScrollView boundary, so we walk up explicitly.
            super.scrollRangeToVisible(range)
            propagateCaretRevealToEnclosingScroller(range: range)
            return
        }
        // Only the reading column needs manual reveal; default keeps AppKit's native implementation.
        guard configuration.readingWidth != nil else {
            super.scrollRangeToVisible(range)
            return
        }
        // Explicit reveal: native scrollRangeToVisible can't position the container's centered subview.
        // A caret at the document end has no fragment at its location; step back one
        // char there so the last line's fragment is found (else nothing reveals).
        let docLength = (self.string as NSString).length
        let revealOffset = min(range.location, max(0, docLength - 1))
        guard let tlm = textLayoutManager,
              let scrollView = enclosingScrollView,
              let start = tlm.textContentManager?.location(tlm.documentRange.location, offsetBy: revealOffset) else {
            super.scrollRangeToVisible(range)
            return
        }
        tlm.enumerateTextLayoutFragments(from: start, options: [.ensuresLayout]) { fragment in
            let cv = scrollView.contentView
            let insetsTop = scrollView.contentInsets.top
            // Reveal the CARET's line, not the whole layout fragment. An active image/latex embed
            // renders its block below the source line via paragraphSpacing, so layoutFragmentFrame is
            // as tall as the image; revealing its maxY would scroll the viewport down by the block
            // height even though the caret sits on the source line at the top. Frames are text-view-
            // local; lift by the text view's offset inside the container (the header band).
            var revealRect = fragment.layoutFragmentFrame
            // Reveal the ACTUAL caret location's segment (not the stepped-back revealOffset), so a
            // freshly soft-wrapped last line at the document end still scrolls into view; fall back to
            // the stepped-back offset only when the true end-of-document has no segment of its own.
            for segOffset in [min(range.location, docLength), revealOffset] {
                guard let segLoc = tlm.textContentManager?.location(tlm.documentRange.location, offsetBy: segOffset) else { continue }
                var found = false
                tlm.enumerateTextSegments(in: NSTextRange(location: segLoc), type: .standard, options: []) { _, segFrame, _, _ in
                    if segFrame.height > 0 { revealRect = segFrame; found = true }   // caret rect = its line, not the block
                    return false
                }
                if found { break }
            }
            let frame = revealRect.offsetBy(dx: 0, dy: self.frame.origin.y)
            let visibleTop = cv.bounds.origin.y + insetsTop
            let visibleBottom = cv.bounds.origin.y + cv.bounds.height
            let margin: CGFloat = 24
            let targetY: CGFloat
            if frame.minY < visibleTop {
                targetY = frame.minY - insetsTop - margin
            } else if frame.maxY > visibleBottom {
                targetY = frame.maxY - cv.bounds.height + margin
            } else {
                return false   // already visible
            }
            cv.scroll(to: NSPoint(x: cv.bounds.origin.x, y: targetY))
            scrollView.reflectScrolledClipView(cv)
            (scrollView as? ClampedScrollView)?.clampToInsets()
            return false
        }
    }

    /// Walk the view hierarchy above the inner scroll view to find the
    /// enclosing (page-level) scroller and ask it to reveal the caret rect.
    /// Used in `.fitsContent` where the inner scroll view cannot scroll.
    private func propagateCaretRevealToEnclosingScroller(range: NSRange) {
        guard let innerScrollView = enclosingScrollView,
              let tlm = textLayoutManager,
              let start = tlm.textContentManager?.location(
                  tlm.documentRange.location, offsetBy: range.location
              ) else { return }
        // Compute the caret rect in window coordinates so we can convert it
        // into whichever enclosing scroller we find.
        var caretRect: CGRect?
        tlm.enumerateTextLayoutFragments(from: start, options: [.ensuresLayout]) { fragment in
            caretRect = fragment.layoutFragmentFrame.offsetBy(dx: 0, dy: self.frame.origin.y)
            return false
        }
        guard let rect = caretRect else { return }
        // Convert from document-view space (container) to the inner scroll
        // view's coordinate space, then to window, so we can convert into
        // any ancestor we find.
        let container = innerScrollView.documentView ?? self
        let rectInWindow = container.convert(rect, to: nil)
        // Walk up past the inner scroll view looking for a parent NSScrollView.
        var view: NSView? = innerScrollView.superview
        while let v = view {
            if let outerScrollView = v as? NSScrollView, outerScrollView !== innerScrollView {
                guard let outerDocView = outerScrollView.documentView else { return }
                let rectInOuter = outerDocView.convert(rectInWindow, from: nil)
                outerDocView.scrollToVisible(rectInOuter)
                return
            }
            view = v.superview
        }
    }

    /// Force TextKit 2 to lay out all fragments within the current visible rect.
    func ensureVisibleLayout() {
        guard let tlm = textLayoutManager else { return }
        let visTop = visibleRect.minY
        let visBot = visibleRect.maxY
        tlm.enumerateTextLayoutFragments(from: tlm.documentRange.location, options: [.ensuresLayout]) { fragment in
            let fr = fragment.layoutFragmentFrame
            if fr.maxY < visTop { return true }
            if fr.minY > visBot { return false }
            return true
        }
    }
}
