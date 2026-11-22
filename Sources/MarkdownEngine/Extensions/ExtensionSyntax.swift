//
//  ExtensionSyntax.swift
//  MarkdownEngine
//
//  The extension seam's syntax: the delimiters an extension declares, which
//  the parser reads. Its styling half is in `MarkdownExtension.swift`.
//

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

// MARK: - Parser-facing registry (internal)

/// Precompiled, purely syntactic view of the registered extensions — the only
/// thing the parser sees. Built once per parse entry from the configuration's extensions' syntax.
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
    /// Directive rules (`@font(size: 18){…}`). Carried here so the directive
    /// fingerprint folds into the one grammar fingerprint every parse cache
    /// already keys on — registering a directive invalidates those caches with
    /// no second key to thread through the pipeline.
    let directives: DirectiveRegistry
    /// Stable fingerprint for cache keying ("" when empty). Two registries with
    /// the same fingerprint produce identical parses for identical text.
    let fingerprint: String

    static let empty = ExtensionRegistry(entries: [], blockEntries: [], directives: .empty, fingerprint: "")

    private init(entries: [Entry], blockEntries: [BlockEntry], directives: DirectiveRegistry, fingerprint: String) {
        self.entries = entries
        self.blockEntries = blockEntries
        self.directives = directives
        self.fingerprint = fingerprint
    }

    /// One registered extension's syntax: its id and either form.
    typealias Syntax = (id: String, inline: InlineSyntax?, block: BlockSyntax?)

    /// Built from the syntax each extension declares, so the parser needs no `MarkdownExtension`.
    init(syntax extensions: [Syntax], directives: DirectiveRegistry = .empty) {
        // Directives alone are a non-empty grammar: only bail out when BOTH
        // halves are empty, or a directive-only configuration would parse as
        // pure markdown.
        guard !extensions.isEmpty || !directives.isEmpty else {
            self = .empty
            return
        }
        self.directives = directives
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
        let extensionFingerprint = extensions
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
        // One grammar fingerprint covering both seams. The `~` separator keeps
        // the halves distinguishable; an empty half contributes nothing, so a
        // directive-free registry keeps the fingerprint it had before
        // directives existed.
        self.fingerprint = directives.isEmpty
            ? extensionFingerprint
            : extensionFingerprint + "~" + directives.fingerprint
    }

    var isEmpty: Bool { entries.isEmpty && blockEntries.isEmpty && directives.isEmpty }

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
