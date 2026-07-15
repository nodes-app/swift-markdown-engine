//
//  StrikethroughExtension.swift
//  MarkdownEngine
//
//  Created by Luca Chen on 15.07.26.
//
//  `~~text~~` strikethrough (GFM flavor) as an inline span extension. Not
//  registered by default — the core engine parses pure markdown; embedders
//  opt in via:
//
//      configuration.extensions = [StrikethroughExtension()]
//
//  Matches the formerly built-in semantics exactly, including the stricter
//  GFM-ish run handling: `~~a~~~` stays literal (the closer must not extend
//  into a longer `~` run), unlike highlight's tolerant `==abc===`.
//

import AppKit
import Foundation

public struct StrikethroughExtension: MarkdownExtension {

    /// Well-known id, referenced by the engine's formatting actions
    /// (context menu / `applyStrikethroughRequest` toggle).
    public static let identifier = "strikethrough"

    public init() {}

    public var id: String { Self.identifier }

    public var inline: InlineSyntax? {
        InlineSyntax(open: "~~", close: "~~", rejectsCloserRun: true)
    }

    public func contentAttributes(theme: MarkdownEditorTheme) -> [NSAttributedString.Key: Any] {
        [
            .strikethroughStyle: NSUnderlineStyle.single.rawValue,
            .strikethroughColor: theme.strikethroughColor,
        ]
    }

    public func html(childrenHTML: String) -> String {
        "<del>\(childrenHTML)</del>"
    }
}
