#if os(macOS)
//
//  NativeTextViewCoordinator+CaretColor.swift
//  MarkdownEngine
//
//  Created by Luca Chen on 30.07.26.
//
//  The caret takes the ink of the span it sits in. An extension paints its
//  content with its own attributes, and one that inverts — dark ink on a light
//  block, e.g. an inverted `==highlight==` — leaves a `theme.bodyText` caret
//  drawn in the block's own color, i.e. invisible. Generic on purpose: any
//  extension whose `contentAttributes` carry a foreground gets this for free.
//

import AppKit
import Foundation

extension NativeTextViewCoordinator {

    /// Foreground an extension paints at `location`, or `theme.bodyText`.
    /// Only the CONTENT counts — on the `==` markers the background is the page
    /// again, so the caret belongs back at the body color.
    ///
    /// Runs on every keystroke, so it borrows both of the caller's results: the
    /// already-parsed `tokens` (a `parsedDocument` call without the edit
    /// descriptor would drop the keystroke's O(edit) splice onto an O(doc)
    /// verify) and `active`, the memoized set of tokens the caret is inside —
    /// which turns this from a pass over every token in the document into a
    /// look at the two or three under the caret.
    func caretColor(at location: Int, tokens: [MarkdownToken], active: Set<Int>) -> NSColor {
        let theme = configuration.theme
        guard configuration.cursorFollowsSpanInk else { return theme.bodyText }
        // Which extensions repaint their ink at all — for a registry where none
        // does (the engine's own highlight/strikethrough paint background and
        // decoration only) this is where the work stops, before the token scan.
        var inkByID: [String: NSColor] = [:]
        for ext in configuration.extensions {
            if let color = ext.contentAttributes(theme: theme)[.foregroundColor] as? NSColor {
                inkByID[ext.id] = color
            }
        }
        guard !inkByID.isEmpty else { return theme.bodyText }
        var innermost: (length: Int, color: NSColor)?
        for index in active {
            guard index >= 0, index < tokens.count else { continue }
            let token = tokens[index]
            guard case .extensionSpan(let id) = token.kind, let color = inkByID[id],
                  location >= token.contentRange.location,
                  location <= NSMaxRange(token.contentRange)
            else { continue }
            if innermost == nil || token.contentRange.length < innermost!.length {
                innermost = (token.contentRange.length, color)   // nested spans: the tightest one wins
            }
        }
        return innermost?.color ?? theme.bodyText
    }
}
#endif
