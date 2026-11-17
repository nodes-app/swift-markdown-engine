import AppKit
import Foundation

/// Describes a link activation before the editor applies its default routing.
public struct MarkdownLinkActivation: Sendable, Equatable {
    /// The syntax that produced the activated link.
    public enum Kind: Sendable, Equatable {
        /// A Markdown `[label](destination)` link.
        case inlineLink
        /// A `[[name]]` or `[[name|identifier]]` link.
        case wikiLink
        /// A URL detected in plain text.
        case autolink
    }

    /// The syntax that produced this activation.
    public let kind: Kind

    /// The destination as written in the source. Inline Markdown destinations
    /// have angle brackets and an optional title removed, with no decoding.
    public let destination: String
    /// UTF-16 range of the full link token in raw Markdown storage coordinates.
    public let sourceRange: NSRange
    /// Device-independent modifier keys held during the click.
    public let modifierFlags: NSEvent.ModifierFlags
    /// Whether the activated editor currently allows text editing.
    public let isEditable: Bool

    /// Creates an activation with its source destination and UTF-16 token range.
    public init(
        kind: Kind,
        destination: String,
        sourceRange: NSRange,
        modifierFlags: NSEvent.ModifierFlags,
        isEditable: Bool
    ) {
        self.kind = kind
        self.destination = destination
        self.sourceRange = sourceRange
        self.modifierFlags = modifierFlags
        self.isEditable = isEditable
    }
}
