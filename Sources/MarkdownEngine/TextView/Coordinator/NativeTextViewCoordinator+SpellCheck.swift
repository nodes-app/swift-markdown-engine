//
//  NativeTextViewCoordinator+SpellCheck.swift
//  MarkdownEngine
//
//  macOS 15.x fallback spell-check driver. On macOS 26+ AppKit's own
//  TextKit 2 pass paints `.spellingState` underlines via the default
//  fragment. On 15.x that path is broken (the system neither writes nor
//  renders `.spellingState` on custom fragments), so the engine drives
//  `NSSpellChecker` itself and paints dotted-red underlines from the
//  coordinator's misspelled-range cache in
//  `MarkdownTextLayoutFragment.draw(at:in:)`.
//
//  Design (see devlog-0610-spellcheck-15x-fallback-design.md):
//  - Synchronous `checkSpelling(of:startingAt:)` walk on the main
//    thread — deterministic, no background-queue data races.
//  - 400 ms debounce. Cache is cleared **synchronously** on every
//    `textDidChange` before the next pass is scheduled, so the stale-
//    offset bug class never surfaces.
//  - The system's own continuous spell-check pass is left enabled.
//    On macOS 15.x it paints on the default fragment (which our custom
//    fragment replaces), so it can't interfere with our cache-based
//    drawing. Disabling it was tried and caused a recursive
//    textDidChange cascade that cancelled the debounced pass.
//  - Reuses existing zone helpers (`isInsideCode`, `isInsideLatex`,
//    `isInsideSpellcheckSuppressedToken`) — same gates as
//    `NativeTextView+SpellingPolicy`. Belt-and-suspenders with the
//    `.spellingState: 0` stamps added by PR #64.
//  - Uses `textView.spellCheckerDocumentTag` (not a private tag) so
//    the system "Ignore Spelling" action clears the underline.
//  - `didToggleSpellCheckingPolicy` cancels the pending pass on
//    toggle-off and schedules an immediate pass on toggle-on.
//

import AppKit

extension NativeTextViewCoordinator {
    /// Debounce window between the last edit and the spell-check pass.
    /// Long enough to avoid stalling fast typists, short enough that the
    /// underline appears almost as soon as the word boundary is crossed.
    private static let spellCheckDebounce: TimeInterval = 0.4

    /// Schedule a (debounced) spell-check pass over the entire document.
    /// Subsequent calls within the debounce window cancel the previous
    /// scheduled pass.
    ///
    /// The coordinator's `spellMisspelledRanges` cache is assumed to have
    /// been cleared by the caller (typically `textDidChange`) BEFORE this
    /// method is invoked — that's what prevents stale-offset underlines
    /// from painting during the debounce window.
    func scheduleSpellCheck(textView: NSTextView) {
        spellCheckWorkItem?.cancel()
        // On macOS 26+ AppKit's own TextKit 2 pass paints the underline
        // via the default fragment. Running the engine driver here would
        // produce double underlines (the system pass + our cache-based
        // fragment pass).
        guard #unavailable(macOS 26) else {
            spellMisspelledRanges.removeAll()
            return
        }
        guard userPrefersContinuousSpellChecking else {
            // Toggle is off — make sure stale marks aren't left around.
            print("[SC] schedule: toggle OFF, clearing")
            clearSpellMisspellings(textView: textView)
            return
        }
        print("[SC] schedule: queued, len=\((textView.string as NSString).length)")
        // NOTE: the system's own continuous spell-check pass is left
        // enabled. On macOS 15.x it paints on the default fragment
        // (which our custom MarkdownTextLayoutFragment replaces), so
        // its `.spellingState` underlines are invisible. Our cache-
        // based drawing in drawSpellMisspellings is the sole visible
        // painter. Disabling the system pass via
        // `textView.isContinuousSpellCheckingEnabled = false` was tried
        // but caused a recursive textDidChange cascade (AppKit clears
        // .spellingState attributes synchronously, which triggers a
        // delegate call that cancels the debounced pass).
        let work = DispatchWorkItem { [weak self, weak textView] in
            guard let self, let textView else { return }
            self.runSpellCheckPass(textView: textView)
        }
        spellCheckWorkItem = work
        DispatchQueue.main.asyncAfter(
            deadline: .now() + Self.spellCheckDebounce,
            execute: work
        )
    }

    /// Run a full-document scan on the main thread using the
    /// synchronous `checkSpelling(of:startingAt:)` loop.
    ///
    /// Previous approaches used a background queue (async
    /// `requestChecking` or `DispatchQueue.global`), but both were
    /// unreliable on macOS 15.x:
    /// - `requestChecking`'s completion handler sometimes never fired
    ///   after the first call.
    /// - Background-queue access to `textView.string` (not thread-safe)
    ///   and `shouldSuppressSpellMark` (reads `cachedParsedDocument`
    ///   which the main thread mutates during restyles) caused data
    ///   races that silently produced empty results after edits.
    ///
    /// For typical notes (hundreds of words, a handful of
    /// misspellings) the synchronous walk takes single-digit
    /// milliseconds — well within the 400 ms debounce window.
    ///
    /// Filters results against the engine's existing zone helpers so
    /// code, LaTeX, links, and image embeds never end up underlined.
    func runSpellCheckPass(textView: NSTextView) {
        guard #unavailable(macOS 26) else { return }
        guard userPrefersContinuousSpellChecking else {
            print("[SC] run: toggle OFF")
            clearSpellMisspellings(textView: textView)
            return
        }
        let string = textView.string
        let ns = string as NSString
        let length = ns.length
        print("[SC] run: start len=\(length)")
        guard length > 0 else {
            print("[SC] run: empty doc")
            updateSpellMisspelledRanges([], textView: textView)
            return
        }

        let checker = NSSpellChecker.shared
        let docTag = textView.spellCheckerDocumentTag

        // Synchronous walk on the main thread — avoids all threading
        // issues with NSTextView.string and the parsedDocument cache.
        var misspelledRanges: [NSRange] = []
        var rawHits = 0
        var searchStart = 0
        while searchStart < length {
            let misspelled = checker.checkSpelling(
                of: ns as String,
                startingAt: searchStart,
                language: nil,
                wrap: false,
                inSpellDocumentWithTag: docTag,
                wordCount: nil
            )
            guard misspelled.location != NSNotFound else { break }
            rawHits += 1
            if !shouldSuppressSpellMark(range: misspelled, in: string) {
                misspelledRanges.append(misspelled)
            }
            searchStart = NSMaxRange(misspelled)
        }
        print("[SC] run: done rawHits=\(rawHits) kept=\(misspelledRanges.count) tag=\(docTag)")
        updateSpellMisspelledRanges(misspelledRanges, textView: textView)
    }

    /// Empties the misspelling set and triggers a redraw so any leftover
    /// underlines disappear immediately. Called synchronously from
    /// `textDidChange` and from `didToggleSpellCheckingPolicy` (off).
    func clearSpellMisspellings(textView: NSTextView) {
        guard !spellMisspelledRanges.isEmpty else { return }
        updateSpellMisspelledRanges([], textView: textView)
    }

    /// Replaces the stored set and forces every fragment overlapping an
    /// affected range to re-execute its draw. `textView.needsDisplay = true`
    /// alone is insufficient on macOS 15.x because TextKit 2 maintains
    /// per-fragment rendering caches: a paragraph that wasn't restyled or
    /// re-laid-out simply re-blits its old imagery, so newly-discovered
    /// misspellings outside the edited paragraph never paint until
    /// something forces a full re-layout (panel show/hide, selection
    /// change, etc.).
    ///
    /// `invalidateRenderingAttributes(for:)` is too soft — the layout
    /// manager treats it as a hint and may silently no-op when no
    /// rendering-attribute spans actually changed in the range. We saw
    /// this in repro logs: the call returned, no `draw(at:in:)` followed,
    /// and underlines stayed gone until a selection change forced a
    /// fresh display pass.
    ///
    /// `invalidateLayout(for:)` always busts the fragment's drawing
    /// cache and re-runs `draw(at:in:)` on the next display tick. Layout
    /// re-runs only over the small misspelling ranges, so cost is
    /// bounded. We pair it with `textView.needsDisplay = true` so the
    /// containing view actually schedules the next display pass.
    private func updateSpellMisspelledRanges(_ ranges: [NSRange], textView: NSTextView) {
        print("[SC] update: was=\(spellMisspelledRanges.count) now=\(ranges.count)")
        let previous = spellMisspelledRanges
        spellMisspelledRanges = ranges

        guard let tlm = textView.textLayoutManager,
              let tcs = tlm.textContentManager as? NSTextContentStorage else {
            textView.needsDisplay = true
            return
        }

        for nsRange in (previous + ranges) where nsRange.length > 0 {
            guard let textRange = TextStylingService.textRange(from: nsRange, in: tcs) else { continue }
            tlm.invalidateLayout(for: textRange)
        }
        textView.needsDisplay = true
    }

    /// True when the candidate misspelling falls inside a zone where the
    /// engine deliberately disables spell marks (code, LaTeX, link, embed).
    /// Same gates as `NativeTextView+SpellingPolicy`.
    private func shouldSuppressSpellMark(range: NSRange, in text: String) -> Bool {
        if text.contains("`"), isInsideCode(range: range, in: text) {
            return true
        }
        if text.contains("$"), isInsideLatex(location: range.location, in: text) {
            return true
        }
        return isInsideSpellcheckSuppressedToken(range: range, in: text)
    }
}
