//
//  DirectiveCompletionScanner.swift
//  MarkdownEngine
//
//  Phase 4 — what is the caret trying to complete?
//
//  Autocomplete cannot read the AST: while you are typing, `@ico` and
//  `@icon(sta` are not directives yet — the scanner rejects them (no body, no
//  closing paren), which is exactly right for STYLING and useless for
//  COMPLETION. So this is a separate, deliberately forgiving scan backwards
//  from the caret over the current line.
//
//  It answers one question — "is the caret in a directive NAME, or in one of
//  its ARGUMENTS?" — and hands back the range a pick should replace. The
//  engine then asks the registry (for names) or the directive itself (for
//  values) what the candidates are, so a newly registered directive appears in
//  the picker with no embedder change.
//

import Foundation

// MARK: - What is being completed

public enum DirectiveCompletionKind: Sendable, Equatable {
    /// Typing the directive name: `@fo|`
    case name
    /// Typing an argument value: `@icon(sta|` or `@icon(star, color: gr|`.
    /// `label` is nil for a positional argument; `index` is its position
    /// among the arguments of the call.
    case argument(label: String?, index: Int)
}

// MARK: - One offered candidate

/// A single row in the embedder's picker. Uniform across name and value
/// completion, so one list UI serves both.
public struct DirectiveCompletionItem: Sendable, Equatable {
    /// Primary text, e.g. `font` or `JP`.
    public var title: String
    /// Secondary text, e.g. a description or a country name.
    public var subtitle: String
    /// Optional preview of the RESULT — the flag for a country code, the
    /// glyph for a symbol. Shown by the picker; never inserted.
    public var detail: String?
    /// Text that replaces ``DirectiveCompletionContext/replacementRange``.
    public var insertion: String
    /// Caret position within `insertion` after the pick; nil lands at the end.
    public var caretOffset: Int?
    /// SF Symbol for the row.
    public var symbolName: String?

    public init(
        title: String,
        subtitle: String = "",
        detail: String? = nil,
        insertion: String,
        caretOffset: Int? = nil,
        symbolName: String? = nil
    ) {
        self.title = title
        self.subtitle = subtitle
        self.detail = detail
        self.insertion = insertion
        self.caretOffset = caretOffset
        self.symbolName = symbolName
    }

    /// Build from a directive's declared name-completion metadata, splitting
    /// the `|` caret marker out of the snippet.
    init(_ completion: DirectiveCompletion) {
        let snippet = completion.snippet
        let caret = snippet.firstIndex(of: "|")
        self.init(
            title: completion.title,
            subtitle: completion.subtitle,
            detail: nil,
            insertion: snippet.replacingOccurrences(of: "|", with: ""),
            caretOffset: caret.map { snippet.distance(from: snippet.startIndex, to: $0) },
            symbolName: completion.symbolName
        )
    }
}

// MARK: - The caret's completion context

/// Everything the embedder needs to show a picker, delivered through
/// ``NativeTextViewWrapper/onDirectiveCompletion``. `nil` means "no picker".
public struct DirectiveCompletionContext: Sendable {
    public let kind: DirectiveCompletionKind
    public let marker: Character
    /// Text typed so far for the thing being completed (may be empty).
    public let prefix: String
    /// Document range a pick replaces.
    public let replacementRange: NSRange
    /// The directive being called; nil while its name is still incomplete.
    public let directiveID: String?
    /// Registry- or directive-supplied candidates, already filtered by
    /// `prefix` and ranked.
    public let candidates: [DirectiveCompletionItem]

    public init(
        kind: DirectiveCompletionKind,
        marker: Character,
        prefix: String,
        replacementRange: NSRange,
        directiveID: String?,
        candidates: [DirectiveCompletionItem]
    ) {
        self.kind = kind
        self.marker = marker
        self.prefix = prefix
        self.replacementRange = replacementRange
        self.directiveID = directiveID
        self.candidates = candidates
    }
}

// MARK: - Committing a pick

/// Push one of these into ``NativeTextViewWrapper/pendingDirectiveCompletion``
/// to commit a picked candidate. The engine replaces the range, places the
/// caret, and clears the binding.
public struct DirectiveCompletionRequest: Sendable {
    /// Stable id so the engine can ignore an already-applied request across
    /// SwiftUI re-renders.
    public let id: UUID
    /// Document the pick targets; ignored when it doesn't match the editor's
    /// `documentId` (prevents cross-document writes).
    public let documentId: String
    public let replacementRange: NSRange
    public let insertion: String
    /// Caret position within `insertion`; nil lands past it.
    public let caretOffset: Int?

    public init(
        id: UUID = UUID(),
        documentId: String,
        replacementRange: NSRange,
        insertion: String,
        caretOffset: Int? = nil
    ) {
        self.id = id
        self.documentId = documentId
        self.replacementRange = replacementRange
        self.insertion = insertion
        self.caretOffset = caretOffset
    }

    /// Convenience: commit `item` for `context`.
    public init(documentId: String, context: DirectiveCompletionContext, item: DirectiveCompletionItem) {
        self.init(
            documentId: documentId,
            replacementRange: context.replacementRange,
            insertion: item.insertion,
            caretOffset: item.caretOffset
        )
    }
}

// MARK: - Scanner

enum DirectiveCompletionScanner {

    private static let lparen: unichar = 0x28
    private static let rparen: unichar = 0x29
    private static let lbrace: unichar = 0x7B
    private static let comma: unichar = 0x2C
    private static let colon: unichar = 0x3A
    private static let quote: unichar = 0x22
    private static let backslash: unichar = 0x5C
    private static let dot: unichar = 0x2E

    /// Longest name we will scan backwards over before giving up. Bounds the
    /// work per caret move to a constant, independent of line length.
    private static let maxScanback = 256

    /// Classify the caret, or nil when it isn't completing a directive.
    static func context(
        in ns: NSString,
        caret: Int,
        registry: DirectiveRegistry,
        directives: [any MarkdownDirective],
        settings: DirectiveRegistrySettings
    ) -> DirectiveCompletionContext? {
        guard !registry.isEmpty, caret >= 0, caret <= ns.length else { return nil }

        guard let markerIndex = findMarker(in: ns, caret: caret, registry: registry) else { return nil }
        let marker = ns.character(at: markerIndex)
        guard let table = registry.byMarker[marker] else { return nil }

        // Name run.
        var cursor = markerIndex + 1
        while cursor < caret, isNameChar(ns.character(at: cursor)) { cursor += 1 }
        let nameRange = NSRange(location: markerIndex + 1, length: cursor - (markerIndex + 1))
        let name = ns.substring(with: nameRange)

        // Still inside the name: complete the directive name itself.
        if cursor == caret {
            let candidates = nameCandidates(prefix: name, marker: marker, directives: directives, settings: settings)
            guard !candidates.isEmpty else { return nil }
            return DirectiveCompletionContext(
                kind: .name,
                marker: Character(UnicodeScalar(marker) ?? "@"),
                prefix: name,
                replacementRange: NSRange(location: markerIndex, length: caret - markerIndex),
                directiveID: nil,
                candidates: candidates
            )
        }

        // Past the name — the only other completable position is inside the
        // argument list of a REGISTERED directive.
        guard ns.character(at: cursor) == lparen,
              let entry = table[name],
              let directive = directives.first(where: { $0.id == entry.id })
        else { return nil }

        return argumentContext(
            in: ns, caret: caret, openParen: cursor, marker: marker,
            directive: directive
        )
    }

    // MARK: Marker

    /// Nearest marker before `caret` that could open a directive, or nil.
    /// Stops at the line start, at whitespace runs that can't be inside a
    /// call, and after `maxScanback` characters.
    private static func findMarker(in ns: NSString, caret: Int, registry: DirectiveRegistry) -> Int? {
        var index = caret - 1
        let limit = max(0, caret - maxScanback)
        while index >= limit {
            let c = ns.character(at: index)
            if c == 0x0A || c == 0x0D { return nil }              // line start
            if c == lbrace { return nil }                          // inside a body, not a call
            if registry.byMarker[c] != nil, !isEscaped(index, ns) {
                // Same boundary rule the parser uses, so completion can't
                // offer a directive the parser would refuse to recognise.
                if index == 0 { return index }
                let previous = ns.character(at: index - 1)
                if previous != c, isBoundary(previous) { return index }
            }
            index -= 1
        }
        return nil
    }

    // MARK: Arguments

    private static func argumentContext(
        in ns: NSString,
        caret: Int,
        openParen: Int,
        marker: unichar,
        directive: any MarkdownDirective
    ) -> DirectiveCompletionContext? {
        // The caret must be INSIDE the parens: no unescaped `)` between the
        // opening paren and the caret at depth 0, and no line break.
        var depth = 0
        var inQuote = false
        var segmentStart = openParen + 1
        var index = openParen + 1
        var argumentIndex = 0
        while index < caret {
            let c = ns.character(at: index)
            if c == 0x0A || c == 0x0D { return nil }
            if c == quote, !isEscaped(index, ns) { inQuote.toggle() }
            if !inQuote, !isEscaped(index, ns) {
                if c == lparen { depth += 1 }
                if c == rparen {
                    if depth == 0 { return nil }                   // call already closed
                    depth -= 1
                }
                if c == comma, depth == 0 {
                    argumentIndex += 1
                    segmentStart = index + 1
                }
            }
            index += 1
        }

        // Split the current segment into an optional `label:` and the value
        // typed so far.
        var label: String?
        var valueStart = segmentStart
        var scan = segmentStart
        var quoted = false
        while scan < caret {
            let c = ns.character(at: scan)
            if c == quote { quoted.toggle() }
            if c == colon, !quoted {
                label = ns.substring(with: NSRange(location: segmentStart, length: scan - segmentStart))
                    .trimmingCharacters(in: .whitespaces)
                valueStart = scan + 1
                break
            }
            scan += 1
        }
        // Leading whitespace belongs to the separator, not the value.
        while valueStart < caret, ns.character(at: valueStart) == 0x20 || ns.character(at: valueStart) == 0x09 {
            valueStart += 1
        }
        let prefix = ns.substring(with: NSRange(location: valueStart, length: caret - valueStart))

        // Resolve which parameter this is.
        let schema = directive.syntax.parameters
        let parameter: DirectiveParameter?
        if let label {
            parameter = schema.first { $0.label == label }
        } else {
            let positional = schema.filter { $0.label == nil }
            parameter = argumentIndex < positional.count ? positional[argumentIndex] : nil
        }
        guard let parameter else { return nil }

        let candidates = directive.valueCompletions(for: parameter, prefix: prefix)
        guard !candidates.isEmpty else { return nil }

        return DirectiveCompletionContext(
            kind: .argument(label: label, index: argumentIndex),
            marker: Character(UnicodeScalar(marker) ?? "@"),
            prefix: prefix,
            replacementRange: NSRange(location: valueStart, length: caret - valueStart),
            directiveID: directive.id,
            candidates: candidates
        )
    }

    // MARK: Name candidates

    /// Registry-filtered directive names. The engine owns this ranking, so a
    /// newly registered directive shows up with no embedder change.
    private static func nameCandidates(
        prefix: String,
        marker: unichar,
        directives: [any MarkdownDirective],
        settings: DirectiveRegistrySettings
    ) -> [DirectiveCompletionItem] {
        let needle = prefix.lowercased()
        let defaultMarker = settings.defaultMarker
        return directives
            .filter { directive in
                let own = directive.syntax.marker ?? defaultMarker
                guard Array(String(own).utf16).first == marker else { return false }
                guard !needle.isEmpty else { return true }
                if directive.syntax.name.lowercased().hasPrefix(needle) { return true }
                return directive.completion.keywords.contains { $0.lowercased().hasPrefix(needle) }
            }
            // Name-prefix matches rank above keyword-only matches, then
            // alphabetically — stable and predictable while typing.
            .sorted { a, b in
                let aName = a.syntax.name.lowercased().hasPrefix(needle)
                let bName = b.syntax.name.lowercased().hasPrefix(needle)
                if aName != bName { return aName }
                return a.syntax.name < b.syntax.name
            }
            .map { DirectiveCompletionItem($0.completion) }
    }

    // MARK: Character classes

    private static func isNameChar(_ c: unichar) -> Bool {
        (c >= 0x41 && c <= 0x5A) || (c >= 0x61 && c <= 0x7A)
            || (c >= 0x30 && c <= 0x39) || c == 0x5F || c == 0x2D || c == dot
    }

    private static func isBoundary(_ c: unichar) -> Bool {
        guard let scalar = UnicodeScalar(c) else { return true }
        return !CharacterSet.alphanumerics.contains(scalar)
    }

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
