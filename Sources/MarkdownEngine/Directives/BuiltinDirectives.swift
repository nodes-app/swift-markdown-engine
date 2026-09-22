//
//  BuiltinDirectives.swift
//  MarkdownEngine
//
//  Three directives that between them exercise every part of the seam, and
//  double as the "is a new command easy to write?" test. Not registered by
//  default — the core engine parses pure markdown; embedders opt in the way
//  they do for extensions:
//
//      configuration.directives = [FontDirective(), ColorDirective()]
//
//  `style` and `presentation` are declared here but not yet consulted by the
//  styler (Phase 2 / Phase 3). In Phase 1 a container directive's syntax
//  shrinks and its body renders as ordinary markdown; a self-contained call
//  renders as literal text.
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
