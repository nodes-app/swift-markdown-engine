//
//  MarkdownDirective.swift
//  MarkdownEngine
//
//  The directive seam: a NAMED, ARGUMENT-CARRYING inline command —
//  `@pagebreak`, `@font(size: 18){styled text}` — contributed by the embedder
//  instead of hard-coded into the parser. Sibling of `MarkdownExtension`,
//  which covers delimiter-shaped constructs (`==x==`, `::: … :::`) and cannot
//  express a name plus a typed argument list.
//
//  This file is the PARSING half of the seam: the protocol, the syntax rule,
//  and the argument schema. Presentation (font transforms, glyphs) and
//  autocomplete extend the protocol in follow-up changes; nothing here styles
//  anything yet.
//
//  Two forms, both TREE-SHAPED — a directive's effect never escapes its own
//  node:
//
//    * self-contained — `@pagebreak`, `@date(format: iso)`. A leaf.
//    * container      — `@font(size: 18){text}`. The body is re-parsed as
//      markdown, and will later be styled with the directive's font transform
//      COMPOSED over the inherited font, so `@font(size: 18){**bold**}` comes
//      out bold AND 18pt.
//
//  There is deliberately no "applies to everything after me" form. That would
//  make styling depend on document position rather than tree position, which
//  breaks both the styler's compose-on-descent model and the block-scoped
//  incremental restyle (a directive's effect would outlive its own block).
//
//  Isolation contract, inherited verbatim from `MarkdownExtension`: a directive
//  supplies SYNTAX (name + parameter schema) and PRESENTATION (font transform,
//  attributes, glyph). It never emits ranges — the parser derives all geometry.
//  A misbehaving directive can restyle its own body at worst, never a neighbor.
//
//  Two rules do the safety work, and both live in `DirectiveScanner`:
//    1. REGISTERED NAMES ONLY — `@home` in prose stays literal text unless
//       `home` is registered. This is what makes the seam safe to enable over
//       an existing document corpus.
//    2. LEFT BOUNDARY — a directive opens only at start-of-line or after
//       whitespace / opening punctuation, so `name@example.com` never opens
//       one.
//

import AppKit
import Foundation

// MARK: - Values

/// Unit suffix on a numeric argument: `18`, `18pt`, `1.5em`, `50%`.
public enum DirectiveUnit: String, Sendable, Equatable, CaseIterable {
    case none = ""
    case point = "pt"
    case em
    case percent = "%"
}

/// One parsed argument value. Deliberately small and closed — directives get
/// typed accessors rather than raw text, so an embedder never re-parses.
public enum DirectiveValue: Sendable, Equatable {
    /// `"quoted text"`
    case string(String)
    /// `18`, `-0.5`
    case number(Double)
    /// `18pt`, `1.5em`, `50%` (and bare numbers in a `.length` parameter)
    case length(Double, DirectiveUnit)
    /// `true` / `false`
    case boolean(Bool)
    /// Bareword: `red`, `center`, `iso8601`
    case keyword(String)

    public var asString: String? {
        switch self {
        case .string(let s), .keyword(let s): return s
        default: return nil
        }
    }

    public var asDouble: Double? {
        switch self {
        case .number(let n), .length(let n, _): return n
        default: return nil
        }
    }

    public var asBool: Bool? {
        if case .boolean(let b) = self { return b }
        return nil
    }

    /// Resolve against an inherited size: `pt` and unitless are absolute, `em`
    /// and `%` are relative.
    public func resolvedLength(relativeTo base: CGFloat) -> CGFloat? {
        guard case .length(let value, let unit) = self else {
            return asDouble.map { CGFloat($0) }
        }
        switch unit {
        case .none, .point: return CGFloat(value)
        case .em:           return base * CGFloat(value)
        case .percent:      return base * CGFloat(value) / 100
        }
    }
}

// MARK: - Parameter schema

/// One declared parameter. The schema drives three things at once: argument
/// coercion, diagnostics for a malformed call, and (later) argument-level
/// autocomplete inside the parens.
public struct DirectiveParameter: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        case string
        case number
        case length
        case boolean
        /// Closed set of barewords, e.g. `["left", "center", "right"]`. An
        /// empty set accepts any bareword.
        case keyword([String])
    }

    /// `nil` for a positional parameter (`@color(red)`).
    public var label: String?
    public var kind: Kind
    public var isRequired: Bool
    public var defaultValue: DirectiveValue?
    /// Shown in the completion picker's argument hint.
    public var documentation: String

    public init(
        label: String?,
        kind: Kind,
        isRequired: Bool = false,
        defaultValue: DirectiveValue? = nil,
        documentation: String = ""
    ) {
        self.label = label
        self.kind = kind
        self.isRequired = isRequired
        self.defaultValue = defaultValue
        self.documentation = documentation
    }
}

// MARK: - Syntax rule

/// The syntax of a directive: its name, which form(s) it accepts, and its
/// parameter schema. The marker character comes from the registry settings
/// unless the directive overrides it.
public struct DirectiveSyntax: Sendable, Equatable {
    public enum Form: String, Sendable, Equatable {
        /// `@pagebreak` — no body. A body makes the candidate literal.
        case selfContained
        /// `@font(size: 18){…}` — body required. No body makes it literal.
        case container
        /// Body optional.
        case either
    }

    /// `[A-Za-z_][A-Za-z0-9_-]*`, dot-separated segments allowed
    /// (`layout.columns`). Matched EXACTLY — an unregistered name stays
    /// literal text, exactly like unregistered extension syntax.
    public var name: String
    public var form: Form
    /// Override the registry's default marker for this one directive. `nil`
    /// uses ``DirectiveRegistrySettings/defaultMarker`` (`@`).
    public var marker: Character?
    public var parameters: [DirectiveParameter]
    /// Whether the body is re-parsed as markdown (container, like a link's
    /// text) or kept opaque (leaf, like a code span).
    public var parsesBody: Bool

    public init(
        name: String,
        form: Form,
        marker: Character? = nil,
        parameters: [DirectiveParameter] = [],
        parsesBody: Bool = true
    ) {
        self.name = name
        self.form = form
        self.marker = marker
        self.parameters = parameters
        self.parsesBody = parsesBody
    }
}

// MARK: - Styling result

/// How a directive changes the font of its body. Data, not a closure, so the
/// transform is inspectable, testable, and cheap in the per-keystroke styling
/// path — with `custom` as the escape hatch for the rare case.
public struct DirectiveFontTransform {
    public enum Size {
        case absolute(CGFloat)
        case scale(CGFloat)
    }

    public var size: Size?
    public var traits: NSFontTraitMask?
    public var familyName: String?
    public var custom: ((NSFont) -> NSFont)?

    public static let inherit = DirectiveFontTransform()

    public init(
        size: Size? = nil,
        traits: NSFontTraitMask? = nil,
        familyName: String? = nil,
        custom: ((NSFont) -> NSFont)? = nil
    ) {
        self.size = size
        self.traits = traits
        self.familyName = familyName
        self.custom = custom
    }

    /// Compose over the INHERITED font — the whole point. `@font(size: 18)`
    /// inside a heading keeps the heading's bold; `**bold**` inside the body
    /// keeps 18pt.
    public func apply(to font: NSFont, manager: NSFontManager = .shared) -> NSFont {
        var result = font
        if let familyName {
            result = NSFont(name: familyName, size: result.pointSize) ?? result
        }
        switch size {
        case .absolute(let points): result = manager.convert(result, toSize: points)
        case .scale(let factor):    result = manager.convert(result, toSize: result.pointSize * factor)
        case nil:                   break
        }
        if let traits { result = manager.convert(result, toHaveTrait: traits) }
        if let custom { result = custom(result) }
        return result
    }
}

/// What a container directive does to its body.
public struct DirectiveStyle {
    public var font: DirectiveFontTransform
    /// Non-font attributes for the body range (background, colour, kern…).
    public var attributes: [NSAttributedString.Key: Any]

    public static let inherit = DirectiveStyle()

    public init(
        font: DirectiveFontTransform = .inherit,
        attributes: [NSAttributedString.Key: Any] = [:]
    ) {
        self.font = font
        self.attributes = attributes
    }
}

/// Everything a directive may read while deciding how to present itself.
/// Read-only by construction — a directive cannot reach the text storage.
public struct DirectiveContext {
    public let theme: MarkdownEditorTheme
    /// Font inherited at the directive's position (heading font inside a
    /// heading, body font in a paragraph).
    public let inheritedFont: NSFont
    /// True when the caret is inside the directive — source is revealed.
    public let isActive: Bool
    public let marker: Character

    public init(theme: MarkdownEditorTheme, inheritedFont: NSFont, isActive: Bool, marker: Character) {
        self.theme = theme
        self.inheritedFont = inheritedFont
        self.isActive = isActive
        self.marker = marker
    }
}

// MARK: - The protocol

/// An embedder-contributed inline command. Register instances via
/// `MarkdownEditorConfiguration.directives`; an unregistered name stays
/// literal text.
public protocol MarkdownDirective: Sendable {
    /// Stable identifier, unique per directive. Defaults to `syntax.name`.
    /// Used for dispatch and cache keying — never shown to users.
    var id: String { get }
    var syntax: DirectiveSyntax { get }

    /// Container form: how the body is styled. Ignored for self-contained.
    /// Called during styling; must be cheap and synchronous.
    func style(arguments: DirectiveArguments, context: DirectiveContext) -> DirectiveStyle

    /// Clean-copy path. `bodyHTML` is already escaped / recursively rendered
    /// (empty for self-contained).
    func html(arguments: DirectiveArguments, bodyHTML: String) -> String

}

public extension MarkdownDirective {
    // NOTE: like `MarkdownExtension`, these defaults mean a conformance that
    // misspells `syntax` compiles fine and yields an inert directive. If your
    // command never fires, check that name first.
    var id: String { syntax.name }

    func style(arguments: DirectiveArguments, context: DirectiveContext) -> DirectiveStyle { .inherit }

    func html(arguments: DirectiveArguments, bodyHTML: String) -> String {
        bodyHTML.isEmpty
            ? "<span data-directive=\"\(id)\"></span>"
            : "<span data-directive=\"\(id)\">\(bodyHTML)</span>"
    }

}
