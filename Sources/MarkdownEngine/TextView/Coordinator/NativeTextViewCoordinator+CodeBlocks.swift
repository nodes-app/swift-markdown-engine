//
//  NativeTextViewCoordinator+CodeBlocks.swift
//  MarkdownEngine
//
//  Created by Luca Chen on 16.03.26.
//
//  Tracks code-block selections in the document so the host can render the
//  small "copy code" button overlay on top of every fenced code block. Skips
//  blocks the caret is currently inside (`activeTokenIndices`) to avoid the
//  button overlapping the cursor while editing.
//

import AppKit

extension NativeTextViewCoordinator {
    func updateCodeBlockSelection(textView: NSTextView, parsed: ParsedDocument? = nil) {
        guard let textContainer = textView.textContainer else {
            onCodeBlockSelectionChange?([])
            return
        }

        if let parsed {
            // Indexed pairs come from the parse's single classification pass —
            // no per-call full-token filter.
            cachedCodeBlockTokens = parsed.codeBlockTokensWithIndices
        } else if cachedCodeBlockTokens.isEmpty {
            onCodeBlockSelectionChange?([])
            return
        }

        let nsText = textView.string as NSString
        let scrollOffset = textView.enclosingScrollView?.contentView.bounds.origin ?? .zero

        // Identical inputs → identical selections. The delegate path calls
        // this twice per keystroke (selection change + textDidChange) and on
        // every caret move; skip the substring/language/viewRect work when
        // nothing relevant changed. Calls without `parsed` (document switch,
        // scroll hooks) always recompute.
        //
        // The key must include the FULL active-token set, not just its code
        // intersection: a caret move INTO a standalone block (block-LaTeX /
        // table) toggles that block between its rendered image and raw source
        // — a real height change that shifts a code block below it to a new Y
        // — while leaving version, scroll, width, and the code∩active set
        // unchanged. Keying on the whole active set makes any such toggle
        // (the only same-version event that moves layout) recompute. Text
        // edits are covered by the bumped version; the twice-per-keystroke
        // redundancy still dedupes because both calls share one active set.
        if let parsed {
            let key = (parsed.version, scrollOffset.y, textContainer.containerSize.width,
                       activeTokenIndices)
            if let last = lastCodeSelKey, last == key { return }
            lastCodeSelKey = key
        } else {
            lastCodeSelKey = nil
        }

        // One-shot full-document layout per document; fixes stale Y from TextKit 2's lazy layout without per-update cost.
        if !didEnsureLayoutForCurrentDocument, let tlm = textView.textLayoutManager {
            tlm.ensureLayout(for: tlm.documentRange)
            didEnsureLayoutForCurrentDocument = true
        }

        // Only on-screen code blocks have a visible copy button. Computing a
        // viewRect (and copying the code) for every block in the document is
        // O(doc) and dominates large files; cull to the laid-out viewport range
        // — scroll hooks recompute as blocks come into view.
        let visibleRange: NSRange? = {
            guard let tlm = textView.textLayoutManager,
                  let vp = tlm.textViewportLayoutController.viewportRange else { return nil }
            let start = tlm.offset(from: tlm.documentRange.location, to: vp.location)
            return NSRange(location: start, length: tlm.offset(from: vp.location, to: vp.endLocation))
        }()

        let selections: [CodeBlockSelection] = cachedCodeBlockTokens.compactMap { originalIndex, token in
            guard !activeTokenIndices.contains(originalIndex) else { return nil }
            if let visibleRange, NSIntersectionRange(token.range, visibleRange).length == 0 { return nil }
            guard var boundingRect = textView.viewRect(forCharacterRange: token.range, using: layoutBridge) else { return nil }

            boundingRect.origin.x = textView.frame.origin.x + textView.textContainerOrigin.x - scrollOffset.x
            boundingRect.size.width = textContainer.containerSize.width

            return CodeBlockSelection(
                id: originalIndex,
                rect: boundingRect,
                language: MarkdownTokenizer.extractLanguage(from: token, in: textView.string),
                code: nsText.substring(with: token.contentRange)
            )
        }

        onCodeBlockSelectionChange?(selections)
    }
}
