//
//  MarkdownTextMutation.swift
//  MarkdownEngine
//

import Foundation

/// One completed native editor mutation in UTF-16 display-text coordinates.
///
/// `range` addresses the text before the edit and `replacement` is the exact
/// string that replaced it. MarkdownEngine reports only transitions backed by
/// one accepted native edit; multi-step smart-input transformations and
/// ambiguous composition batches are intentionally omitted.
public struct MarkdownTextMutation: Equatable, Sendable {
    public let range: NSRange
    public let replacement: String

    public init(range: NSRange, replacement: String) {
        self.range = range
        self.replacement = replacement
    }
}
