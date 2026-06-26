//
//  NativeTextViewCoordinator+WikiLinkSnapback.swift
//  MarkdownEngine
//
//  Snap-back: when the caret LEAVES a `[[Name]]` / `![[Name]]` token, re-sync the
//  token's DISPLAYED name to the target node's CURRENT name (via the resolver) —
//  so a manually-edited/drifted label corrects itself the moment you click/move
//  out of the link, like a Notion mention. This is the live-editing counterpart
//  to `WikiLinkService.makeDisplayState`, which only re-injects the live name on a
//  full rebuild/load. The on-disk storage then heals via the normal
//  `makeStorageState` writeback on the next `textDidChange`.
//
//  Modeled on the proven surgical core of `applyInlineReplacement`
//  (+Restyling.swift) but stripped to the snap-back job and owning its own caret
//  + undo contract (one isolated, named "Update Link Name" step).
//

import AppKit

extension NativeTextViewCoordinator {
    /// When the caret LEAVES a `[[Name]]` / `![[Name]]` token, re-sync the displayed
    /// name to the target node's current name (via the resolver). Returns the caret
    /// location the caller should re-settle to (delta-adjusted), or nil if it did nothing.
    @discardableResult
    func resyncWikiLinkNameOnLeave(_ textView: NSTextView, token: MarkdownToken, caretLoc: Int) -> Int? {
        guard !isProgrammaticEdit, !textView.hasMarkedText(), !isWritingToolsActive else { return nil }
        guard token.kind == .wikiLink || token.kind == .imageEmbed else { return nil }
        guard let storage = textView.textStorage else { return nil }
        let contentRange = token.contentRange
        let docLen = storage.length
        guard contentRange.location != NSNotFound, contentRange.length > 0,
              NSMaxRange(contentRange) <= docLen else { return nil }
        // Defensive: only re-sync once the caret has actually LEFT the token (the caret-delta math below assumes it).
        guard !NSLocationInRange(caretLoc, contentRange) else { return nil }
        // Opaque suffix (uuid or uuid|width) lives in .wikiLinkID, uniform over the name run.
        guard let suffix = storage.attribute(.wikiLinkID, at: contentRange.location, effectiveRange: nil) as? String,
              !suffix.isEmpty else { return nil }
        let bareID = suffix.split(separator: "|", maxSplits: 1).first.map(String.init) ?? suffix
        // Reject names with [[ ]] grammar chars (incl. '[') so a bracketed node name falls back to the stored label.
        guard let live = configuration.services.wikiLinks.name(forID: bareID), !live.isEmpty,
              live.rangeOfCharacter(from: CharacterSet(charactersIn: "|]\n\r[")) == nil else { return nil }
        let currentName = (storage.string as NSString).substring(with: contentRange)
        guard live != currentName else { return nil } // no churn + loop terminator

        textView.breakUndoCoalescing()
        isProgrammaticEdit = true
        defer { isProgrammaticEdit = false }
        guard textView.shouldChangeText(in: contentRange, replacementString: live) else { return nil }
        storage.replaceCharacters(in: contentRange, with: live)
        let newContentRange = NSRange(location: contentRange.location, length: (live as NSString).length)
        storage.addAttribute(.wikiLinkID, value: suffix, range: newContentRange)
        // Suppress the auto-reveal that didChangeText's writeback can trigger (a tall image embed
        // would otherwise scroll-jump on snap-back). The caller suppresses the final setSelectedRange too.
        (textView as? NativeTextView)?.suppressAutoRevealOnce = true
        textView.didChangeText()
        textView.undoManager?.setActionName("Update Link Name")
        textView.breakUndoCoalescing()

        let delta = (live as NSString).length - contentRange.length
        // Caret is OUTSIDE the token (it just left). Shift only if the link is before the caret.
        let newCaret = (NSMaxRange(contentRange) <= caretLoc) ? caretLoc + delta : caretLoc
        return newCaret
    }
}
