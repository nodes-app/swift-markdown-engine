//
//  MarkdownExtension.swift
//  MarkdownEngine
//
//  Created by Luca Chen on 15.07.26.
//
//  The extension seam: a construct beyond pure markdown — an inline span
//  (`==text==`, `%%text%%`, …) and/or a fenced block (`::: … :::`) — can be
//  supplied by an extension instead of being hard-coded into the parser. The core stays pure
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
public struct InlineSyntax: Sendable, Equatable {
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

// MARK: - Block syntax rule

/// The syntax of a fenced block, mirroring the engine's built-in fence
/// semantics (``` code fences):
///
/// * A line starting with `fence` at column 0 OPENS the block; the rest of
///   that line is the info string (e.g. `::: warning`).
/// * The next line starting with `fence` at column 0 CLOSES it.
/// * An unclosed block runs to the end of the document.
///
/// Built-in constructs always classify first — a fence that collides with a
/// built-in line form (```, `$$`, `#`, `>`, list markers, `|…|`) never fires.
public struct BlockSyntax: Sendable, Equatable {
    /// Fence prefix that opens and closes the block, e.g. `":::"`.
    public var fence: String

    public init(fence: String) {
        self.fence = fence
    }
}

// MARK: - Extension protocol

/// An opt-in construct beyond pure markdown. Register instances via
/// `MarkdownEditorConfiguration.extensions`; an unregistered construct's
/// syntax stays literal text.
///
/// An extension contributes one or both syntax forms:
/// * ``inline`` — a delimited span on a single line (`==text==`).
/// * ``block`` — a fenced multi-line block (`:::` … `:::`).
///
/// It supplies only SYNTAX (delimiters) and ATTRIBUTES (how its content
/// looks). It never emits ranges — the parser derives all geometry — so a
/// misbehaving extension can at worst restyle its own construct, never a
/// neighbor. Marker mute/hide, caret reveal, incremental restyle, table
/// cells, and rich copy are handled generically by the engine, identical
/// for every extension.
public protocol MarkdownExtension: Sendable {
    /// Stable identifier, unique per extension (e.g. `"highlight"`). Used for
    /// dispatch and cache keying — never shown to users.
    var id: String { get }
    /// Inline span form; `nil` when the extension has none (default).
    var inline: InlineSyntax? { get }
    /// Fenced block form; `nil` when the extension has none (default).
    var block: BlockSyntax? { get }
    /// Attributes applied to the construct's CONTENT range (between the
    /// markers/fences). Called during styling; must be cheap and synchronous.
    func contentAttributes(theme: MarkdownEditorTheme) -> [NSAttributedString.Key: Any]
    /// Wrap the rendered inner HTML for the clean-copy path
    /// (`childrenHTML` is already escaped / recursively rendered).
    func html(childrenHTML: String) -> String
}

public extension MarkdownExtension {
    // NOTE: because these have nil defaults, a conformance that misspells the
    // property name (`var inlin: …`) compiles fine and silently yields an
    // inert extension. If your construct never fires, check these two names
    // first.
    var inline: InlineSyntax? { nil }
    var block: BlockSyntax? { nil }
}

// MARK: - Parser-facing registry (internal)

/// Precompiled, purely syntactic view of the registered extensions — the only
/// thing the parser sees. Built once per parse entry from the configuration.
struct ExtensionRegistry {
    struct Entry {
        let id: String
        let open: [unichar]
        let close: [unichar]
        let syntax: InlineSyntax
    }

    struct BlockEntry {
        let id: String
        let fence: String
        let fenceChars: [unichar]
    }

    /// Inline span rules, in registration order.
    let entries: [Entry]
    /// Fenced block rules, in registration order.
    let blockEntries: [BlockEntry]
    /// Stable fingerprint for cache keying ("" when empty). Two registries with
    /// the same fingerprint produce identical parses for identical text.
    let fingerprint: String

    static let empty = ExtensionRegistry(entries: [], blockEntries: [], fingerprint: "")

    private init(entries: [Entry], blockEntries: [BlockEntry], fingerprint: String) {
        self.entries = entries
        self.blockEntries = blockEntries
        self.fingerprint = fingerprint
    }

    init(extensions: [any MarkdownExtension]) {
        guard !extensions.isEmpty else {
            self = .empty
            return
        }
        self.entries = extensions.compactMap { ext in
            guard let syntax = ext.inline else { return nil }
            return Entry(
                id: ext.id,
                open: Array(syntax.open.utf16),
                close: Array(syntax.close.utf16),
                syntax: syntax
            )
        }
        self.blockEntries = extensions.compactMap { ext in
            guard let block = ext.block, !block.fence.isEmpty else { return nil }
            return BlockEntry(id: ext.id, fence: block.fence, fenceChars: Array(block.fence.utf16))
        }
        // Every syntax field participates: registries that differ in ANY flag
        // must never share cached parse results. Free-text fields (id, open,
        // close, fence) are length-prefixed so the concatenation is injective —
        // an id containing the separator characters cannot alias another
        // registry.
        func framed(_ str: String) -> String { "\(str.utf16.count).\(str)" }
        self.fingerprint = extensions
            .map { ext in
                var parts = [framed(ext.id)]
                if let s = ext.inline {
                    parts += ["i", framed(s.open), framed(s.close),
                              "\(s.parsesContent)", "\(s.requiresNonEmptyContent)",
                              "\(s.rejectsOpenerRun)", "\(s.rejectsCloserRun)"]
                }
                if let b = ext.block {
                    parts += ["b", framed(b.fence)]
                }
                return parts.joined(separator: ",")
            }
            .joined(separator: "|")
    }

    var isEmpty: Bool { entries.isEmpty && blockEntries.isEmpty }

    /// The first registered block rule whose fence opens `line` (column 0),
    /// or nil. Registration order is precedence, matching the inline rules.
    func blockEntry(opening line: String) -> BlockEntry? {
        blockEntries.first { line.hasPrefix($0.fence) }
    }

    /// The block rule with the given extension id, or nil.
    func blockEntry(for id: String) -> BlockEntry? {
        blockEntries.first { $0.id == id }
    }
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
