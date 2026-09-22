//
//  DirectiveParserTests.swift
//  MarkdownEngineTests
//
//  The directive seam's parser half: `@name(args){body}` matches only for
//  registered names at a valid boundary, rejections stay literal text, and the
//  resulting node carries the geometry the styler needs.
//

import AppKit
import Foundation
import Testing
@testable import MarkdownEngine

@Suite("Directives — parsing")
struct DirectiveParserTests {

    // A directive named after a domain label, so the email-boundary test is
    // exercised against a name that WOULD otherwise match.
    private struct WildthinkDirective: MarkdownDirective {
        var syntax: DirectiveSyntax { DirectiveSyntax(name: "wildthink", form: .selfContained) }
    }

    private struct OpaqueDirective: MarkdownDirective {
        var syntax: DirectiveSyntax {
            DirectiveSyntax(name: "raw", form: .container, parsesBody: false)
        }
    }

    private struct EitherDirective: MarkdownDirective {
        var syntax: DirectiveSyntax { DirectiveSyntax(name: "note", form: .either) }
    }

    private struct BackslashDirective: MarkdownDirective {
        var syntax: DirectiveSyntax {
            DirectiveSyntax(name: "bigger", form: .container, marker: "\\")
        }
    }

    private var registry: ExtensionRegistry {
        ExtensionRegistry(extensions: [], directives: DirectiveRegistry(directives: [
            SizedDirective(), TintDirective(), MarkerDirective(),
            WildthinkDirective(), OpaqueDirective(), EitherDirective(),
        ]))
    }

    // MARK: - Helpers

    /// Every directive node in the parse, flattened (directives project as
    /// extension-shaped nodes under the reserved id namespace).
    private func directives(_ text: String, _ registry: ExtensionRegistry? = nil) -> [ExtensionInlineNode] {
        var found: [ExtensionInlineNode] = []
        func walk(_ nodes: [InlineNode]) {
            for node in nodes {
                switch node {
                case .ext(let ext):
                    if DirectiveRegistry.directiveID(forNodeID: ext.extensionID) != nil { found.append(ext) }
                    walk(ext.children)
                case .emphasis(_, _, _, let children), .link(_, _, _, _, let children):
                    walk(children)
                default:
                    break
                }
            }
        }
        walk(InlineParser.parse(text, registry: registry ?? self.registry))
        return found
    }

    private func ids(_ text: String, _ registry: ExtensionRegistry? = nil) -> [String] {
        directives(text, registry).compactMap { DirectiveRegistry.directiveID(forNodeID: $0.extensionID) }
    }

    private func body(_ text: String) -> String? {
        guard let node = directives(text).first else { return nil }
        return (text as NSString).substring(with: node.contentRange)
    }

    // MARK: - Recognition

    @Test("a registered container directive parses")
    func containerParses() {
        #expect(ids("@font(size: 18){hello}") == ["font"])
        #expect(body("@font(size: 18){hello}") == "hello")
    }

    @Test("a registered self-contained directive parses")
    func selfContainedParses() {
        #expect(ids("text @marker more") == ["marker"])
    }

    @Test("without a registered directive, @name stays literal")
    func unregisteredStaysLiteral() {
        #expect(ids("@unknown(size: 18){hello}").isEmpty)
        #expect(ids("@font(size: 18){hello}", .empty).isEmpty)
    }

    @Test("the whole call is claimed, markers plus body")
    func claimsWholeCall() {
        let text = "@font(size: 18){hello}"
        let node = directives(text)[0]
        #expect(node.range == NSRange(location: 0, length: (text as NSString).length))
        #expect((text as NSString).substring(with: node.markers[0]) == "@font(size: 18){")
        #expect((text as NSString).substring(with: node.markers[1]) == "}")
    }

    @Test("a self-contained call carries no markers in Phase 1 — it renders literally")
    func selfContainedHasNoMarkers() {
        #expect(directives("@marker")[0].markers.isEmpty)
    }

    // MARK: - Boundary rule

    @Test("a directive must open at a boundary, not mid-word")
    func rejectsMidWord() {
        #expect(ids("a@marker").isEmpty)
        #expect(ids("word@font(size: 18){x}").isEmpty)
    }

    @Test("an email address never opens a directive")
    func rejectsEmail() {
        // `wildthink` IS registered — only the boundary rule saves this.
        #expect(ids("mail jason@example.com now").isEmpty)
    }

    @Test("a marker run stays literal")
    func rejectsMarkerRun() {
        #expect(ids("@@marker").isEmpty)
    }

    @Test("punctuation and line starts are valid boundaries")
    func acceptsBoundaries() {
        #expect(ids("(@marker)") == ["marker"])
        #expect(ids("line one\n@marker") == ["marker"])
        #expect(ids("> @marker") == ["marker"])
    }

    @Test("markup delimiters are boundaries — a directive can abut emphasis")
    func acceptsMarkupBoundaries() {
        // Regression: an allow-list of "opening punctuation" silently dropped
        // every one of these, because the preceding character is a markup
        // delimiter. Only word characters may reject.
        #expect(ids("*@font(size: 18){x}*") == ["font"])
        #expect(ids("**@font(size: 18){x}**") == ["font"])
        #expect(ids("_@font(size: 18){x}_") == ["font"])
        #expect(ids("- @marker") == ["marker"])
        #expect(ids("1. @marker") == ["marker"])
        #expect(ids("#@marker") == ["marker"])
    }

    @Test("a digit is a word character, so it rejects")
    func rejectsAfterDigit() {
        #expect(ids("v2@marker").isEmpty)
    }

    @Test("an escaped marker stays literal")
    func rejectsEscapedMarker() {
        #expect(ids("\\@marker").isEmpty)
    }

    // MARK: - Form enforcement

    @Test("a container call without a body stays literal")
    func containerNeedsBody() {
        #expect(ids("@font(size: 18)").isEmpty)
    }

    @Test("a self-contained call with a body stays literal")
    func selfContainedRejectsBody() {
        #expect(ids("@marker{x}").isEmpty)
    }

    @Test("an either-form directive accepts both shapes")
    func eitherAcceptsBoth() {
        #expect(ids("@note") == ["note"])
        #expect(ids("@note{body}") == ["note"])
    }

    // MARK: - Delimiter scanning

    @Test("braces nest inside a body")
    func nestedBraces() {
        #expect(body("@font(size: 18){a {b} c}") == "a {b} c")
    }

    @Test("parens nest inside an argument list")
    func nestedParens() {
        #expect(body("@font(size: max(18, 20)){x}") == "x")
    }

    @Test("the scanner treats an escaped brace as body text, not a closer")
    func scannerHonoursEscapedBrace() {
        let text = "@font(size: 18){a \\} b}" as NSString
        let match = DirectiveScanner.match(text, len: text.length, at: 0,
                                           registry: DirectiveRegistry(directives: [SizedDirective()]))
        #expect(match?.bodyRange.map { text.substring(with: $0) } == "a \\} b")
    }

    @Test("in the full parse an interior escape keeps the call literal — as it does for every construct")
    func interiorEscapeStaysLiteral() {
        // The escape pass claims `\}` before the link-family pass runs, and a
        // candidate overlapping a claimed span is rejected. Directives inherit
        // that rule verbatim: `[a \* b](url)` and `==a \* b==` are rejected the
        // same way. The scanner still measures the body correctly (above), so
        // the day escapes stop pre-claiming, directives need no change.
        #expect(ids("@font(size: 18){a \\} b}").isEmpty)
    }

    @Test("a brace inside a quoted argument does not open a body")
    func quotedBraceInArguments() {
        #expect(body("@font(family: \"a{b\"){x}") == "x")
    }

    @Test("an unbalanced call stays literal")
    func unbalancedStaysLiteral() {
        #expect(ids("@font(size: 18{hello}").isEmpty)
        #expect(ids("@font(size: 18){hello").isEmpty)
    }

    @Test("a directive never spans a line break")
    func singleLineOnly() {
        #expect(ids("@font(size: 18){a\nb}").isEmpty)
        #expect(ids("@font(size:\n18){a}").isEmpty)
    }

    // MARK: - Precedence

    @Test("a directive inside a code span never fires — built-ins claim first")
    func codeSpanWins() {
        #expect(ids("`@font(size: 18){x}`").isEmpty)
    }

    @Test("a directive inside inline LaTeX never fires")
    func latexWins() {
        #expect(ids("$@font(size: 18){x}$").isEmpty)
    }

    @Test("a directive inside a link's text still parses")
    func nestsInsideLink() {
        #expect(ids("[see @font(size: 18){this}](url)") == ["font"])
    }

    // MARK: - Body parsing

    @Test("a container body is re-parsed as markdown")
    func bodyIsReparsed() {
        let node = directives("@font(size: 18){**bold**}")[0]
        let hasEmphasis = node.children.contains {
            if case .emphasis = $0 { return true }
            return false
        }
        #expect(hasEmphasis)
    }

    @Test("an opaque directive keeps its body unparsed")
    func opaqueBodyStaysFlat() {
        #expect(directives("@raw{**bold**}")[0].children.isEmpty)
    }

    @Test("directives nest")
    func directivesNest() {
        #expect(ids("@font(size: 18){@color(red){x}}") == ["font", "color"])
    }

    // MARK: - Markers

    @Test("an alternate marker can be registered")
    func alternateMarker() {
        let registry = ExtensionRegistry(extensions: [], directives: DirectiveRegistry(
            directives: [BackslashDirective()]
        ))
        #expect(ids("\\bigger{x}", registry) == ["bigger"])
        // The default marker is inert for a directive that overrode it.
        #expect(ids("@bigger{x}", registry).isEmpty)
    }

    @Test("a multi-scalar marker is rejected at registration, not half-matched")
    func rejectsMultiScalarMarker() {
        // Marker dispatch is one dictionary probe per character on the parse
        // hot path, which requires a single UTF-16 code unit. An emoji marker
        // must drop out at registration rather than matching a lone surrogate.
        struct EmojiMarkerDirective: MarkdownDirective {
            var syntax: DirectiveSyntax {
                DirectiveSyntax(name: "rocket", form: .selfContained, marker: "🚀")
            }
        }
        let registry = DirectiveRegistry(directives: [EmojiMarkerDirective()])
        #expect(registry.isEmpty)
        #expect(ids("🚀rocket", ExtensionRegistry(extensions: [], directives: registry)).isEmpty)
    }

    @Test("markers coexist")
    func markersCoexist() {
        let registry = ExtensionRegistry(extensions: [], directives: DirectiveRegistry(
            directives: [SizedDirective(), BackslashDirective()]
        ))
        #expect(ids("@font(size: 18){a} and \\bigger{b}", registry) == ["font", "bigger"])
    }

    // MARK: - Token projection

    @Test("a directive projects a token, so caret reveal and copy see it")
    func projectsToken() {
        let text = "@font(size: 18){hello}"
        let tokens = MarkdownTokenizer.parseTokensViaAST(in: text, registry: registry)
        let match = tokens.contains { $0.kind == .extensionSpan("directive.font") }
        #expect(match)
    }

    // MARK: - Grammar fingerprint

    @Test("registering a directive changes the grammar fingerprint")
    func fingerprintTracksDirectives() {
        let without = ExtensionRegistry(extensions: [HighlightExtension()])
        let with = ExtensionRegistry(extensions: [HighlightExtension()],
                                     directives: DirectiveRegistry(directives: [SizedDirective()]))
        #expect(without.fingerprint != with.fingerprint)
    }

    @Test("an equal directive set produces an equal fingerprint")
    func fingerprintIsStable() {
        let a = ExtensionRegistry(extensions: [], directives: DirectiveRegistry(directives: [SizedDirective()]))
        let b = ExtensionRegistry(extensions: [], directives: DirectiveRegistry(directives: [SizedDirective()]))
        #expect(a.fingerprint == b.fingerprint)
    }

    @Test("changing the marker changes the fingerprint")
    func fingerprintTracksMarker() {
        let atSign = DirectiveRegistry(directives: [SizedDirective()],
                                       settings: DirectiveRegistrySettings(defaultMarker: "@"))
        let slash = DirectiveRegistry(directives: [SizedDirective()],
                                      settings: DirectiveRegistrySettings(defaultMarker: "/"))
        #expect(atSign.fingerprint != slash.fingerprint)
    }

    @Test("a directive-free registry keeps the fingerprint it had before directives existed")
    func fingerprintUnchangedWithoutDirectives() {
        let registry = ExtensionRegistry(extensions: [HighlightExtension()])
        #expect(!registry.fingerprint.contains("~"))
    }

    @Test("a directive-only registry is not empty")
    func directiveOnlyRegistryIsNotEmpty() {
        let registry = ExtensionRegistry(extensions: [], directives: DirectiveRegistry(directives: [SizedDirective()]))
        #expect(!registry.isEmpty)
        #expect(!registry.fingerprint.isEmpty)
    }

    // MARK: - Known limitation: pre-claimed spans in a body

    /// A body holding a span claimed by an EARLIER pass rejects the whole
    /// directive. Pinned deliberately: this is the documented limitation, and
    /// the follow-up that lifts it should flip these, not delete them.
    @Test("a code span in the body keeps the whole directive literal")
    func codeSpanInBodyRejects() {
        let registry = MarkdownEditorConfiguration(directives: [SizedDirective()]).extensionRegistry
        let nodes = InlineParser.parse("@font(size: 18){a `b` c}", registry: registry)
        #expect(!nodes.contains { if case .ext = $0 { return true }; return false })
    }

    @Test("a backslash escape in the body keeps the whole directive literal")
    func escapeInBodyRejects() {
        let registry = MarkdownEditorConfiguration(directives: [SizedDirective()]).extensionRegistry
        let nodes = InlineParser.parse(#"@font(size: 18){a \* c}"#, registry: registry)
        #expect(!nodes.contains { if case .ext = $0 { return true }; return false })
    }

    /// The limitation is specific to spans claimed BEFORE this pass. Anything
    /// claimed in the same pass or later composes normally, so the rejection
    /// rule is narrower than "no other construct in a body".
    @Test("inline math, links and emphasis all compose inside a body")
    func samePassConstructsInBodyCompose() {
        let registry = MarkdownEditorConfiguration(directives: [SizedDirective()]).extensionRegistry
        for source in ["@font(size: 18){a $x^2$ c}",
                       "@font(size: 18){a [l](u) c}",
                       "@font(size: 18){a *b* c}"] {
            let nodes = InlineParser.parse(source, registry: registry)
            #expect(nodes.contains { if case .ext = $0 { return true }; return false },
                    "expected a directive for \(source)")
        }
    }

}
