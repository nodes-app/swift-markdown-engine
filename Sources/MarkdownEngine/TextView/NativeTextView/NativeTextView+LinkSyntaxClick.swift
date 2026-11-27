//
//  NativeTextView+LinkSyntaxClick.swift
//  MarkdownEngine
//
//  Created by Luca Chen on 27.11.26.
//
//  A closed link keeps its syntax in the text - `[`, `](url)`, `[[`, `]]` -
//  drawn near zero width right beside its words. A plain click just beside the
//  words lands in that stack: AppKit parks the caret somewhere inside it (in
//  the URL, say) and reports no link click, so the edit zone in
//  `clickedOnLink`, which puts the caret just outside the markers, never runs,
//  and the link opens with the caret in its URL. This puts the caret where the
//  edit zone would.
//

import AppKit

extension MarkdownToken {
    /// Where a caret parked in this closed link's hidden syntax belongs: just
    /// outside the markers, on the side the click was on. Nil in the visible
    /// words, outside the link, and for every other kind of token.
    func caretOutsideHiddenLinkSyntax(_ caret: Int) -> Int? {
        guard kind == .link || kind == .wikiLink else { return nil }
        let start = range.location
        let end = NSMaxRange(range)
        // Right after the words counts too: the open link would show the
        // caret before its `](url)`, inside the syntax all the same.
        if caret >= NSMaxRange(contentRange), caret < end { return end }
        if caret > start, caret <= contentRange.location { return start }
        return nil
    }
}

extension NativeTextViewCoordinator {
    /// The caret a plain click left in a closed link's hidden syntax, moved
    /// outside it; nil when it can stay. `activeBefore` is the tokens open
    /// before the click: an open link shows its syntax, so a click in its URL
    /// is meant to edit it there.
    func caretOutsideHiddenLinkSyntax(_ caret: Int, in text: String, activeBefore: Set<Int>) -> Int? {
        guard !configuration.rawSourceMode else { return nil }
        for (index, token) in parsedDocument(for: text).tokens.enumerated()
        where !activeBefore.contains(index)
            && token.range.location < caret && caret < NSMaxRange(token.range) {
            if let outside = token.caretOutsideHiddenLinkSyntax(caret) { return outside }
        }
        return nil
    }
}

extension NativeTextView {
    /// After a plain single click that was no link click, AppKit's or the
    /// paragraph-spacing remap's: see the header.
    func moveCaretOutOfHiddenLinkSyntax(after event: NSEvent, activeBefore: Set<Int>) {
        let selection = selectedRange()
        guard isEditable, event.clickCount == 1, selection.length == 0,
              event.modifierFlags.intersection(.deviceIndependentFlagsMask).isEmpty,
              let coordinator = delegate as? NativeTextViewCoordinator,
              let outside = coordinator.caretOutsideHiddenLinkSyntax(
                  selection.location, in: string, activeBefore: activeBefore)
        else { return }
        setSelectedRange(NSRange(location: outside, length: 0))
    }
}
