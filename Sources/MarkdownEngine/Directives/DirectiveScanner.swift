//
//  DirectiveScanner.swift
//  MarkdownEngine
//
//  The parser side of the directive seam. Called from
//  `InlineParser.matchClaimedSpan` AFTER every built-in, so a directive can
//  never take text away from core markdown — the same precedence rule
//  extension spans follow.
//
//  Self-contained by design: the scanner re-implements the two helpers it
//  needs (`isEscaped`, balanced-delimiter scanning) rather than reaching into
//  `InlineParser`'s private ones, so the whole seam is one directory of new
//  files plus a four-line hook.
//
//  Rejection is always silent and always means "stays literal text": an
//  unregistered name, a malformed call, a wrong-form call, a run crossing a
//  line break. Nothing here can produce a partial construct.
//
//  Because the scanner runs inside `scanLinkFamily` (pass 3), a directive
//  inside a code span is already claimed and never fires.
//
//  KNOWN LIMITATION — a directive whose BODY holds a pre-claimed span is
//  rejected whole, so `@font(size: 18){a `b` c}` produces no directive node
//  at all rather than a directive containing a code span. The same applies to
//  a backslash escape (`{a \* c}`), since escapes are claimed in pass 2.
//
//  It is exactly the pre-claimed passes that bite — code spans and escapes.
//  Constructs claimed in this pass or later are fine: `$…$`, links, emphasis
//  and nesting all work inside a body. The cause is `scanLinkFamily`'s
//  overlap rule, which rejects any candidate meeting a claimed span; #118
//  granted link labels an exemption from the same rule, and directives want
//  the equivalent. Tracked separately — it belongs with that rule, not here.
//

import Foundation

/// A matched directive, in absolute UTF-16 coordinates. Neutral value type:
/// `InlineParser` converts it into its own private `Span` at the call site.
struct DirectiveMatch: Equatable {
    /// AST node id — already namespaced via `DirectiveRegistry.nodeID(for:)`.
    let nodeID: String
    let range: NSRange
    /// The name run, without the marker (`font` in `@font(…)`).
    let nameRange: NSRange
    /// Inside the parens; `nil` when the call has no argument list.
    let argumentsRange: NSRange?
    /// Inside the braces; `nil` for a self-contained call.
    let bodyRange: NSRange?
    /// Ranges that shrink when the caret leaves: `[prefix, closingBrace]` for
    /// a container, empty for a self-contained call (Phase 1 renders those
    /// literally — the glyph pass that collapses them lands in Phase 3).
    let markers: [NSRange]
    /// Range carrying the node's content: the body for a container, the whole
    /// call for a self-contained one.
    let contentRange: NSRange
    /// Whether the content is re-parsed as markdown.
    let parsesContent: Bool
}

enum DirectiveScanner {

    private static let lparen: unichar = 0x28
    private static let rparen: unichar = 0x29
    private static let lbrace: unichar = 0x7B
    private static let rbrace: unichar = 0x7D
    private static let backslash: unichar = 0x5C
    private static let quote: unichar = 0x22
    private static let dot: unichar = 0x2E
    private static let newline: unichar = 0x0A
    private static let carriageReturn: unichar = 0x0D

    /// Try to match a directive starting at `i`. Returns nil for every
    /// rejection — the candidate then stays literal text.
    static func match(_ ns: NSString, len: Int, at i: Int, registry: DirectiveRegistry) -> DirectiveMatch? {
        guard !registry.isEmpty, i >= 0, i < len else { return nil }
        let marker = ns.character(at: i)
        guard let table = registry.byMarker[marker], !table.isEmpty else { return nil }

        // Left boundary: anything that isn't a word character. Markup
        // delimiters therefore open directives (`*@font(size: 18){x}*`), while
        // `name@example.com` never does, and a `@@` run stays literal
        // (mirrors `InlineSyntax.rejectsOpenerRun`).
        if i > 0 {
            let previous = ns.character(at: i - 1)
            guard previous != marker, isBoundary(previous) else { return nil }
        }
        guard !isEscaped(i, ns) else { return nil }

        // Name: ident ('.' ident)*
        var cursor = i + 1
        let nameStart = cursor
        guard cursor < len, isIdentStart(ns.character(at: cursor)) else { return nil }
        while cursor < len {
            let c = ns.character(at: cursor)
            if isIdentChar(c) {
                cursor += 1
            } else if c == dot, cursor + 1 < len, isIdentStart(ns.character(at: cursor + 1)) {
                cursor += 1
            } else {
                break
            }
        }
        let nameRange = NSRange(location: nameStart, length: cursor - nameStart)

        // REGISTERED NAMES ONLY — the property that makes this safe to enable
        // over an existing document corpus.
        guard let entry = table[ns.substring(with: nameRange)] else { return nil }

        // Optional argument list `( … )`: balanced, single line.
        var argumentsRange: NSRange?
        if cursor < len, ns.character(at: cursor) == lparen {
            guard let close = balanced(ns, len: len, from: cursor + 1, open: lparen, close: rparen) else { return nil }
            argumentsRange = NSRange(location: cursor + 1, length: close - (cursor + 1))
            cursor = close + 1
        }

        // Optional body `{ … }`: balanced, single line, escape-aware.
        var bodyRange: NSRange?
        if cursor < len, ns.character(at: cursor) == lbrace {
            guard let close = balanced(ns, len: len, from: cursor + 1, open: lbrace, close: rbrace) else { return nil }
            bodyRange = NSRange(location: cursor + 1, length: close - (cursor + 1))
            cursor = close + 1
        }

        // Form check — a mismatched call stays literal rather than rendering
        // half-configured.
        switch entry.form {
        case .selfContained: guard bodyRange == nil else { return nil }
        case .container:     guard bodyRange != nil else { return nil }
        case .either:        break
        }

        let range = NSRange(location: i, length: cursor - i)

        if let body = bodyRange {
            // Markers are what shrinks when the caret leaves: the whole
            // `@font(size: 18){` prefix and the closing `}`, leaving only the
            // styled body visible.
            let prefix = NSRange(location: i, length: body.location - i)
            let closingBrace = NSRange(location: NSMaxRange(body), length: 1)
            return DirectiveMatch(
                nodeID: DirectiveRegistry.nodeID(for: entry.id),
                range: range,
                nameRange: nameRange,
                argumentsRange: argumentsRange,
                bodyRange: body,
                markers: [prefix, closingBrace],
                contentRange: body,
                parsesContent: entry.parsesBody
            )
        }

        // Self-contained: no markers in Phase 1, so the call renders as plain
        // literal text instead of collapsing to nothing. It is still CLAIMED,
        // so emphasis and autolinking can't fire inside it, and it still
        // projects a token — the glyph pass in Phase 3 only has to add
        // presentation.
        return DirectiveMatch(
            nodeID: DirectiveRegistry.nodeID(for: entry.id),
            range: range,
            nameRange: nameRange,
            argumentsRange: argumentsRange,
            bodyRange: nil,
            markers: [],
            contentRange: range,
            parsesContent: false
        )
    }

    /// Recover the argument range from a directive node's PREFIX marker
    /// (`@font(size: 18){`, or the whole call when self-contained).
    ///
    /// The AST carries directives as extension-shaped nodes, which have no
    /// slot for an argument range, so styling recovers it from the geometry
    /// the parser already emitted. The prefix is well-formed by construction —
    /// this scanner produced it — so the walk is a short, total re-derivation
    /// rather than a second parse of the document.
    static func argumentsRange(inPrefix prefix: NSRange, of ns: NSString) -> NSRange? {
        let end = min(NSMaxRange(prefix), ns.length)
        var k = prefix.location + 1                    // past the marker
        while k < end, isIdentChar(ns.character(at: k)) || ns.character(at: k) == dot { k += 1 }
        guard k < end, ns.character(at: k) == lparen else { return nil }
        guard let close = balanced(ns, len: end, from: k + 1, open: lparen, close: rparen) else { return nil }
        return NSRange(location: k + 1, length: close - (k + 1))
    }

    // MARK: - Character classes

    /// `[A-Za-z_]`
    private static func isIdentStart(_ c: unichar) -> Bool {
        (c >= 0x41 && c <= 0x5A) || (c >= 0x61 && c <= 0x7A) || c == 0x5F
    }

    /// `[A-Za-z0-9_-]`
    private static func isIdentChar(_ c: unichar) -> Bool {
        isIdentStart(c) || (c >= 0x30 && c <= 0x39) || c == 0x2D
    }

    /// Whether a directive may open after `c`.
    ///
    /// Stated as a DENY list — only letters and digits reject — rather than an
    /// allow list of punctuation. An allow list looks safer and is wrong: it
    /// silently breaks every markup context that abuts a directive
    /// (`*@font(size: 18){x}*`, `**…**`, `~~…~~`, `- @pagebreak`), because the
    /// preceding character is a markup delimiter nobody remembered to list.
    ///
    /// Rejecting word characters is all the email rule needs:
    /// `name@example.com` is preceded by `e`. Underscore is deliberately a
    /// boundary so `_@font(size: 18){x}_` works; `foo_@example.com` is not a
    /// shape worth protecting, and the name still has to be registered.
    private static func isBoundary(_ c: unichar) -> Bool {
        guard let scalar = UnicodeScalar(c) else { return true }   // surrogate half
        return !CharacterSet.alphanumerics.contains(scalar)
    }

    // MARK: - Scanning helpers

    /// Index of the delimiter balancing the run starting at `from`, or nil
    /// when the run is unbalanced or crosses a line break. Escaped delimiters
    /// and delimiters inside a quoted string don't count.
    private static func balanced(_ ns: NSString, len: Int, from: Int, open: unichar, close: unichar) -> Int? {
        var depth = 1
        var inQuote = false
        var k = from
        while k < len {
            let c = ns.character(at: k)
            if c == newline || c == carriageReturn { return nil }
            if !isEscaped(k, ns) {
                if c == quote {
                    inQuote.toggle()
                } else if !inQuote {
                    if c == open { depth += 1 }
                    if c == close {
                        depth -= 1
                        if depth == 0 { return k }
                    }
                }
            }
            k += 1
        }
        return nil
    }

    /// Whether the character at `index` is preceded by an odd number of
    /// backslashes. Mirrors `InlineParser.isEscaped`, kept local so this file
    /// has no private dependency on the parser.
    private static func isEscaped(_ index: Int, _ ns: NSString) -> Bool {
        var count = 0
        var k = index - 1
        while k >= 0, ns.character(at: k) == backslash {
            count += 1
            k -= 1
        }
        return count % 2 == 1
    }
}
