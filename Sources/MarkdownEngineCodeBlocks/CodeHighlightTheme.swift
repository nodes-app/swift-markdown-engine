//
//  CodeHighlightTheme.swift
//  MarkdownEngineCodeBlocks
//
//  Created by Luca Chen on 16.10.26.
//

import AppKit

/// Token colours for ``HighlightJSBridge``, keyed by highlight.js scope name:
/// `keyword`, `string`, `title.function`, `variable.language`, … (the scope
/// `title.function` is what highlight.js's CSS calls `.hljs-title.function_`).
///
/// In code languages the bridge also scopes what highlight.js leaves plain:
/// `identifier`, `title.function.invoke` (calls), `property` (`.member`),
/// `operator` and `punctuation`.
///
/// A token takes the colour of its innermost scope that has one. A dotted
/// scope without its own entry falls back to its parent name
/// (`title.function.invoke` → `title.function` → `title`), and a token no
/// scope colours takes ``foreground``.
public struct CodeHighlightTheme {
    /// Colour of code no scope colours.
    public var foreground: NSColor
    /// The theme's own block background, used when the bridge is given none.
    public var background: NSColor
    /// Colour per highlight.js scope name.
    public var colors: [String: NSColor]

    public init(foreground: NSColor, background: NSColor, colors: [String: NSColor]) {
        self.foreground = foreground
        self.background = background
        self.colors = colors
    }

    /// The colour of a token nested in `scopes`, outermost first; `nil` leaves it at ``foreground``.
    public func color(forScopes scopes: [String]) -> NSColor? {
        for scope in scopes.reversed() {
            var name = Substring(scope)
            while true {
                if let color = colors[String(name)] {
                    return color
                }
                guard let dot = name.lastIndex(of: ".") else { break }
                name = name[..<dot]
            }
        }
        return nil
    }
}

extension CodeHighlightTheme {
    /// highlight.js's GitHub theme (`github.css`).
    public static let githubLight = CodeHighlightTheme(
        foreground: NSColor(hex: 0x24292E),
        background: NSColor(hex: 0xFFFFFF),
        colors: palette([
            0xD73A49: ["doctag", "keyword", "template-tag", "template-variable", "type", "variable.language"],
            0x6F42C1: ["title", "title.class", "title.class.inherited", "title.function"],
            0x005CC5: ["attr", "attribute", "literal", "meta", "number", "operator", "variable",
                       "selector-attr", "selector-class", "selector-id", "section"],
            0x032F62: ["regexp", "string"],
            0xE36209: ["built_in", "symbol"],
            0x6A737D: ["comment", "code", "formula"],
            0x22863A: ["name", "quote", "selector-tag", "selector-pseudo", "addition"],
            0x24292E: ["subst", "emphasis", "strong"],
            0x735C0F: ["bullet"],
            0xB31D28: ["deletion"],
        ])
    )

    /// highlight.js's GitHub Dark theme (`github-dark.css`).
    public static let githubDark = CodeHighlightTheme(
        foreground: NSColor(hex: 0xC9D1D9),
        background: NSColor(hex: 0x0D1117),
        colors: palette([
            0xFF7B72: ["doctag", "keyword", "template-tag", "template-variable", "type", "variable.language"],
            0xD2A8FF: ["title", "title.class", "title.class.inherited", "title.function"],
            0x79C0FF: ["attr", "attribute", "literal", "meta", "number", "operator", "variable",
                       "selector-attr", "selector-class", "selector-id"],
            0xA5D6FF: ["regexp", "string"],
            0xFFA657: ["built_in", "symbol"],
            0x8B949E: ["comment", "code", "formula"],
            0x7EE787: ["name", "quote", "selector-tag", "selector-pseudo"],
            0xC9D1D9: ["subst", "emphasis", "strong"],
            0x1F6FEB: ["section"],
            0xF2CC60: ["bullet"],
            0xAFF5B4: ["addition"],
            0xFFDCD7: ["deletion"],
        ])
    )

    private static func palette(_ groups: KeyValuePairs<Int, [String]>) -> [String: NSColor] {
        var colors: [String: NSColor] = [:]
        for (hex, scopes) in groups {
            for scope in scopes {
                colors[scope] = NSColor(hex: hex)
            }
        }
        return colors
    }
}

private extension NSColor {
    convenience init(hex: Int) {
        self.init(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: 1
        )
    }
}
