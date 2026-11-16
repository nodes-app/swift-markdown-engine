//
//  NativeTextView+UndoGuard.swift
//  MarkdownEngine
//
//  Created by Luca Chen on 09.11.26.
//
//  ⌘Z and ⇧⌘Z. NSTextView leaves undo: and redo: to NSWindow, which asks the
//  first responder's undo manager; taking them here lets the coordinator check
//  the stack against the text first (`validateUndoBaseline`).
//

import AppKit

extension NativeTextView {
    @objc func undo(_ sender: Any?) {
        (delegate as? NativeTextViewCoordinator)?.validateUndoBaseline(self)
        undoManager?.undo()
    }

    @objc func redo(_ sender: Any?) {
        (delegate as? NativeTextViewCoordinator)?.validateUndoBaseline(self)
        undoManager?.redo()
    }

    /// The menu items as NSWindow validates them: AppKit's localized titles
    /// ("Undo Typing"), enabled when there is something to undo. Nil for any
    /// other item.
    func validateUndoItem(_ item: any NSValidatedUserInterfaceItem) -> Bool? {
        switch item.action {
        case #selector(undo(_:)):
            guard let undoManager else { return false }
            (item as? NSMenuItem)?.title = undoManager.undoMenuItemTitle
            return undoManager.canUndo
        case #selector(redo(_:)):
            guard let undoManager else { return false }
            (item as? NSMenuItem)?.title = undoManager.redoMenuItemTitle
            return undoManager.canRedo
        default:
            return nil
        }
    }
}
