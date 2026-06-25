//
//  NativeTextViewCoordinator+Find.swift
//  MarkdownEngine
//
//  Created by Luca Chen on 16.03.26.
//
//  Find-in-document highlighting. The host app posts the bus notifications
//  registered in `MarkdownEditorBus.findScrollToRange` /
//  `findClearHighlights` to drive the highlight overlay; this extension
//  renders the highlights into the underlying NSTextStorage and scrolls the
//  current match into view.
//

import AppKit

extension NativeTextViewCoordinator {
    /// Legacy path: the host computes match ranges and posts them. Kept for compatibility, but
    /// it trusts SOURCE-coordinate ranges, which misalign wherever the displayed text is shorter
    /// than the source (node links etc.). Prefer `handleFindQuery`.
    @objc func handleFindScrollToRange(_ notification: Notification) {
        guard let info = notification.userInfo,
              let currentIndex = info["currentIndex"] as? Int,
              let allRanges = info["allRanges"] as? [NSRange] else { return }
        renderFindMatches(allRanges, currentIndex: currentIndex)
    }

    /// Find against the engine's OWN displayed text (`tv.string`). Matches are computed in
    /// DISPLAY coordinates, so highlights land correctly even where the displayed text differs
    /// from the source (node links rendered shorter than `[[Name|UUID]]`, LaTeX, images). Posts
    /// the match count back via `bus.findResults` so the host can show "x of y".
    @objc func handleFindQuery(_ notification: Notification) {
        guard let tv = textView,
              let info = notification.userInfo,
              let query = info["query"] as? String else { return }
        let requestedIndex = info["currentIndex"] as? Int ?? 0

        var allRanges: [NSRange] = []
        if !query.isEmpty {
            let haystack = tv.string as NSString
            let opts: NSString.CompareOptions = [.caseInsensitive, .diacriticInsensitive]
            var searchStart = 0
            while searchStart < haystack.length {
                let scope = NSRange(location: searchStart, length: haystack.length - searchStart)
                let found = haystack.range(of: query, options: opts, range: scope)
                if found.location == NSNotFound { break }
                allRanges.append(found)
                searchStart = found.location + max(found.length, 1)
            }
        }

        let currentIndex = allRanges.isEmpty ? 0 : min(max(requestedIndex, 0), allRanges.count - 1)
        renderFindMatches(allRanges, currentIndex: currentIndex)

        if let resultsName = configuration.services.bus.findResults {
            NotificationCenter.default.post(name: resultsName, object: nil, userInfo: ["count": allRanges.count])
        }
    }

    /// Highlight all matches (current one stronger) and scroll the current match into view.
    private func renderFindMatches(_ allRanges: [NSRange], currentIndex: Int) {
        guard let tv = textView else { return }
        let storage = tv.textStorage
        let fullRange = NSRange(location: 0, length: (tv.string as NSString).length)

        // Clear previous highlights
        storage?.removeAttribute(.backgroundColor, range: fullRange)

        // Highlight all matches; the focused match gets a stronger color.
        let theme = configuration.theme
        let matchAlpha = configuration.markers.findMatchHighlightAlpha
        let highlightColor = theme.findMatchHighlight.withAlphaComponent(matchAlpha)
        let currentHighlightColor = theme.findCurrentMatchHighlight

        for (i, matchRange) in allRanges.enumerated() {
            guard matchRange.location + matchRange.length <= fullRange.length else { continue }
            let color = (i == currentIndex) ? currentHighlightColor : highlightColor
            storage?.addAttribute(.backgroundColor, value: color, range: matchRange)
        }

        if let tlm = tv.textLayoutManager {
            tlm.ensureLayout(for: tlm.documentRange)
        }

        // Scroll the current match into view.
        guard allRanges.indices.contains(currentIndex) else { return }
        let range = allRanges[currentIndex]
        guard range.location + range.length <= fullRange.length else { return }
        // Default (text view IS documentView): native reveal — unchanged for non-readingWidth embedders.
        guard configuration.readingWidth != nil,
              let tlm = tv.textLayoutManager,
              let scrollView = tv.enclosingScrollView,
              let matchStart = tlm.textContentManager?.location(tlm.documentRange.location, offsetBy: range.location) else {
            tv.scrollRangeToVisible(range)
            return
        }
        // Reading column: text view is a centered subview of the container — scroll the clip explicitly.
        tlm.enumerateTextLayoutFragments(from: matchStart, options: [.ensuresLayout]) { fragment in
            let cv = scrollView.contentView
            let insetsTop = scrollView.contentInsets.top
            // Fragment frames are text-view-local; the scroll offset is in
            // document-view space — lift by the text view's offset inside the
            // container (the header band).
            let frame = fragment.layoutFragmentFrame.offsetBy(dx: 0, dy: tv.frame.origin.y)
            let visibleTop = cv.bounds.origin.y + insetsTop
            let visibleBottom = cv.bounds.origin.y + cv.bounds.height
            // Only scroll when the match is off-screen; reveal it a little below the top.
            if frame.minY < visibleTop || frame.maxY > visibleBottom {
                let targetY = frame.minY - insetsTop - cv.bounds.height * 0.2
                cv.scroll(to: NSPoint(x: cv.bounds.origin.x, y: targetY))
                scrollView.reflectScrolledClipView(cv)
                (scrollView as? ClampedScrollView)?.clampToInsets()
            }
            return false
        }
    }

    @objc func handleFindClearHighlights(_ notification: Notification) {
        guard let tv = textView else { return }
        let scrollView = tv.enclosingScrollView
        let preY = scrollView?.contentView.bounds.origin.y ?? 0
        let insetsTop = scrollView?.contentInsets.top ?? 0
        let visualTopDocY = preY + insetsTop
        var anchorOffsetFromTop: CGFloat = 0
        var anchorTextRange: NSTextRange? = nil
        // Fragment frames are text-view-local; visualTopDocY is in document-view
        // space — lift them by the text view's offset inside the container (the
        // header band) before comparing.
        let textViewTop = tv.frame.origin.y
        if let tlm = tv.textLayoutManager {
            tlm.enumerateTextLayoutFragments(from: tlm.documentRange.location, options: [.ensuresLayout]) { fragment in
                let frame = fragment.layoutFragmentFrame.offsetBy(dx: 0, dy: textViewTop)
                if frame.maxY < visualTopDocY { return true }
                anchorTextRange = fragment.rangeInElement
                anchorOffsetFromTop = visualTopDocY - frame.minY
                return false
            }
        }

        let fullRange = NSRange(location: 0, length: (tv.string as NSString).length)
        tv.textStorage?.removeAttribute(.backgroundColor, range: fullRange)
        if let tlm = tv.textLayoutManager {
            tlm.ensureLayout(for: tlm.documentRange)
        }

        if let tlm = tv.textLayoutManager, let anchor = anchorTextRange {
            tlm.enumerateTextLayoutFragments(from: anchor.location, options: [.ensuresLayout]) { fragment in
                let newDocY = fragment.layoutFragmentFrame.minY + textViewTop + anchorOffsetFromTop
                let targetScrollY = newDocY - insetsTop
                if let cv = scrollView?.contentView, abs(cv.bounds.origin.y - targetScrollY) > 0.5 {
                    cv.scroll(to: NSPoint(x: cv.bounds.origin.x, y: targetScrollY))
                    scrollView?.reflectScrolledClipView(cv)
                }
                return false
            }
        }
    }
}
