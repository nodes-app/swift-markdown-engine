//
//  DirectiveArguments.swift
//  MarkdownEngine
//
//  Schema-driven coercion of a directive's argument list.
//
//  Runs at STYLING time, not parse time: the parser stays geometry-only (the
//  isolation contract), and a document with no directives pays nothing. One
//  short scan per directive per restyle sits well under the existing per-block
//  token memo cost; if it ever shows up in a profile, memoise on
//  (substring, schema fingerprint).
//
//  Coercion never throws and never partially applies: an argument that fails
//  its schema is dropped and recorded as a diagnostic, so a directive always
//  receives a well-formed `DirectiveArguments` and can decide for itself
//  whether to render as invalid.
//

import Foundation

// MARK: - Diagnostics

/// A problem found while coercing a call against its schema.
public struct DirectiveDiagnostic: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        case unknownLabel(String)
        case typeMismatch(label: String, expected: String)
        case missingRequired(String)
        case tooManyPositional
    }
    public let kind: Kind
    /// Absolute range of the offending argument, for diagnostics styling.
    public let range: NSRange

    public init(kind: Kind, range: NSRange) {
        self.kind = kind
        self.range = range
    }
}

// MARK: - Arguments

/// Arguments of one directive call, already coerced against the schema.
public struct DirectiveArguments: Sendable, Equatable {
    public let labeled: [String: DirectiveValue]
    public let positional: [DirectiveValue]
    public let diagnostics: [DirectiveDiagnostic]

    public static let empty = DirectiveArguments(labeled: [:], positional: [], diagnostics: [])

    public init(
        labeled: [String: DirectiveValue],
        positional: [DirectiveValue],
        diagnostics: [DirectiveDiagnostic]
    ) {
        self.labeled = labeled
        self.positional = positional
        self.diagnostics = diagnostics
    }

    /// True when every argument coerced cleanly and every required parameter
    /// was supplied.
    public var isValid: Bool { diagnostics.isEmpty }

    public subscript(_ label: String) -> DirectiveValue? { labeled[label] }

    public func string(_ label: String) -> String? { labeled[label]?.asString }
    public func number(_ label: String) -> Double? { labeled[label]?.asDouble }
    public func bool(_ label: String) -> Bool? { labeled[label]?.asBool }
    public func length(_ label: String, relativeTo base: CGFloat) -> CGFloat? {
        labeled[label]?.resolvedLength(relativeTo: base)
    }
}

// MARK: - Parsing

extension DirectiveArguments {

    /// Parse and coerce the argument list at `range` against `schema`.
    /// A nil or empty range still applies defaults and reports missing
    /// required parameters, so `@font` and `@font()` behave identically.
    init(parsing range: NSRange?, in ns: NSString, schema: [DirectiveParameter]) {
        let anchor = range ?? NSRange(location: 0, length: 0)
        guard let range, range.length > 0 else {
            self = Self.applyingDefaults(labeled: [:], positional: [], diagnostics: [],
                                         schema: schema, anchor: anchor)
            return
        }

        let positionalSchema = schema.filter { $0.label == nil }
        var labeled: [String: DirectiveValue] = [:]
        var positional: [DirectiveValue] = []
        var diagnostics: [DirectiveDiagnostic] = []

        for argument in Self.splitArguments(range, in: ns) {
            let (labelRange, valueRange) = Self.splitLabel(argument, in: ns)
            let raw = ns.substring(with: valueRange).trimmingCharacters(in: .whitespaces)
            guard !raw.isEmpty else { continue }

            guard let labelRange else {
                let index = positional.count
                guard index < positionalSchema.count else {
                    diagnostics.append(.init(kind: .tooManyPositional, range: argument))
                    continue
                }
                let parameter = positionalSchema[index]
                guard let value = Self.coerce(raw, to: parameter.kind) else {
                    diagnostics.append(.init(
                        kind: .typeMismatch(label: "#\(index)", expected: Self.describe(parameter.kind)),
                        range: valueRange))
                    continue
                }
                positional.append(value)
                continue
            }

            let label = ns.substring(with: labelRange).trimmingCharacters(in: .whitespaces)
            guard let parameter = schema.first(where: { $0.label == label }) else {
                diagnostics.append(.init(kind: .unknownLabel(label), range: argument))
                continue
            }
            guard let value = Self.coerce(raw, to: parameter.kind) else {
                diagnostics.append(.init(
                    kind: .typeMismatch(label: label, expected: Self.describe(parameter.kind)),
                    range: valueRange))
                continue
            }
            labeled[label] = value
        }

        self = Self.applyingDefaults(labeled: labeled, positional: positional,
                                     diagnostics: diagnostics, schema: schema, anchor: range)
    }

    /// Fill unsupplied parameters — labelled and positional alike — from their
    /// defaults, then report whatever required parameter is still missing.
    ///
    /// Positional defaults fill by POSITION, so they only apply to a tail the
    /// call didn't reach: given `(a, b = 2, c)`, `@x(1)` yields `1, 2` and
    /// still reports `#2` missing. A default can't be skipped over, because
    /// there is no syntax for "use the default here but supply the next one" —
    /// so the first positional without a default ends the filling.
    private static func applyingDefaults(
        labeled: [String: DirectiveValue],
        positional: [DirectiveValue],
        diagnostics: [DirectiveDiagnostic],
        schema: [DirectiveParameter],
        anchor: NSRange
    ) -> DirectiveArguments {
        var labeled = labeled
        var positional = positional
        var diagnostics = diagnostics

        for parameter in schema {
            guard let label = parameter.label, labeled[label] == nil else { continue }
            if let fallback = parameter.defaultValue {
                labeled[label] = fallback
            } else if parameter.isRequired {
                diagnostics.append(.init(kind: .missingRequired(label), range: anchor))
            }
        }

        let positionalSchema = schema.filter { $0.label == nil }
        for index in positional.count..<max(positional.count, positionalSchema.count) {
            guard let fallback = positionalSchema[index].defaultValue else { break }
            positional.append(fallback)
        }
        for index in positional.count..<max(positional.count, positionalSchema.count)
        where positionalSchema[index].isRequired {
            diagnostics.append(.init(kind: .missingRequired("#\(index)"), range: anchor))
        }

        return DirectiveArguments(labeled: labeled, positional: positional, diagnostics: diagnostics)
    }

    /// Split on commas at depth 0, respecting quotes and nested brackets, so
    /// `@x(a: "one, two", b: f(1, 2))` is two arguments.
    private static func splitArguments(_ range: NSRange, in ns: NSString) -> [NSRange] {
        var out: [NSRange] = []
        var depth = 0
        var inQuote = false
        var start = range.location
        for k in range.location..<NSMaxRange(range) {
            let c = ns.character(at: k)
            if c == 0x22 { inQuote.toggle(); continue }             // "
            guard !inQuote else { continue }
            switch c {
            case 0x28, 0x5B, 0x7B: depth += 1                       // ( [ {
            case 0x29, 0x5D, 0x7D: depth -= 1                       // ) ] }
            case 0x2C where depth == 0:                             // ,
                out.append(NSRange(location: start, length: k - start))
                start = k + 1
            default: break
            }
        }
        if start < NSMaxRange(range) {
            out.append(NSRange(location: start, length: NSMaxRange(range) - start))
        }
        return out
    }

    /// Split `label: value` at the first depth-0, unquoted colon. A value
    /// containing a colon (`"12:30"`) is safe because quotes suppress the split.
    private static func splitLabel(_ range: NSRange, in ns: NSString) -> (label: NSRange?, value: NSRange) {
        var inQuote = false
        for k in range.location..<NSMaxRange(range) {
            let c = ns.character(at: k)
            if c == 0x22 { inQuote.toggle(); continue }
            if c == 0x3A, !inQuote {                                 // :
                let label = NSRange(location: range.location, length: k - range.location)
                let value = NSRange(location: k + 1, length: NSMaxRange(range) - (k + 1))
                // A leading colon (`:value`) is not a label.
                return label.length > 0 ? (label, value) : (nil, range)
            }
        }
        return (nil, range)
    }

    private static func coerce(_ raw: String, to kind: DirectiveParameter.Kind) -> DirectiveValue? {
        if raw.count >= 2, raw.hasPrefix("\""), raw.hasSuffix("\"") {
            let inner = String(raw.dropFirst().dropLast())
            // A quoted literal is a string; it satisfies .string and .keyword,
            // and nothing else.
            switch kind {
            case .string:                 return .string(inner)
            case .keyword(let allowed):   return allowed.isEmpty || allowed.contains(inner) ? .keyword(inner) : nil
            default:                      return nil
            }
        }
        switch kind {
        case .string:
            return .string(raw)
        case .boolean:
            guard let value = Bool(raw) else { return nil }
            return .boolean(value)
        case .number:
            guard let value = Double(raw) else { return nil }
            return .number(value)
        case .length:
            return parseLength(raw)
        case .keyword(let allowed):
            guard allowed.isEmpty || allowed.contains(raw) else { return nil }
            return .keyword(raw)
        }
    }

    /// `18`, `18pt`, `1.5em`, `50%`
    private static func parseLength(_ raw: String) -> DirectiveValue? {
        for unit in [DirectiveUnit.percent, .em, .point] where raw.hasSuffix(unit.rawValue) {
            guard let value = Double(raw.dropLast(unit.rawValue.count)) else { return nil }
            return .length(value, unit)
        }
        guard let value = Double(raw) else { return nil }
        return .length(value, .none)
    }

    private static func describe(_ kind: DirectiveParameter.Kind) -> String {
        switch kind {
        case .string:               return "string"
        case .number:               return "number"
        case .length:               return "length"
        case .boolean:              return "boolean"
        case .keyword(let allowed): return allowed.isEmpty ? "keyword" : allowed.joined(separator: "|")
        }
    }
}
