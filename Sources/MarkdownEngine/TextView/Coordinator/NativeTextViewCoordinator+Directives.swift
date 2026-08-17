//
//  NativeTextViewCoordinator+Directives.swift
//  MarkdownEngine
//
//  Phase 4 — directive autocomplete, riding the seam the `[[wiki-link]]`
//  picker already established: the engine detects the trigger, reports the
//  caret rect, and routes ↑/↓/↵/Esc; the EMBEDDER draws the list. No picker UI
//  ships in the engine.
//
//  What the engine does own is the CANDIDATES, because it owns the registry:
//  names come from the registered directives, values from the directive whose
//  call the caret sits in. A newly registered directive therefore appears in
//  the picker with no embedder change at all — which is the whole point of
//  "new commands should be easy to create and plug in".
//

import AppKit
import Foundation

extension NativeTextViewCoordinator {

    /// Recompute the caret's directive-completion context and publish it.
    /// Called from `textViewDidChangeSelection`.
    ///
    /// `codeTokens` gate the whole thing: typing `@icon(` inside a code span
    /// or fenced block must not pop a picker.
    func updateDirectiveCompletion(_ textView: NSTextView, text: NSString, codeTokens: [MarkdownToken], isTyping: Bool) {
        guard !configuration.rawSourceMode,
              !configuration.directives.isEmpty,
              textView.isEditable,
              !isWritingToolsActive,
              !textView.hasMarkedText()          // mid-IME composition
        else {
            publishDirectiveCompletion(nil)
            return
        }

        let selection = textView.selectedRange()
        // Autocomplete follows a caret, not a selection, and only while
        // TYPING — clicking into an existing call shouldn't pop the picker
        // (the same gate the wiki-link picker uses).
        guard selection.length == 0, isTyping else {
            publishDirectiveCompletion(nil)
            return
        }
        guard !MarkdownDetection.isInsideCodeBlock(location: selection.location, codeTokens: codeTokens) else {
            publishDirectiveCompletion(nil)
            return
        }

        let context = DirectiveCompletionScanner.context(
            in: text,
            caret: selection.location,
            registry: cachedExtensionRegistry.directives,
            directives: configuration.directives,
            settings: configuration.directiveSettings
        )
        if let context {
            let rect = textView.viewRect(forCharacterRange: context.replacementRange, using: layoutBridge)
                ?? textView.viewRect(forCharacterRange: selection, using: layoutBridge)
            if let rect {
                DispatchQueue.main.async { self.onCaretRectChange?(rect) }
            }
        }
        publishDirectiveCompletion(context)
    }

    private func publishDirectiveCompletion(_ context: DirectiveCompletionContext?) {
        // `isDirectiveCompletionActive` gates key routing in `doCommandBy`,
        // which runs BEFORE the async hand-off below — so set it synchronously
        // or the first ↓ after the picker opens would fall through to the
        // text view and move the caret instead.
        let wasActive = isDirectiveCompletionActive
        isDirectiveCompletionActive = context != nil
        guard context != nil || wasActive else { return }   // nothing to say
        DispatchQueue.main.async { self.onDirectiveCompletion?(context) }
    }

    /// Apply a picked candidate: replace the range, place the caret.
    ///
    /// Deliberately NOT routed through `applyInlineReplacement` — that path
    /// runs the wiki-link storage/display transform and stamps `.wikiLinkID`,
    /// neither of which means anything for a directive.
    func applyDirectiveCompletion(_ request: DirectiveCompletionRequest, to textView: NSTextView) {
        lastAppliedDirectiveCompletionID = request.id

        let text = textView.string as NSString
        let range = request.replacementRange
        guard range.location != NSNotFound,
              range.location >= 0,
              NSMaxRange(range) <= text.length
        else { return }

        textView.breakUndoCoalescing()
        isProgrammaticEdit = true
        defer { isProgrammaticEdit = false }

        guard textView.shouldChangeText(in: range, replacementString: request.insertion) else { return }
        textView.textStorage?.replaceCharacters(in: range, with: request.insertion)
        textView.didChangeText()
        textView.undoManager?.setActionName("Insert Directive")
        textView.breakUndoCoalescing()

        // Caret lands where the candidate asked — inside `(…)` or `{…}` for a
        // snippet, past the value for a plain one.
        let offset = request.caretOffset ?? (request.insertion as NSString).length
        let documentLength = (textView.string as NSString).length
        let caret = min(max(range.location + offset, 0), documentLength)
        textView.setSelectedRange(NSRange(location: caret, length: 0))

        // The picker's own dismissal is the embedder's business, but the
        // engine must stop routing keys to it immediately.
        isDirectiveCompletionActive = false
        DispatchQueue.main.async { self.onDirectiveCompletion?(nil) }
    }
}
