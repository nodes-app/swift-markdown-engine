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
//  - Synchronous `checkSpelling(of:startingAt:)` walk on a background
//    queue — deterministic, no unreliable completion handlers.
//  - 400 ms debounce. Cache is cleared **synchronously** on every
//    `textDidChange` before the next pass is scheduled, so the stale-
//    offset bug class never surfaces.
//  - System's own continuous-spell-check pass is disabled on 15.x so it
//    can't race with the engine's driver (the unreliable underlines that
//    sometimes appeared after selection changes were from the system's
//    pass, not ours).
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
            clearSpellMisspellings(textView: textView)
            return
        }
        // Disable the system's own continuous spell-check pass on 15.x
        // so it can't race with the engine's driver. On macOS 15.7.7 the
        // system's pass paints `.spellingState` unreliably (sometimes
        // after mount, sometimes after selection, rarely after edits),
        // producing the inconsistent underlines reported in testing.
        // The engine is the sole painter on 15.x.
        textView.isContinuousSpellCheckingEnabled = false
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

    /// Run a full-document scan on a background queue using the
    /// synchronous `checkSpelling(of:startingAt:)` loop. The previous
    /// async `requestChecking(of:…)` API was unreliable on macOS 15.x —
    /// its completion handler sometimes didn't fire after the first call,
    /// leaving the cache permanently empty after edits.
    ///
    /// Filters results against the engine's existing zone helpers so
    /// code, LaTeX, links, and image embeds never end up underlined.
    func runSpellCheckPass(textView: NSTextView) {
        guard #unavailable(macOS 26) else { return }
        guard userPrefersContinuousSpellChecking else {
            DispatchQueue.main.async {
                self.clearSpellMisspellings(textView: textView)
            }
            return
        }
        let string = textView.string
        let ns = string as NSString
        let length = ns.length
        guard length > 0 else {
            DispatchQueue.main.async {
                self.updateSpellMisspelledRanges([], textView: textView)
            }
            return
        }

        let checker = NSSpellChecker.shared
        let docTag = textView.spellCheckerDocumentTag

        // Synchronous walk on a background queue.
        // `checkSpelling(of:startingAt:)` is fast for typical note sizes
        // and deterministically calls back — no completion-handler race.
        DispatchQueue.global(qos: .userInitiated).async { [weak self, weak textView] in
            guard let self, let textView else { return }
            var misspelledRanges: [NSRange] = []
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
                if !self.shouldSuppressSpellMark(range: misspelled, in: string) {
                    misspelledRanges.append(misspelled)
                }
                searchStart = NSMaxRange(misspelled)
            }
            DispatchQueue.main.async {
                self.updateSpellMisspelledRanges(misspelledRanges, textView: textView)
            }
        }
    }

    /// Empties the misspelling set and triggers a redraw so any leftover
    /// underlines disappear immediately. Called synchronously from
    /// `textDidChange` and from `didToggleSpellCheckingPolicy` (off).
    func clearSpellMisspellings(textView: NSTextView) {
        guard !spellMisspelledRanges.isEmpty else { return }
        updateSpellMisspelledRanges([], textView: textView)
    }

    /// Replaces the stored set and asks the text view to redraw. The
    /// fragment's `draw(at:in:)` reads from `spellMisspelledRanges` on
    /// each repaint, so a simple `needsDisplay = true` is enough — no
    /// layout invalidation required.
    private func updateSpellMisspelledRanges(_ ranges: [NSRange], textView: NSTextView) {
        spellMisspelledRanges = ranges
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
