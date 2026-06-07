//
//  NativeTextViewCoordinator+SpellCheck.swift
//  MarkdownEngine
//
//  Drives NSSpellChecker manually and stores misspelled ranges that
//  `MarkdownTextLayoutFragment.draw(at:in:)` paints as dotted-red
//  underlines. Required because NSTextView's automatic spell-mark
//  rendering does not fire for our custom NSTextLayoutFragment subclass
//  in TextKit 2 — `setSpellingState(_:range:)` and the
//  `isContinuousSpellCheckingEnabled` flag both end up as no-ops
//  visually unless we draw the marks ourselves.
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
    func scheduleSpellCheck(textView: NSTextView) {
        spellCheckWorkItem?.cancel()
        guard userPrefersContinuousSpellChecking else {
            // Toggle is off — make sure stale marks aren't left around.
            clearSpellMisspellings(textView: textView)
            return
        }
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

    /// Run a synchronous full-document scan via `NSSpellChecker.shared`.
    /// Filters results against the engine's existing zone helpers so code,
    /// LaTeX, links, and image embeds never end up underlined.
    func runSpellCheckPass(textView: NSTextView) {
        guard userPrefersContinuousSpellChecking else {
            clearSpellMisspellings(textView: textView)
            return
        }
        let string = textView.string
        let length = (string as NSString).length
        guard length > 0 else {
            updateMisspelledRanges([], textView: textView)
            return
        }
        let checker = NSSpellChecker.shared
        var ranges: [NSRange] = []
        var location = 0
        while location < length {
            var wordCount = 0
            let range = checker.checkSpelling(
                of: string,
                startingAt: location,
                language: nil,
                wrap: false,
                inSpellDocumentWithTag: spellCheckDocumentTag,
                wordCount: &wordCount
            )
            if range.location == NSNotFound { break }
            if range.length == 0 {
                location = max(location + 1, NSMaxRange(range))
                continue
            }
            // Honour engine zone suppression — same gates that
            // `NativeTextView.setSpellingState` uses.
            if !shouldSuppressSpellMark(range: range, in: string) {
                ranges.append(range)
            }
            location = NSMaxRange(range)
        }
        updateMisspelledRanges(ranges, textView: textView)
    }

    /// Empties the misspelling set and triggers a redraw so any leftover
    /// underlines disappear immediately.
    func clearSpellMisspellings(textView: NSTextView) {
        guard !spellMisspelledRanges.isEmpty else { return }
        updateMisspelledRanges([], textView: textView)
    }

    /// Replaces the stored set and asks the text view to redraw. The
    /// fragment's `draw(at:in:)` reads from `spellMisspelledRanges` on
    /// each repaint, so a simple `setNeedsDisplay` is enough — no need
    /// to invalidate layout.
    private func updateMisspelledRanges(_ ranges: [NSRange], textView: NSTextView) {
        spellMisspelledRanges = ranges
        textView.needsDisplay = true
    }

    /// True when the candidate misspelling falls inside a zone where the
    /// engine deliberately disables spell marks (code, LaTeX, link, embed).
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
