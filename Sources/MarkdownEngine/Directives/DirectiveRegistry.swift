//
//  DirectiveRegistry.swift
//  MarkdownEngine
//
//  Precompiled, purely syntactic view of the registered directives — the only
//  thing the parser sees. Mirrors `ExtensionRegistry`, and is carried BY it
//  (`ExtensionRegistry.directives`) so the directive fingerprint folds into
//  the one grammar fingerprint every parse cache already keys on. Registering
//  a directive therefore invalidates the caches for free; there is no second
//  cache key to thread through the pipeline.
//

import Foundation

// MARK: - Marker settings

/// Marker configuration for the whole registry.
///
/// `@` is the default: it is the modern convention for "invoke something
/// inline" (Notion / Linear / Slack), and unlike `\` it collides neither with
/// the LaTeX vocabulary this engine renders through `$…$` / `$$…$$` nor with
/// CommonMark's `\`+punctuation escapes.
///
/// Additional markers may be registered simultaneously — the scanner
/// dispatches on the first character — so an embedder that wants
/// LaTeX-flavoured authoring can register directives under `\` and keep `@`
/// free for mentions, or drop `@` entirely.
///
/// - Important: `@` is also the conventional trigger for @-mentions. An app
///   that already uses `@` for people or documents should give directives a
///   different marker rather than disambiguating at the trigger: the two
///   pickers would otherwise compete for the same keystroke. The
///   registered-names-only rule limits the damage (`@alice` stays literal
///   unless `alice` is a directive), but the completion picker still opens on
///   the bare marker.
///
/// - Note: A marker must be a single UTF-16 code unit. Emoji and other
///   multi-scalar characters are rejected at registration so marker dispatch
///   stays one dictionary probe per character on the parse hot path.
public struct DirectiveRegistrySettings: Sendable, Equatable {
    /// Marker used by directives that don't override it. Must be a single
    /// UTF-16 code unit; see the type's note.
    public var defaultMarker: Character

    public static let `default` = DirectiveRegistrySettings()

    public init(defaultMarker: Character = "@") {
        self.defaultMarker = defaultMarker
    }
}

// MARK: - Parser-facing registry (internal)

/// Precompiled directive rules. Built once per parse entry from the
/// configuration, exactly like `ExtensionRegistry`.
struct DirectiveRegistry {

    /// Directive nodes are represented in the AST as extension-shaped nodes
    /// (`InlineNode.ext`) whose id carries this prefix. That gives directives
    /// the whole downstream pipeline — marker shrink, caret reveal, token
    /// projection, incremental restyle, rich copy — with no new node kind, and
    /// keeps the directive seam additive against upstream changes.
    ///
    /// An extension whose own id starts with this prefix would collide; the
    /// prefix contains a `.`, which no bundled extension id uses.
    static let idPrefix = "directive."

    /// The AST id for a directive id.
    static func nodeID(for directiveID: String) -> String { idPrefix + directiveID }

    /// The directive id for an AST id, or nil when the node isn't a directive.
    static func directiveID(forNodeID nodeID: String) -> String? {
        nodeID.hasPrefix(idPrefix) ? String(nodeID.dropFirst(idPrefix.count)) : nil
    }

    struct Entry {
        let id: String
        let name: String
        let marker: unichar
        let form: DirectiveSyntax.Form
        let parsesBody: Bool
    }

    /// marker → name → entry. Two-level so the scanner rejects a non-marker
    /// character in a single dictionary probe — the common case on every
    /// character of every parse.
    let byMarker: [unichar: [String: Entry]]
    /// Stable fingerprint for cache keying ("" when empty). Two registries
    /// with the same fingerprint produce identical parses for identical text.
    let fingerprint: String

    static let empty = DirectiveRegistry(byMarker: [:], fingerprint: "")

    private init(byMarker: [unichar: [String: Entry]], fingerprint: String) {
        self.byMarker = byMarker
        self.fingerprint = fingerprint
    }

    init(directives: [any MarkdownDirective], settings: DirectiveRegistrySettings = .default) {
        guard !directives.isEmpty else {
            self = .empty
            return
        }
        let defaultMarker = Self.unichar(for: settings.defaultMarker)
        var table: [unichar: [String: Entry]] = [:]
        for directive in directives {
            let syntax = directive.syntax
            guard !syntax.name.isEmpty else { continue }
            let marker = syntax.marker.map(Self.unichar(for:)) ?? defaultMarker
            guard marker != 0 else { continue }
            // First registration wins, matching extension precedence.
            guard table[marker]?[syntax.name] == nil else { continue }
            table[marker, default: [:]][syntax.name] = Entry(
                id: directive.id,
                name: syntax.name,
                marker: marker,
                form: syntax.form,
                parsesBody: syntax.parsesBody
            )
        }
        self.byMarker = table
        // Only fields that change the PARSE participate — presentation-only
        // edits (colours, completion prose) must not invalidate parse caches.
        // Free-text fields are length-prefixed so the concatenation is
        // injective: a name containing the separator cannot alias another
        // registry.
        func framed(_ string: String) -> String { "\(string.utf16.count).\(string)" }
        self.fingerprint = directives
            .map { directive in
                let syntax = directive.syntax
                let marker = syntax.marker.map(String.init) ?? String(settings.defaultMarker)
                return [
                    framed(directive.id), framed(syntax.name), framed(marker),
                    syntax.form.rawValue, "\(syntax.parsesBody)",
                ].joined(separator: ",")
            }
            .joined(separator: "|")
    }

    var isEmpty: Bool { byMarker.isEmpty }

    func entry(marker: unichar, name: String) -> Entry? { byMarker[marker]?[name] }

    /// UTF-16 code unit for a marker, or 0 when the character isn't
    /// representable in one unit (an emoji marker is rejected at registration
    /// rather than half-matched at scan time).
    private static func unichar(for character: Character) -> unichar {
        let units = Array(String(character).utf16)
        return units.count == 1 ? units[0] : 0
    }
}

// MARK: - Configuration bridge

public extension MarkdownEditorConfiguration {
    /// Styler-facing lookup: directive behaviour by id.
    var directivesByID: [String: any MarkdownDirective] {
        var out: [String: any MarkdownDirective] = [:]
        for directive in directives { out[directive.id] = directive }
        return out
    }
}

extension MarkdownEditorConfiguration {
    /// The parser-facing directive registry derived from `directives`.
    var directiveRegistry: DirectiveRegistry {
        DirectiveRegistry(directives: directives, settings: directiveSettings)
    }
}
