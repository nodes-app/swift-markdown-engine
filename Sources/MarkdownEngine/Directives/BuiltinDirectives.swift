//
//  BuiltinDirectives.swift
//  MarkdownEngine
//
//  The two reference directives, mirroring how `HighlightExtension` /
//  `StrikethroughExtension` ship: not registered by default, opted into the
//  same way, and present mainly as templates for writing your own.
//
//      configuration.directives = [FontDirective(), ColorDirective()]
//
//  Both are PURE PRESENTATION — a font transform and a colour. Both are
//  containers, so neither draws a glyph; directives that carry curated data
//  (icons, flags, emoji) or encode document policy (page breaks) are app
//  concerns, not engine primitives, so they belong to the embedder. `Demo/`
//  shows what those look like.
//

import AppKit
import Foundation

// MARK: - @font(size: 18){…}  — container, font composition

/// The motivating case.
///
/// Note the FORM: a bare `@font(size: 18)` has no meaning under tree-shaped
/// semantics — there is nothing for it to apply to — so the directive requires
/// a body. That is the one place this seam departs from a LaTeX-style
/// `\font(size: 18)` sketch, and it is what keeps per-keystroke restyling
/// block-local.
public struct FontDirective: MarkdownDirective {

    /// Well-known id, so embedders can reference the directive without
    /// constructing one.
    public static let identifier = "font"

    public init() {}

    public var id: String { Self.identifier }

    public var syntax: DirectiveSyntax {
        DirectiveSyntax(
            name: Self.identifier,
            form: .container,
            parameters: [
                .init(label: "size", kind: .length,
                      documentation: "Point size, or 1.5em / 120% relative to the surrounding text."),
                .init(label: "family", kind: .string,
                      documentation: "Font family name; falls back to the editor font when unavailable."),
                .init(label: "weight", kind: .keyword(["regular", "bold"]),
                      defaultValue: .keyword("regular"),
                      documentation: "Font weight."),
            ]
        )
    }

    public var completion: DirectiveCompletion {
        DirectiveCompletion(
            id: id,
            title: "font",
            subtitle: "Set size, family, or weight for a span",
            keywords: ["size", "typeface", "typography"],
            snippet: "@font(size: |){}",
            symbolName: "textformat.size"
        )
    }

    public func style(arguments: DirectiveArguments, context: DirectiveContext) -> DirectiveStyle {
        // An invalid call mutes rather than restyles, so a typo reads as broken
        // instead of silently doing nothing.
        guard arguments.isValid else {
            return DirectiveStyle(attributes: [.foregroundColor: context.theme.disabledText])
        }
        var transform = DirectiveFontTransform()
        if let size = arguments.length("size", relativeTo: context.inheritedFont.pointSize) {
            transform.size = .absolute(size)
        }
        transform.familyName = arguments.string("family")
        if arguments.string("weight") == "bold" { transform.traits = .boldFontMask }
        return DirectiveStyle(font: transform)
    }

    public func html(arguments: DirectiveArguments, bodyHTML: String) -> String {
        var css: [String] = []
        if let size = arguments.number("size") { css.append("font-size:\(size)px") }
        if let family = arguments.string("family") { css.append("font-family:\(family)") }
        if arguments.string("weight") == "bold" { css.append("font-weight:bold") }
        return css.isEmpty ? bodyHTML : "<span style=\"\(css.joined(separator: ";"))\">\(bodyHTML)</span>"
    }
}

// MARK: - @color(red){…}  — container, positional argument

public struct ColorDirective: MarkdownDirective {

    public static let identifier = "color"

    public init() {}

    public var id: String { Self.identifier }

    /// Standard colour names, resolved without an asset catalog so
    /// `@color(red){…}` works out of the box. An unlisted name falls back to
    /// `NSColor(named:)`, so embedders can add their own palette entries.
    private static let named: [String: NSColor] = [
        "red": .systemRed, "orange": .systemOrange, "yellow": .systemYellow,
        "green": .systemGreen, "mint": .systemMint, "teal": .systemTeal,
        "cyan": .systemCyan, "blue": .systemBlue, "indigo": .systemIndigo,
        "purple": .systemPurple, "pink": .systemPink, "brown": .systemBrown,
        "gray": .systemGray, "grey": .systemGray,
    ]

    public var syntax: DirectiveSyntax {
        DirectiveSyntax(
            name: Self.identifier,
            form: .container,
            parameters: [
                // Open set, not closed: the schema can't know the embedder's
                // asset-catalog names, so resolution (and failure) belongs in
                // `style`, not in argument coercion.
                .init(label: nil, kind: .keyword([]), isRequired: true,
                      documentation: "Standard colour name, or a name from your asset catalog."),
            ]
        )
    }

    public var completion: DirectiveCompletion {
        DirectiveCompletion(
            id: id,
            title: "color",
            subtitle: "Tint a span",
            keywords: ["colour", "tint", "foreground"],
            snippet: "@color(|){}",
            symbolName: "paintpalette"
        )
    }

    public func style(arguments: DirectiveArguments, context: DirectiveContext) -> DirectiveStyle {
        guard let name = arguments.positional.first?.asString else { return .inherit }
        // An unresolvable name leaves the body alone rather than guessing —
        // the source stays readable and the mistake is visible.
        guard let color = Self.named[name.lowercased()] ?? NSColor(named: name) else { return .inherit }
        return DirectiveStyle(attributes: [.foregroundColor: color])
    }

    public func html(arguments: DirectiveArguments, bodyHTML: String) -> String {
        guard let name = arguments.positional.first?.asString else { return bodyHTML }
        return "<span style=\"color:\(name)\">\(bodyHTML)</span>"
    }
}
