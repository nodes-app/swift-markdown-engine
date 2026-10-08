//
//  DirectiveTestFixtures.swift
//  MarkdownEngineTests
//
//  Directives used across the directive suites.
//
//  Deliberately test-local: the engine ships only `FontDirective` and
//  `ColorDirective` as reference implementations — anything carrying curated
//  data or app policy (icons, flags, print semantics) belongs to the embedder.
//  So the shapes those would have exercised are declared here instead, which
//  also keeps the suites hermetic: they test the SEAM, not the bundled
//  directives. A schema is a schema whether it came from the engine or from an
//  embedder.
//

import AppKit
import Foundation
@testable import MarkdownEngine

// MARK: - Parsing and argument shapes

/// Container form with a mixed labelled schema — the shape the parser has to
/// carry through argument coercion.
struct SizedDirective: MarkdownDirective {
    var syntax: DirectiveSyntax {
        DirectiveSyntax(
            name: "font",
            form: .container,
            parameters: [
                .init(label: "size", kind: .length,
                      documentation: "Point size, or 1.5em / 120% relative to the surrounding text."),
                .init(label: "family", kind: .string, documentation: "Font family name."),
                .init(label: "weight", kind: .keyword(["regular", "bold"]),
                      defaultValue: .keyword("regular"), documentation: "Font weight."),
            ]
        )
    }
}

/// Container form with a required POSITIONAL argument.
struct TintDirective: MarkdownDirective {
    var syntax: DirectiveSyntax {
        DirectiveSyntax(
            name: "color",
            form: .container,
            parameters: [.init(label: nil, kind: .keyword([]), isRequired: true,
                               documentation: "Colour name.")]
        )
    }
}

/// Self-contained with two POSITIONAL parameters — the shape that exercises
/// defaults on positionals, which labelled-only filling used to skip.
struct SelfContainedPair: MarkdownDirective {
    var syntax: DirectiveSyntax { DirectiveSyntax(name: "pair", form: .selfContained) }
}

// MARK: - Presentation and completion shapes

/// Self-contained, no arguments, draws a fixed symbol. The minimal glyph case.
struct MarkerDirective: MarkdownDirective {
    var syntax: DirectiveSyntax { DirectiveSyntax(name: "marker", form: .selfContained) }

    var completion: DirectiveCompletion {
        DirectiveCompletion(id: id, title: "marker", subtitle: "A fixed glyph",
                            keywords: ["rule", "divider"], snippet: "@marker",
                            symbolName: "arrow.down.to.line")
    }

    func presentation(arguments: DirectiveArguments, context: DirectiveContext) -> DirectivePresentation {
        context.isActive ? .literal : .symbol(name: "arrow.down.to.line", tint: context.theme.mutedText)
    }

    func html(arguments: DirectiveArguments, bodyHTML: String) -> String { "<hr class=\"marker\" />" }
}

/// Self-contained, symbol chosen by a positional argument, with a static
/// value-completion list. Stands in for an icon-style directive.
struct GlyphDirective: MarkdownDirective {
    static let symbols = ["star.fill", "star", "bolt.fill", "checkmark.circle.fill", "flame.fill"]

    var syntax: DirectiveSyntax {
        DirectiveSyntax(
            name: "glyph",
            form: .selfContained,
            parameters: [
                .init(label: nil, kind: .keyword([]), isRequired: true, documentation: "SF Symbol name."),
                .init(label: "color", kind: .keyword(["red", "green", "blue"]), documentation: "Tint."),
            ]
        )
    }

    var completion: DirectiveCompletion {
        DirectiveCompletion(id: id, title: "glyph", subtitle: "Draw a symbol",
                            keywords: ["symbol", "icon"], snippet: "@glyph(|)", symbolName: "star")
    }

    func presentation(arguments: DirectiveArguments, context: DirectiveContext) -> DirectivePresentation {
        guard !context.isActive, let name = arguments.positional.first?.asString else { return .literal }
        let tint: NSColor? = switch arguments.string("color") {
        case "red": .systemRed
        case "green": .systemGreen
        case "blue": .systemBlue
        default: nil
        }
        return .symbol(name: name, tint: tint)
    }

    func valueCompletions(for parameter: DirectiveParameter, prefix: String) -> [DirectiveCompletionItem] {
        // Only the positional slot is dynamic; `color:` falls through to the
        // schema-derived default.
        guard parameter.label == nil else {
            return defaultValueCompletions(for: parameter, prefix: prefix)
        }
        return Self.symbols
            .filter { prefix.isEmpty || $0.hasPrefix(prefix.lowercased()) }
            .map { DirectiveCompletionItem(title: $0, subtitle: "Symbol", insertion: $0, symbolName: $0) }
    }
}

/// Self-contained, renders replacement TEXT chosen by argument, with dynamic
/// value completions that match on two fields. Stands in for a flag/emoji
/// style directive — the case whose domain is too large to declare.
struct RegionDirective: MarkdownDirective {
    static let table: [(code: String, name: String, glyph: String)] = [
        ("JP", "Japan", "🇯🇵"), ("US", "United States", "🇺🇸"),
        ("DE", "Germany", "🇩🇪"), ("BR", "Brazil", "🇧🇷"),
    ]

    var syntax: DirectiveSyntax {
        DirectiveSyntax(
            name: "region",
            form: .selfContained,
            parameters: [.init(label: nil, kind: .keyword([]), isRequired: true,
                               documentation: "Region code.")]
        )
    }

    var completion: DirectiveCompletion {
        DirectiveCompletion(id: id, title: "region", subtitle: "Region flag",
                            keywords: ["country", "flag"], snippet: "@region(|)", symbolName: "flag")
    }

    func presentation(arguments: DirectiveArguments, context: DirectiveContext) -> DirectivePresentation {
        guard !context.isActive,
              let code = arguments.positional.first?.asString,
              let entry = Self.table.first(where: { $0.code.caseInsensitiveCompare(code) == .orderedSame })
        else { return .literal }
        return .text(entry.glyph)
    }

    func valueCompletions(for parameter: DirectiveParameter, prefix: String) -> [DirectiveCompletionItem] {
        let needle = prefix.lowercased()
        return Self.table
            .filter { needle.isEmpty
                || $0.code.lowercased().hasPrefix(needle)
                || $0.name.lowercased().hasPrefix(needle) }
            .map { DirectiveCompletionItem(title: $0.code, subtitle: $0.name,
                                           detail: $0.glyph, insertion: $0.code) }
    }
}

extension MarkdownDirective {
    /// Reach the protocol's default `valueCompletions` from an override.
    func defaultValueCompletions(for parameter: DirectiveParameter, prefix: String) -> [DirectiveCompletionItem] {
        let values: [String]
        switch parameter.kind {
        case .keyword(let allowed) where !allowed.isEmpty: values = allowed
        case .boolean:                                     values = ["true", "false"]
        default:                                           return []
        }
        let needle = prefix.lowercased()
        return values
            .filter { needle.isEmpty || $0.lowercased().hasPrefix(needle) }
            .map { DirectiveCompletionItem(title: $0, subtitle: parameter.documentation, insertion: $0) }
    }
}
