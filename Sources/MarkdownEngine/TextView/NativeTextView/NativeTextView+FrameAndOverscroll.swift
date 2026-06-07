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
        let policy = BottomOverscrollPolicy(
            overscrollPercent: overscrollPercent,
            minOverscrollPoints: minOverscrollPoints,
            maxOverscrollPoints: maxOverscrollPoints,
            activationStartFraction: configuration.overscroll.activationStartFraction,
            activationRangeFraction: configuration.overscroll.activationRangeFraction
        )
        let resolvedOverscroll = policy.activeOverscroll(
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
        textLayoutManager.enumerateTextLayoutFragments(
            from: documentEnd,
            options: [.reverse, .ensuresLayout, .ensuresExtraLineFragment]
        ) { fragment in
            let frame = fragment.layoutFragmentFrame
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
        textLayoutManager.enumerateTextSegments(
            in: segmentRange,
            type: .standard,
            options: .middleFragmentsExcluded
        ) { _, rect, _, _ in
            segmentMaxY = max(segmentMaxY, rect.maxY)
            return true
        }

        let rawHeight = max(segmentMaxY, fragmentMaxY)
        let measuredHeight = ceil(rawHeight + (textContainerInset.height * 2))
        return max(measuredHeight, minimumContentHeight)
    }

    /// Fixed reading-column width = wrap width + horizontal insets on both sides.
    var readingColumnWidth: CGFloat {
        (configuration.readingWidth ?? 0) + configuration.textInsets.horizontal * 2
    }

    func applyManagedFrameSize(width: CGFloat) {
        let contentHeight = max(ceil(baseContentHeight + activeBottomOverscroll), 0)
        let scrollViewHeight = enclosingScrollView?.contentView.bounds.height ?? 0
        let height = max(contentHeight, scrollViewHeight)

        // Reading column: size the full-width container + the fixed-width column, centered by position.
        if configuration.readingWidth != nil, let container = superview as? ReadingColumnContainerView {
            let clipWidth = enclosingScrollView?.contentView.bounds.width ?? width
            let containerSize = NSSize(width: max(clipWidth, 0), height: height)
            if abs(container.frame.size.width - containerSize.width) > 0.5
                || abs(container.frame.size.height - containerSize.height) > 0.5 {
                container.setFrameSize(containerSize)
            }
            let columnSize = NSSize(width: readingColumnWidth, height: height)
            if abs(columnSize.width - frame.size.width) > 0.5 || abs(columnSize.height - frame.size.height) > 0.5 {
                isApplyingManagedFrameSize = true
                super.setFrameSize(columnSize)
                isApplyingManagedFrameSize = false
            }
            let originX = floor(max(0, (containerSize.width - columnSize.width) / 2))
            if abs(frame.origin.x - originX) > 0.5 || abs(frame.origin.y) > 0.5 {
                setFrameOrigin(NSPoint(x: originX, y: 0))
            }
            return
        }

        let targetSize = NSSize(
            width: max(width, 0),
            height: height
        )
        guard abs(targetSize.width - frame.size.width) > 0.5 || abs(targetSize.height - frame.size.height) > 0.5 else {
            return
        }
        isApplyingManagedFrameSize = true
        super.setFrameSize(targetSize)
        isApplyingManagedFrameSize = false
    }

    /// Re-center the column by moving its X (not resizing it) so it stays smooth during live resize.
    func centerReadingColumn(forClipWidth clipWidth: CGFloat) {
        guard configuration.readingWidth != nil,
              let container = superview as? ReadingColumnContainerView else { return }
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
        super.scrollRangeToVisible(range)
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
