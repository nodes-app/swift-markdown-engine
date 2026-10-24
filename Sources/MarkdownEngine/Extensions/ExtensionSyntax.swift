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
