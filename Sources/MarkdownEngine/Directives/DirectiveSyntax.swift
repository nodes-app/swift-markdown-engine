//
//  DirectiveSyntax.swift
//  MarkdownEngine
//
//  The directive seam's syntax: argument values, the parameter schema and the
//  syntax rule, which the parser reads. Its presentation half is in
//  `MarkdownDirective.swift`.
//

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
