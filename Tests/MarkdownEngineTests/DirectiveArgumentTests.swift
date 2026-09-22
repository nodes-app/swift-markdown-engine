//
//  DirectiveArgumentTests.swift
//  MarkdownEngineTests
//
//  Schema-driven coercion of a directive's argument list: labelled and
//  positional values, units, defaults, and one diagnostic per way a call can
//  be wrong — without ever throwing or partially applying.
//

import AppKit
import Foundation
import Testing
@testable import MarkdownEngine

@Suite("Directives — arguments")
struct DirectiveArgumentTests {

    private let schema: [DirectiveParameter] = [
        .init(label: "size", kind: .length),
        .init(label: "family", kind: .string),
        .init(label: "weight", kind: .keyword(["regular", "bold"]), defaultValue: .keyword("regular")),
        .init(label: "wrap", kind: .boolean),
        .init(label: "count", kind: .number),
    ]

    /// Parse the text between the parens of `@x(…)`.
    private func parse(_ arguments: String, schema: [DirectiveParameter]? = nil) -> DirectiveArguments {
        let text = "(\(arguments))" as NSString
        let range = NSRange(location: 1, length: text.length - 2)
        return DirectiveArguments(parsing: range, in: text, schema: schema ?? self.schema)
    }

    // MARK: - Labelled values

    @Test("labelled values coerce by kind")
    func labelledValues() {
        let args = parse("size: 18, family: \"Menlo\", wrap: true, count: 3")
        #expect(args.number("size") == 18)
        #expect(args.string("family") == "Menlo")
        #expect(args.bool("wrap") == true)
        #expect(args.number("count") == 3)
        #expect(args.isValid)
    }

    @Test("whitespace around labels and values is ignored")
    func toleratesWhitespace() {
        #expect(parse("  size :  18  ").number("size") == 18)
    }

    @Test("an unquoted string value is accepted")
    func unquotedString() {
        #expect(parse("family: Menlo").string("family") == "Menlo")
    }

    // MARK: - Units

    @Test("units parse and resolve", arguments: [
        ("size: 18", 18.0, 18.0),
        ("size: 18pt", 18.0, 18.0),
        ("size: 1.5em", 1.5, 18.0),
        ("size: 50%", 50.0, 6.0),
    ])
    func units(input: String, raw: Double, resolved: Double) {
        let args = parse(input)
        #expect(args.number("size") == raw)
        #expect(args.length("size", relativeTo: 12) == CGFloat(resolved))
    }

    // MARK: - Positional values

    @Test("positional values fill the unlabelled slots in order")
    func positionalValues() {
        let schema: [DirectiveParameter] = [
            .init(label: nil, kind: .keyword([])),
            .init(label: nil, kind: .number),
        ]
        let args = parse("red, 3", schema: schema)
        #expect(args.positional.count == 2)
        #expect(args.positional[0].asString == "red")
        #expect(args.positional[1].asDouble == 3)
    }

    @Test("a surplus positional value is a diagnostic, not a crash")
    func tooManyPositional() {
        let schema: [DirectiveParameter] = [.init(label: nil, kind: .keyword([]))]
        let args = parse("red, blue", schema: schema)
        #expect(args.positional.count == 1)
        #expect(args.diagnostics.contains { $0.kind == .tooManyPositional })
    }

    // MARK: - Splitting

    @Test("a comma inside a quoted value does not split the argument")
    func quotedComma() {
        #expect(parse("family: \"Helvetica, Neue\"").string("family") == "Helvetica, Neue")
    }

    @Test("a colon inside a quoted value is not a label separator")
    func quotedColon() {
        #expect(parse("family: \"12:30\"").string("family") == "12:30")
    }

    @Test("a comma inside nested parens does not split the argument")
    func nestedComma() {
        let args = parse("family: fn(a, b), size: 18")
        #expect(args.number("size") == 18)
    }

    // MARK: - Defaults

    @Test("an unsupplied parameter takes its default")
    func appliesDefaults() {
        #expect(parse("size: 18").string("weight") == "regular")
    }

    @Test("a supplied value beats the default")
    func explicitBeatsDefault() {
        #expect(parse("weight: bold").string("weight") == "bold")
    }

    @Test("an empty argument list still applies defaults")
    func emptyListAppliesDefaults() {
        let args = DirectiveArguments(parsing: nil, in: "" as NSString, schema: schema)
        #expect(args.string("weight") == "regular")
    }

    // MARK: - Diagnostics

    @Test("an unknown label is reported and dropped")
    func unknownLabel() {
        let args = parse("colour: red")
        #expect(args.diagnostics.contains { $0.kind == .unknownLabel("colour") })
        #expect(args["colour"] == nil)
        #expect(!args.isValid)
    }

    @Test("a type mismatch is reported and dropped")
    func typeMismatch() {
        let args = parse("count: notanumber")
        #expect(args.number("count") == nil)
        #expect(args.diagnostics.contains {
            if case .typeMismatch(let label, _) = $0.kind { return label == "count" }
            return false
        })
    }

    @Test("a keyword outside its closed set is a mismatch")
    func keywordOutsideSet() {
        let args = parse("weight: heavy")
        // Falls back to the default rather than passing an unsupported value.
        #expect(args.string("weight") == "regular")
        #expect(!args.isValid)
    }

    @Test("a missing required parameter is reported")
    func missingRequired() {
        let schema: [DirectiveParameter] = [.init(label: "src", kind: .string, isRequired: true)]
        let args = parse("", schema: schema)
        #expect(args.diagnostics.contains { $0.kind == .missingRequired("src") })
    }

    @Test("a missing required positional is reported")
    func missingRequiredPositional() {
        let schema: [DirectiveParameter] = [.init(label: nil, kind: .keyword([]), isRequired: true)]
        #expect(!parse("", schema: schema).isValid)
    }

    @Test("one bad argument does not discard the good ones")
    func partialFailureIsContained() {
        let args = parse("size: 18, colour: red")
        #expect(args.number("size") == 18)
        #expect(!args.isValid)
    }

    // MARK: - End to end

    @Test("arguments read off a parsed directive node")
    func readsFromParsedNode() {
        let text = "@font(size: 1.5em, weight: bold){hi}" as NSString
        let registry = DirectiveRegistry(directives: [SizedDirective()])
        let match = DirectiveScanner.match(text, len: text.length, at: 0, registry: registry)
        let args = DirectiveArguments(parsing: match?.argumentsRange, in: text,
                                      schema: SizedDirective().syntax.parameters)
        #expect(args.length("size", relativeTo: 12) == 18)
        #expect(args.string("weight") == "bold")
        #expect(args.isValid)
    }

    // MARK: - Defaults on positional parameters

    /// A positional parameter carrying a default used to yield nothing:
    /// `applyingDefaults` only filled labelled ones.
    private func positionalString(_ args: DirectiveArguments, _ index: Int) -> String? {
        index < args.positional.count ? args.positional[index].asString : nil
    }

    private var positionalSchema: [DirectiveParameter] {
        [.init(label: nil, kind: .keyword([]), isRequired: true),
         .init(label: nil, kind: .keyword([]), defaultValue: .keyword("medium"))]
    }

    private func arguments(_ source: String, schema: [DirectiveParameter]) -> DirectiveArguments {
        let text = source as NSString
        let registry = DirectiveRegistry(directives: [SelfContainedPair()])
        let match = DirectiveScanner.match(text, len: text.length, at: 0, registry: registry)
        return DirectiveArguments(parsing: match?.argumentsRange, in: text, schema: schema)
    }

    @Test("an unsupplied positional falls back to its default")
    func positionalDefaultApplies() {
        let args = arguments("@pair(star)", schema: positionalSchema)
        #expect(positionalString(args, 0) == "star")
        #expect(positionalString(args, 1) == "medium")
        #expect(args.isValid)
    }

    @Test("a supplied positional wins over its default")
    func positionalDefaultOverridden() {
        let args = arguments("@pair(star, large)", schema: positionalSchema)
        #expect(positionalString(args, 1) == "large")
        #expect(args.isValid)
    }

    @Test("a required positional with no default is still reported missing")
    func requiredPositionalStillMissing() {
        let args = arguments("@pair", schema: positionalSchema)
        #expect(!args.isValid)
        #expect(args.diagnostics.contains { if case .missingRequired("#0") = $0.kind { return true }; return false })
    }

    /// Defaults fill a TAIL. There is no syntax for skipping one, so the first
    /// positional without a default stops the fill and is reported instead.
    @Test("a default cannot be skipped over to reach a later parameter")
    func positionalDefaultsFillOnlyTheTail() {
        let schema: [DirectiveParameter] = [
            .init(label: nil, kind: .keyword([]), isRequired: true),
            .init(label: nil, kind: .keyword([]), defaultValue: .keyword("mid")),
            .init(label: nil, kind: .keyword([]), isRequired: true),
        ]
        let args = arguments("@pair(a)", schema: schema)
        #expect(positionalString(args, 1) == "mid")
        #expect(args.diagnostics.contains { if case .missingRequired("#2") = $0.kind { return true }; return false })
    }

}
