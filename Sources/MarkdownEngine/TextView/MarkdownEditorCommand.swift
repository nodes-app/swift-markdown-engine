//
//  MarkdownEditorCommand.swift
//  MarkdownEngine
//

/// An editor command the engine did not consume and is offering to its host.
public enum MarkdownEditorCommand: Sendable, Equatable {
    /// The standard AppKit cancel operation, normally produced by Escape.
    case escape
    /// Forward tab traversal after editor-owned list indentation declines it.
    case tab
    /// Backward tab traversal after editor-owned list outdentation declines it.
    case backtab
}
