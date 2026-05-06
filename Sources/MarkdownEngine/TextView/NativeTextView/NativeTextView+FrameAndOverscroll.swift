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
        _ = debugTag
        scrollView.contentInsets.bottom = 0

        let lineHeight = layoutBridgeDefaultLineHeight(for: self.baseFont, using: layoutBridge)
        let measured = measuredBaseContentHeight(minimumHeight: lineHeight)
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
        guard baseHeightChanged || overscrollChanged else { return }
        baseContentHeight = measured
        activeBottomOverscroll = resolvedOverscroll
        applyManagedFrameSize(width: targetWidth ?? frame.size.width)
    }

    func measuredBaseContentHeight(minimumHeight: CGFloat) -> CGFloat {
        let minimumContentHeight = ceil(max(minimumHeight, 0) + (textContainerInset.height * 2))
        guard let textLayoutManager else { return minimumContentHeight }

        let documentEnd = textLayoutManager.documentRange.endLocation

        // Anchor: ensure the last fragment is laid out (also gives a max-Y fallback
        // in case `enumerateTextSegments` misses the trailing extra-line fragment).
        var fragmentMaxY: CGFloat = 0
        textLayoutManager.enumerateTextLayoutFragments(
            from: documentEnd,
            options: [.reverse, .ensuresLayout, .ensuresExtraLineFragment]
        ) { fragment in
            fragmentMaxY = fragment.layoutFragmentFrame.maxY
            return false
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

    func applyManagedFrameSize(width: CGFloat) {
        let contentHeight = max(ceil(baseContentHeight + activeBottomOverscroll), 0)
        let scrollViewHeight = enclosingScrollView?.contentView.bounds.height ?? 0
        let targetSize = NSSize(
            width: max(width, 0),
            height: max(contentHeight, scrollViewHeight)
        )
        guard abs(targetSize.width - frame.size.width) > 0.5 || abs(targetSize.height - frame.size.height) > 0.5 else {
            return
        }
        isApplyingManagedFrameSize = true
        super.setFrameSize(targetSize)
        isApplyingManagedFrameSize = false
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
            isApplyingManagedFrameSize = true
            super.setFrameSize(NSSize(width: newSize.width, height: frame.size.height))
            isApplyingManagedFrameSize = false
        }

        recalcOverscroll(for: scrollView, targetWidth: newSize.width, debugTag: "setFrameSize")
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
