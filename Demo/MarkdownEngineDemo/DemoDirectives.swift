//
//  DemoDirectives.swift
//  MarkdownEngineDemo
//
//  Directives that belong to an APP, not to the engine.
//
//  `MarkdownEngine` ships only `FontDirective` and `ColorDirective` as
//  reference implementations, because both are pure presentation. Everything
//  here carries something the engine has no business deciding: curated data
//  (`@icon`, `@emoji`), or document policy (`@pagebreak` — what a page break
//  means is a print concern).
//
//  They're also the honest measure of the seam: each is 30–60 lines, including
//  its argument schema, its glyph, its argument-value completions, and its
//  HTML for rich copy.
//

import AppKit
import MarkdownEngine

// MARK: - @icon(star.fill, color: yellow)

/// An SF Symbol drawn inline, sized to the surrounding text.
struct IconDirective: MarkdownDirective {

    private static let palette: [String: NSColor] = [
        "red": .systemRed, "orange": .systemOrange, "yellow": .systemYellow,
        "green": .systemGreen, "mint": .systemMint, "teal": .systemTeal,
        "cyan": .systemCyan, "blue": .systemBlue, "indigo": .systemIndigo,
        "purple": .systemPurple, "pink": .systemPink, "brown": .systemBrown,
        "gray": .systemGray,
    ]

    var syntax: DirectiveSyntax {
        DirectiveSyntax(
            name: "icon",
            form: .selfContained,
            parameters: [
                .init(label: nil, kind: .keyword([]), isRequired: true,
                      documentation: "SF Symbol name, e.g. star.fill."),
                .init(label: "color", kind: .keyword([]), documentation: "Tint colour."),
            ]
        )
    }

    func presentation(arguments: DirectiveArguments, context: DirectiveContext) -> DirectivePresentation {
        guard !context.isActive, let name = arguments.positional.first?.asString else { return .literal }
        return .symbol(name: name, tint: arguments.string("color").flatMap { Self.palette[$0.lowercased()] })
    }

    func html(arguments: DirectiveArguments, bodyHTML: String) -> String {
        "<span class=\"icon\" data-symbol=\"\(arguments.positional.first?.asString ?? "")\"></span>"
    }
}

// MARK: - @flag(JP)

/// A country flag from an ISO region code — a directive whose glyph is
/// COMPUTED rather than drawn from an asset.
///
/// Dataset-free: codes come from `Locale.Region.isoRegions` and the flag is
/// built from the code's regional-indicator scalars. Nothing to ship, nothing
/// to keep current.
struct FlagDirective: MarkdownDirective {

    var syntax: DirectiveSyntax {
        DirectiveSyntax(
            name: "flag",
            form: .selfContained,
            parameters: [.init(label: nil, kind: .keyword([]), isRequired: true,
                               documentation: "ISO 3166 country code, e.g. JP.")]
        )
    }

    func presentation(arguments: DirectiveArguments, context: DirectiveContext) -> DirectivePresentation {
        guard !context.isActive,
              let code = arguments.positional.first?.asString,
              let flag = Self.flag(for: code) else { return .literal }
        return .text(flag)
    }

    func html(arguments: DirectiveArguments, bodyHTML: String) -> String {
        arguments.positional.first?.asString.flatMap(Self.flag(for:)) ?? ""
    }

    struct Region { let code: String; let name: String; let flag: String }

    static let regions: [Region] = Locale.Region.isoRegions.compactMap { region in
        let code = region.identifier
        guard code.count == 2, let flag = flag(for: code) else { return nil }
        return Region(code: code, name: Locale.current.localizedString(forRegionCode: code) ?? code, flag: flag)
    }

    /// Regional-indicator scalars: `JP` → 🇯🇵.
    static func flag(for code: String) -> String? {
        let upper = code.uppercased()
        guard upper.count == 2 else { return nil }
        var scalars = String.UnicodeScalarView()
        for scalar in upper.unicodeScalars {
            guard scalar.value >= 0x41, scalar.value <= 0x5A,
                  let indicator = UnicodeScalar(0x1F1E6 + scalar.value - 0x41) else { return nil }
            scalars.append(indicator)
        }
        return String(scalars)
    }
}

// MARK: - @pagebreak

/// What a page break *means* is a print concern, so it belongs to the app.
struct PageBreakDirective: MarkdownDirective {

    var syntax: DirectiveSyntax { DirectiveSyntax(name: "pagebreak", form: .selfContained) }

    func presentation(arguments: DirectiveArguments, context: DirectiveContext) -> DirectivePresentation {
        context.isActive ? .literal : .symbol(name: "arrow.down.to.line", tint: context.theme.mutedText)
    }

    func html(arguments: DirectiveArguments, bodyHTML: String) -> String { "<hr class=\"pagebreak\" />" }
}

// MARK: - @emoji(tada)

/// `@emoji(tada)` — the shortest directive here, and the one whose domain
/// is most obviously the app's rather than the engine's.
struct EmojiDirective: MarkdownDirective {

    private static let table: [(name: String, glyph: String)] = [
        ("tada", "🎉"), ("rocket", "🚀"), ("sparkles", "✨"), ("fire", "🔥"),
        ("bug", "🐛"), ("wrench", "🔧"), ("book", "📚"), ("bulb", "💡"),
        ("warning", "⚠️"), ("check", "✅"), ("cross", "❌"), ("eyes", "👀"),
        ("thinking", "🤔"), ("clap", "👏"), ("heart", "❤️"), ("star", "⭐️"),
        ("coffee", "☕️"), ("ship", "🚢"), ("lock", "🔒"), ("chart", "📈"),
    ]

    var syntax: DirectiveSyntax {
        DirectiveSyntax(
            name: "emoji",
            form: .selfContained,
            parameters: [
                .init(label: nil, kind: .keyword([]), isRequired: true,
                      documentation: "Emoji name, e.g. tada."),
            ]
        )
    }

    func presentation(arguments: DirectiveArguments, context: DirectiveContext) -> DirectivePresentation {
        guard !context.isActive,
              let name = arguments.positional.first?.asString,
              let glyph = Self.table.first(where: { $0.name == name })?.glyph
        else { return .literal }
        return .text(glyph)
    }

    func html(arguments: DirectiveArguments, bodyHTML: String) -> String {
        guard let name = arguments.positional.first?.asString,
              let glyph = Self.table.first(where: { $0.name == name })?.glyph else { return "" }
        return glyph
    }
}
