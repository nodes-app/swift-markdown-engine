//
//  EditorFileDrop.swift
//  MarkdownEngine
//
//  Created by Luca Chen on 06.11.26.
//

import AppKit

/// What a drop of files onto the text does.
public enum EditorFileDropAction: Sendable, Equatable {
    /// The files go into the text where they are dropped. While dragging, the
    /// insertion point shows where.
    case insert
    /// The embedder takes the files itself, e.g. into an import panel. The text
    /// accepts the drop without showing an insertion point.
    case handOff
    /// The text does not take this drop.
    case refuse
}

/// Files dragged onto the text from Finder, the desktop or a screenshot thumbnail.
/// Without one, the text view keeps AppKit's own drag handling. Drags of text are
/// never affected, only drags that carry file URLs.
public struct EditorFileDrop {
    /// Decides the drop while it is dragged, asked again as the modifier keys change.
    public var action: (_ files: [URL], _ modifiers: NSEvent.ModifierFlags) -> EditorFileDropAction
    /// For `.insert`: the Markdown to put where the files were dropped (it lands on
    /// lines of its own), or nil to insert nothing.
    public var markdown: (_ files: [URL]) -> String?
    /// For `.handOff`: the dropped files.
    public var handOff: (_ files: [URL]) -> Void

    public init(
        action: @escaping (_ files: [URL], _ modifiers: NSEvent.ModifierFlags) -> EditorFileDropAction,
        markdown: @escaping (_ files: [URL]) -> String?,
        handOff: @escaping (_ files: [URL]) -> Void
    ) {
        self.action = action
        self.markdown = markdown
        self.handOff = handOff
    }
}
