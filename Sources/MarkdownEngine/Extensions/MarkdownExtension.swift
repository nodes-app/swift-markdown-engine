//
//  MarkdownExtension.swift
//  MarkdownEngine
//
//  Created by Luca Chen on 15.07.26.
//
//  The extension seam: a construct delimited by an open/close marker pair
//  on a single line (`==text==`, `%%text%%`, …) can be supplied by an
//  extension instead of being hard-coded into the parser. The core stays pure
//  markdown; extensions are opt-in per editor instance via
//  `MarkdownEditorConfiguration.extensions`.
//
//  Isolation contract: an extension supplies SYNTAX (the delimiters) and
//  ATTRIBUTES (how the content looks). It never emits ranges — the parser
//  derives content/marker ranges itself, so a buggy extension can restyle its
//  own span at worst, never a neighbor. Marker mute/shrink, caret reveal,
//  incremental restyle, and copy behavior are handled generically by the
//  engine, identical for every extension.
//

import AppKit
import Foundation

// MARK: - Syntax rule

/// The syntax of a delimited span, mirroring the semantics of the engine's
/// built-in span scanners:
///
/// * The span opens where `open` matches and closes at the FIRST exact `close`
///   match on the same line.
/// * A lone occurrence of `close`'s first character inside the content aborts
///   the match (the candidate stays literal) — `==a=b==` is not a span.
/// * A newline before the close aborts the match (spans are single-line).
public struct SpanSyntax: Sendable, Equatable {
    /// Opening delimiter, e.g. `"=="`.
    public var open: String
    /// Closing delimiter, e.g. `"=="`.
    public var close: String
    /// Whether the content is re-parsed as markdown (container, like
    /// `==bold **inside**==`) or kept opaque (leaf, like a comment).
    ///
    /// Note: an opaque span's content is still VISIBLE text carrying the
    /// extension's `contentAttributes` — the engine does not yet offer a
    /// caret-aware hide/reveal affordance for content (markers shrink
    /// generically, content does not). A comment-style extension that wants
    /// to fully hide its content needs that future affordance.
    public var parsesContent: Bool
    /// Reject an empty span (`====`). Default `true`.
    public var requiresNonEmptyContent: Bool
    /// Reject when the character before `open` equals `open`'s first character
    /// (the span must not extend a longer delimiter run). Default `true`,
    /// matching `~~`/`==` built-in behavior.
    public var rejectsOpenerRun: Bool
    /// Reject when the character after `close` equals `close`'s last character.
    /// `~~` uses this (strict GFM-ish run handling); `==` does not. Default `false`.
    public var rejectsCloserRun: Bool

    public init(
        open: String,
        close: String,
        parsesContent: Bool = true,
        requiresNonEmptyContent: Bool = true,
        rejectsOpenerRun: Bool = true,
        rejectsCloserRun: Bool = false
    ) {
        self.open = open
        self.close = close
        self.parsesContent = parsesContent
        self.requiresNonEmptyContent = requiresNonEmptyContent
        self.rejectsOpenerRun = rejectsOpenerRun
        self.rejectsCloserRun = rejectsCloserRun
    }
}

// MARK: - Extension protocol

/// An opt-in construct beyond pure markdown — a delimited span like
/// `==text==` or `~~text~~`. Register instances via
/// `MarkdownEditorConfiguration.extensions`; an unregistered construct's
/// syntax stays literal text.
///
/// An extension supplies only SYNTAX (the delimiters via ``SpanSyntax``)
/// and ATTRIBUTES (how its content looks). It never emits ranges — the parser
/// derives all span geometry — so a misbehaving extension can at worst
/// restyle its own span, never a neighbor. Marker mute/shrink, caret reveal,
/// incremental restyle, table cells, and rich copy are handled generically by
/// the engine, identical for every extension.
public protocol MarkdownExtension: Sendable {
    /// Stable identifier, unique per extension (e.g. `"highlight"`). Used for
    /// dispatch and cache keying — never shown to users.
    var id: String { get }
    /// The delimiter syntax this extension contributes to the parser.
    var syntax: SpanSyntax { get }
    /// Attributes applied to the span's CONTENT range (between the markers).
    /// Called during styling; must be cheap and synchronous.
    func contentAttributes(theme: MarkdownEditorTheme) -> [NSAttributedString.Key: Any]
    /// Wrap the rendered inner HTML for the clean-copy path
    /// (`childrenHTML` is already escaped / recursively rendered).
    func html(childrenHTML: String) -> String
}

// MARK: - Parser-facing registry (internal)

/// Precompiled, purely syntactic view of the registered extensions — the only
/// thing the parser sees. Built once per parse entry from the configuration.
struct ExtensionRegistry {
    struct Entry {
        let id: String
        let open: [unichar]
        let close: [unichar]
        let syntax: SpanSyntax
    }

    let entries: [Entry]
    /// Stable fingerprint for cache keying ("" when empty). Two registries with
    /// the same fingerprint produce identical parses for identical text.
    let fingerprint: String

    static let empty = ExtensionRegistry(entries: [], fingerprint: "")

    private init(entries: [Entry], fingerprint: String) {
        self.entries = entries
        self.fingerprint = fingerprint
    }

    init(extensions: [any MarkdownExtension]) {
        guard !extensions.isEmpty else {
            self = .empty
            return
        }
        self.entries = extensions.map { ext in
            Entry(
                id: ext.id,
                open: Array(ext.syntax.open.utf16),
                close: Array(ext.syntax.close.utf16),
                syntax: ext.syntax
            )
        }
        // Every syntax field participates: registries that differ in ANY flag
        // must never share cached parse results. Free-text fields (id, open,
        // close) are length-prefixed so the concatenation is injective — an id
        // containing the separator characters cannot alias another registry.
        func framed(_ str: String) -> String { "\(str.utf16.count).\(str)" }
        self.fingerprint = extensions
            .map {
                let s = $0.syntax
                return [framed($0.id), framed(s.open), framed(s.close),
                        "\(s.parsesContent)", "\(s.requiresNonEmptyContent)",
                        "\(s.rejectsOpenerRun)", "\(s.rejectsCloserRun)"].joined(separator: ",")
            }
            .joined(separator: "|")
    }

    var isEmpty: Bool { entries.isEmpty }
}

extension MarkdownEditorConfiguration {
    /// The parser-facing registry derived from `extensions`.
    var extensionRegistry: ExtensionRegistry {
        ExtensionRegistry(extensions: extensions)
    }

    /// Styler-facing lookup: extension behavior by id.
    var extensionsByID: [String: any MarkdownExtension] {
        var out: [String: any MarkdownExtension] = [:]
        for ext in extensions { out[ext.id] = ext }
        return out
    }
}
