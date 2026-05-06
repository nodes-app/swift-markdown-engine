//
//  NativeTextViewSelectionTypes.swift
//  MarkdownEngine
//
//  Created by Luca Chen on 16.03.26.
//
//  Public selection / replacement value types exposed by NativeTextViewWrapper.
//

import Foundation

/// A range of text occupied by a wiki-link `[[Name]]`, in both the display
/// and (where known) the storage coordinate systems.
public struct WikiLinkSelection: Sendable {
    /// Range of the link in the document the user is editing (display form).
    public let displayRange: NSRange
    /// Equivalent range in the underlying storage form `[[Name|<id>]]`,
    /// or `nil` when the storage range is unknown / the link is new.
    public let storageRange: NSRange?
    /// Plain text the user will see inside the brackets — used by embedders
    /// to seed a rename popover or autocomplete.
    public let placeholder: String

    public init(displayRange: NSRange, storageRange: NSRange?, placeholder: String) {
        self.displayRange = displayRange
        self.storageRange = storageRange
        self.placeholder = placeholder
    }
}

/// Which kind of inline token the caret is currently inside.
public enum InlineSelectionKind: Sendable {
    /// A `[[Name]]` wiki-link.
    case wikiLink
    /// A `![[Name]]` embedded-image reference.
    case imageEmbed
}

/// Snapshot of the inline token the caret is inside, delivered through
/// ``NativeTextViewWrapper/onInlineSelectionChange``.
public struct InlineSelectionState: Sendable {
    /// Whether the active token is a wiki-link or an image embed.
    public let kind: InlineSelectionKind
    /// Range and seed text of the active inline token.
    public let selection: WikiLinkSelection

    public init(kind: InlineSelectionKind, selection: WikiLinkSelection) {
        self.kind = kind
        self.selection = selection
    }
}

/// Request to replace an inline token's source with a new storage fragment.
///
/// Embedders push one of these into
/// ``NativeTextViewWrapper/pendingInlineReplacement`` to commit the result of
/// a rename / autocomplete UI. The engine applies the replacement, restores
/// the caret past it, and clears the binding.
public struct InlineReplacementRequest: Sendable {
    /// Stable identifier so the engine can detect already-applied requests
    /// across SwiftUI re-renders.
    public let id: UUID
    /// Document the replacement targets. Ignored if it doesn't match the
    /// editor's current `documentId` (prevents cross-document writes).
    public let documentId: String
    /// Inline-token range being replaced.
    public let selection: WikiLinkSelection
    /// New storage-form text, e.g. `"[[New Name|<id>]]"` or
    /// `"![[image-name]]"`.
    public let storageFragment: String
    /// `true` when the fragment is a `![[…]]` image embed and the engine
    /// should treat it as a standalone block.
    public let isImageEmbedMode: Bool

    public init(
        id: UUID = UUID(),
        documentId: String,
        selection: WikiLinkSelection,
        storageFragment: String,
        isImageEmbedMode: Bool
    ) {
        self.id = id
        self.documentId = documentId
        self.selection = selection
        self.storageFragment = storageFragment
        self.isImageEmbedMode = isImageEmbedMode
    }
}
