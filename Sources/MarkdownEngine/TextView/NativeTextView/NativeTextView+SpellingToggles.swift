//
//  NativeTextView+SpellingToggles.swift
//  MarkdownEngine
//
//  Created by Nicolas Mallinckrodt on 19.05.26.
//
//  AppKit's context menu and Edit > Spelling and Grammar menu route through
//  these action methods. We forward to `super` so the standard menu state
//  flips, then snapshot the result into the coordinator so the user's choice
//  survives the next `updateAutocorrectSettings` pass (which otherwise
//  restores the "on" state whenever the caret leaves a code/LaTeX/link span).
//

#if os(macOS)
import AppKit

extension NativeTextView {
    override func toggleContinuousSpellChecking(_ sender: Any?) {
        super.toggleContinuousSpellChecking(sender)
        (delegate as? NativeTextViewCoordinator)?.didToggleSpellCheckingPolicy(textView: self)
    }

    override func toggleGrammarChecking(_ sender: Any?) {
        super.toggleGrammarChecking(sender)
        (delegate as? NativeTextViewCoordinator)?.didToggleSpellCheckingPolicy(textView: self)
    }

    override func toggleAutomaticSpellingCorrection(_ sender: Any?) {
        super.toggleAutomaticSpellingCorrection(sender)
        (delegate as? NativeTextViewCoordinator)?.didToggleSpellCheckingPolicy(textView: self)
    }
}
#endif
