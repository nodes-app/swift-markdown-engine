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

    /// A curated shortlist — the system ships thousands of symbols and exposes
    /// no enumeration API. A real app would back this with its own catalogue;
    /// the engine offers whatever `valueCompletions` returns.
    private static let suggested = [
        "star.fill", "star", "heart.fill", "bolt.fill", "flame.fill",
        "checkmark.circle.fill", "xmark.circle.fill", "exclamationmark.triangle.fill",
        "info.circle.fill", "questionmark.circle.fill", "bell.fill", "bookmark.fill",
        "tag.fill", "pin.fill", "paperclip", "link", "calendar", "clock.fill",
        "person.fill", "envelope.fill", "phone.fill", "house.fill", "gearshape.fill",
        "magnifyingglass", "trash.fill", "folder.fill", "doc.fill", "book.fill",
        "lightbulb.fill", "hammer.fill", "wrench.fill", "leaf.fill", "globe",
        "arrow.right", "arrow.up.right", "arrow.down.to.line", "chevron.right",
        "hand.thumbsup.fill", "hand.raised.fill", "eye.fill", "lock.fill",
    ]

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

    var completion: DirectiveCompletion {
        DirectiveCompletion(id: id, title: "icon", subtitle: "Draw an SF Symbol inline",
                            keywords: ["symbol", "glyph", "image"],
                            snippet: "@icon(|)", symbolName: "star")
    }

    func presentation(arguments: DirectiveArguments, context: DirectiveContext) -> DirectivePresentation {
        guard !context.isActive, let name = arguments.positional.first?.asString else { return .literal }
        return .symbol(name: name, tint: arguments.string("color").flatMap { Self.palette[$0.lowercased()] })
    }

    func valueCompletions(for parameter: DirectiveParameter, prefix: String) -> [DirectiveCompletionItem] {
        let needle = prefix.lowercased()
        guard parameter.label == nil else {
            return Self.palette.keys.sorted()
                .filter { needle.isEmpty || $0.hasPrefix(needle) }
                .map { DirectiveCompletionItem(title: $0, subtitle: "Colour", insertion: $0) }
        }
        return Self.suggested
            .filter { needle.isEmpty || $0.hasPrefix(needle) }
            .map { DirectiveCompletionItem(title: $0, subtitle: "SF Symbol", insertion: $0, symbolName: $0) }
    }

    func html(arguments: DirectiveArguments, bodyHTML: String) -> String {
        "<span class=\"icon\" data-symbol=\"\(arguments.positional.first?.asString ?? "")\"></span>"
    }
}

// MARK: - @flag(JP)

/// A country flag from an ISO region code — the reference case for
/// argument-value completion against a domain too large to declare.
///
/// Dataset-free: codes come from `Locale.Region.isoRegions`, names from the
/// user's locale, and the flag is computed from the code's regional-indicator
/// scalars. Nothing to ship, nothing to keep current.
struct FlagDirective: MarkdownDirective {

    var syntax: DirectiveSyntax {
        DirectiveSyntax(
            name: "flag",
            form: .selfContained,
            parameters: [.init(label: nil, kind: .keyword([]), isRequired: true,
                               documentation: "ISO 3166 country code, e.g. JP.")]
        )
    }

    var completion: DirectiveCompletion {
        DirectiveCompletion(id: id, title: "flag", subtitle: "Country flag from an ISO code",
                            keywords: ["country", "nation"],
                            snippet: "@flag(|)", symbolName: "flag")
    }

    func presentation(arguments: DirectiveArguments, context: DirectiveContext) -> DirectivePresentation {
        guard !context.isActive,
              let code = arguments.positional.first?.asString,
              let flag = Self.flag(for: code) else { return .literal }
        return .text(flag)
    }

    func valueCompletions(for parameter: DirectiveParameter, prefix: String) -> [DirectiveCompletionItem] {
        let needle = prefix.lowercased()
        return Self.regions
            .filter { needle.isEmpty
                || $0.code.lowercased().hasPrefix(needle)
                || $0.name.lowercased().hasPrefix(needle) }
            // Code matches first — typing `us` wants US, not Uruguay.
            .sorted { a, b in
                let aCode = a.code.lowercased().hasPrefix(needle)
                let bCode = b.code.lowercased().hasPrefix(needle)
                return aCode == bCode ? a.name < b.name : aCode
            }
            .prefix(50)
            .map { DirectiveCompletionItem(title: $0.code, subtitle: $0.name,
                                           detail: $0.flag, insertion: $0.code) }
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

    var completion: DirectiveCompletion {
        DirectiveCompletion(id: id, title: "pagebreak", subtitle: "Force a page break when printing",
                            keywords: ["page", "break", "print"],
                            snippet: "@pagebreak", symbolName: "arrow.down.to.line")
    }

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

    var completion: DirectiveCompletion {
        DirectiveCompletion(
            id: id, title: "emoji", subtitle: "Insert an emoji by name",
            keywords: ["smiley", "reaction"], snippet: "@emoji(|)", symbolName: "face.smiling"
        )
    }

    func presentation(arguments: DirectiveArguments, context: DirectiveContext) -> DirectivePresentation {
        guard !context.isActive,
              let name = arguments.positional.first?.asString,
              let glyph = Self.table.first(where: { $0.name == name })?.glyph
        else { return .literal }
        return .text(glyph)
    }

    func valueCompletions(for parameter: DirectiveParameter, prefix: String) -> [DirectiveCompletionItem] {
        let needle = prefix.lowercased()
        return Self.table
            .filter { needle.isEmpty || $0.name.hasPrefix(needle) }
            .map { DirectiveCompletionItem(title: $0.name, detail: $0.glyph, insertion: $0.name) }
    }

    func html(arguments: DirectiveArguments, bodyHTML: String) -> String {
        guard let name = arguments.positional.first?.asString,
              let glyph = Self.table.first(where: { $0.name == name })?.glyph else { return "" }
        return glyph
    }
}
