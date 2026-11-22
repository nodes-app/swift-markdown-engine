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
import MarkdownEngineSyntax

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

extension ExtensionRegistry {
    /// The registry for `extensions`' syntax, in registration order.
    init(extensions: [any MarkdownExtension], directives: DirectiveRegistry = .empty) {
        self.init(syntax: extensions.map { (id: $0.id, inline: $0.inline, block: $0.block) },
                  directives: directives)
    }
}

extension MarkdownEditorConfiguration {
    /// The parser-facing registry derived from `extensions` and `directives`.
    var extensionRegistry: ExtensionRegistry {
        ExtensionRegistry(extensions: extensions, directives: directiveRegistry)
    }

    /// Styler-facing lookup: extension behavior by id.
    var extensionsByID: [String: any MarkdownExtension] {
        var out: [String: any MarkdownExtension] = [:]
        for ext in extensions { out[ext.id] = ext }
        return out
    }
}
