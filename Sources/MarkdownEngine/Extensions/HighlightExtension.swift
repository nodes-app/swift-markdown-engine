//
//  HighlightExtension.swift
//  MarkdownEngine
//
//  Created by Luca Chen on 15.07.26.
//
//  `==text==` highlight (Obsidian/CriticMarkup flavor) as the first inline
//  span extension. Not registered by default — the core engine parses pure
//  markdown; embedders opt in via:
//
//      configuration.extensions = [HighlightExtension()]
//
//  Behavior is identical to the formerly built-in construct: content gets the
//  theme's highlight background, content is re-parsed (emphasis etc. nest),
//  markers mute while the caret is inside and shrink away otherwise, and the
//  clean-copy path emits `<mark>`.
//

import AppKit
import Foundation

public struct HighlightExtension: MarkdownExtension {

    /// Well-known id, referenced by the engine's formatting actions
    /// (context menu / `applyHighlightRequest` toggle).
    public static let identifier = "highlight"

    public init() {}

    public var id: String { Self.identifier }

    public var inline: InlineSyntax? {
        InlineSyntax(open: "==", close: "==")
    }

    public func contentAttributes(theme: MarkdownEditorTheme) -> [NSAttributedString.Key: Any] {
        [.backgroundColor: theme.highlightColor]
    }

    public func html(childrenHTML: String) -> String {
        "<mark>\(childrenHTML)</mark>"
    }
}
