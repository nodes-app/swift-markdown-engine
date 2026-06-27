//
//  NativeTextView+CmdReturn.swift
//  MarkdownEngine
//
//  ⌘↵ ("link & open") for the inline [[…]] preview. AppKit does NOT route ⌘+Return
//  through doCommandBy(insertNewline:), so we intercept it as a key equivalent — which
//  fires first for ⌘-combos — and forward `.confirmAndOpen` to the embedder.
//

import AppKit

extension NativeTextView {
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
           event.keyCode == 36 || event.keyCode == 76,            // Return / keypad Enter
           let coord = delegate as? NativeTextViewCoordinator,
           coord.isWikiLinkActive || coord.isImageEmbedActive,
           let handler = coord.onInlinePreviewKey,
           handler(.confirmAndOpen) {
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}
