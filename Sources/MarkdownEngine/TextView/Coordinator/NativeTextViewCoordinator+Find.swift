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

extension NSAttributedString.Key {
    /// Marks a background this file painted. `.backgroundColor` has other owners
    /// (extension spans, code fences, table cells), so find has to recognize its
    /// own highlights before removing any.
    static let findHighlight = NSAttributedString.Key("FindHighlight")
}

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
        // Every live coordinator hears this (`object: nil`), and an editor the host
        // has routed away from can outlive its view for a while — it is not the
        // document being searched, and its answer would overwrite the real one's.
        // Measured: 24 coordinators replying to one ⌘F, 22 of them windowless with
        // an empty buffer, each reporting 0 matches and resetting the host's index.
        guard tv.window != nil else { return }
        let requestedIndex = info["currentIndex"] as? Int ?? 0

        let allRanges = findMatches(of: query, in: tv.string as NSString)
        let currentIndex = allRanges.isEmpty ? 0 : min(max(requestedIndex, 0), allRanges.count - 1)
        renderFindMatches(allRanges, currentIndex: currentIndex)
        postFindResults(count: allRanges.count)
    }

    /// All ranges of `query` in `haystack` (display coordinates), case- and
    /// diacritic-insensitive. Shared by find and replace.
    func findMatches(of query: String, in haystack: NSString) -> [NSRange] {
        guard !query.isEmpty else { return [] }
        var ranges: [NSRange] = []
        let opts: NSString.CompareOptions = [.caseInsensitive, .diacriticInsensitive]
        var searchStart = 0
        while searchStart < haystack.length {
            let scope = NSRange(location: searchStart, length: haystack.length - searchStart)
            let found = haystack.range(of: query, options: opts, range: scope)
            if found.location == NSNotFound { break }
            ranges.append(found)
            searchStart = found.location + max(found.length, 1)
        }
        return ranges
    }

    private func postFindResults(count: Int) {
        if let resultsName = configuration.services.bus.findResults {
            NotificationCenter.default.post(name: resultsName, object: nil, userInfo: ["count": count])
        }
    }

    /// Replace the current find match with the replacement string (one undo
    /// step), then re-highlight and report the remaining match count.
    @objc func handleReplaceCurrent(_ notification: Notification) {
        guard let tv = textView, tv.isEditable,
              let info = notification.userInfo,
              let query = info["query"] as? String, !query.isEmpty,
              let replacement = info["replacement"] as? String else { return }
        let requestedIndex = info["currentIndex"] as? Int ?? 0

        let matches = findMatches(of: query, in: tv.string as NSString)
        guard !matches.isEmpty else { postFindResults(count: 0); return }
        let idx = min(max(requestedIndex, 0), matches.count - 1)
        let target = matches[idx]
        guard NSMaxRange(target) <= (tv.string as NSString).length else { return }

        tv.breakUndoCoalescing()
        isProgrammaticEdit = true
        defer { isProgrammaticEdit = false }
        guard tv.shouldChangeText(in: target, replacementString: replacement) else { return }
        tv.textStorage?.replaceCharacters(in: target, with: replacement)
        tv.didChangeText()
        tv.undoManager?.setActionName("Replace")
        tv.breakUndoCoalescing()

        // Re-find on the edited text; keep the index so focus lands on the next
        // occurrence (or clamps to the last remaining one).
        let updated = findMatches(of: query, in: tv.string as NSString)
        let nextIndex = updated.isEmpty ? 0 : min(idx, updated.count - 1)
        renderFindMatches(updated, currentIndex: nextIndex)
        postFindResults(count: updated.count)
    }

    /// Replace every find match in a single undo step, then re-highlight.
    @objc func handleReplaceAll(_ notification: Notification) {
        guard let tv = textView, tv.isEditable,
              let info = notification.userInfo,
              let query = info["query"] as? String, !query.isEmpty,
              let replacement = info["replacement"] as? String else { return }

        let matches = findMatches(of: query, in: tv.string as NSString)
        guard !matches.isEmpty else { postFindResults(count: 0); return }

        // Group as one undo; edit back-to-front so earlier ranges stay valid.
        let orderedRanges = matches.reversed().map { NSValue(range: $0) }
        let replacements = Array(repeating: replacement, count: matches.count)

        tv.breakUndoCoalescing()
        isProgrammaticEdit = true
        defer { isProgrammaticEdit = false }
        guard tv.shouldChangeText(inRanges: orderedRanges, replacementStrings: replacements) else { return }
        tv.textStorage?.beginEditing()
        for match in matches.reversed() {
            tv.textStorage?.replaceCharacters(in: match, with: replacement)
        }
        tv.textStorage?.endEditing()
        tv.didChangeText()
        tv.undoManager?.setActionName("Replace All")
        tv.breakUndoCoalescing()

        // Usually zero remain; non-zero only if the replacement contains the query.
        let remaining = findMatches(of: query, in: tv.string as NSString)
        renderFindMatches(remaining, currentIndex: 0)
        postFindResults(count: remaining.count)
    }

    /// Drop find's own backgrounds and restyle the paragraphs they sat in.
    ///
    /// Removing `.backgroundColor` takes the styling background with it - one
    /// attribute, several owners - and nothing repaints it on its own, so an
    /// `==` block stayed blank until the next restyle happened to run (a click).
    /// Scoped to the marked ranges: paragraphs find never touched keep theirs.
    private func clearFindHighlights(in textView: NSTextView) {
        guard let storage = textView.textStorage else { return }
        let text = textView.string as NSString
        guard text.length > 0 else { return }

        var highlighted: [NSRange] = []
        storage.enumerateAttribute(
            .findHighlight,
            in: NSRange(location: 0, length: text.length),
            options: []
        ) { value, range, _ in
            if value != nil { highlighted.append(range) }
        }
        guard !highlighted.isEmpty else { return }

        for range in highlighted {
            storage.removeAttribute(.backgroundColor, range: range)
            storage.removeAttribute(.findHighlight, range: range)
        }
        // Raw source mode has no styling to restore; restyleParagraphs no-ops there.
        restyleParagraphs(highlighted.map { text.paragraphRange(for: $0) }, in: textView)
    }

    /// Highlight all matches (current one stronger) and scroll the current match into view.
    private func renderFindMatches(_ allRanges: [NSRange], currentIndex: Int) {
        guard let tv = textView else { return }
        let storage = tv.textStorage
        let fullRange = NSRange(location: 0, length: (tv.string as NSString).length)

        clearFindHighlights(in: tv)

        // Highlight all matches; the focused match gets a stronger color.
        let theme = configuration.theme
        let matchAlpha = configuration.markers.findMatchHighlightAlpha
        let highlightColor = theme.findMatchHighlight.withAlphaComponent(matchAlpha)
        let currentHighlightColor = theme.findCurrentMatchHighlight

        for (i, matchRange) in allRanges.enumerated() {
            guard matchRange.location + matchRange.length <= fullRange.length else { continue }
            let color = (i == currentIndex) ? currentHighlightColor : highlightColor
            storage?.addAttribute(.backgroundColor, value: color, range: matchRange)
            storage?.addAttribute(.findHighlight, value: true, range: matchRange)
        }

        if let tlm = tv.textLayoutManager {
            tlm.ensureLayout(for: tlm.documentRange)
        }

        // Scroll the current match into view.
        guard allRanges.indices.contains(currentIndex) else { return }
        let range = allRanges[currentIndex]
        guard range.location + range.length <= fullRange.length else { return }
        // Scroll via TextKit 2 fragment layout, which works whether or not the
        // reading column is active. `scrollRangeToVisible` is unreliable for
        // off-screen content in a TextKit 2 text view (it routes through the
        // absent TextKit 1 layout manager), so it's only the last-resort fallback.
        // When the text view IS the document view, `tv.frame.origin.y` is 0 and
        // the offset below is a no-op, so the same math serves both layouts.
        guard let tlm = tv.textLayoutManager,
              let scrollView = tv.enclosingScrollView,
              let matchStart = tlm.textContentManager?.location(tlm.documentRange.location, offsetBy: range.location) else {
            tv.scrollRangeToVisible(range)
            return
        }
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
                (scrollView as? ClampedScrollView)?.cancelPendingScrollRestore()
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

        clearFindHighlights(in: tv)
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
