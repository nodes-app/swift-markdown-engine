//
//  DirectiveCompletionTests.swift
//  MarkdownEngineTests
//
//  Phase 4 — what the caret is trying to complete.
//
//  The scanner's job is the opposite of the parser's: it must succeed on text
//  the parser REJECTS, because `@gly` and `@glyph(sta` are what a directive
//  looks like while you're still typing it. So these tests are mostly about
//  incomplete input, plus the places a picker must stay shut.
//

import AppKit
import Foundation
import Testing
@testable import MarkdownEngine

@Suite("Directives — completion context")
struct DirectiveCompletionTests {

    private let directives: [any MarkdownDirective] = [
        FontDirective(), ColorDirective(), GlyphDirective(), RegionDirective(), MarkerDirective(),
    ]

    private var registry: DirectiveRegistry { DirectiveRegistry(directives: directives) }

    /// Context at the caret marked by `|` in `text`.
    private func context(_ text: String) -> DirectiveCompletionContext? {
        let caret = (text as NSString).range(of: "|").location
        let stripped = text.replacingOccurrences(of: "|", with: "") as NSString
        return DirectiveCompletionScanner.context(
            in: stripped, caret: caret, registry: registry,
            directives: directives, settings: .default
        )
    }

    private func titles(_ text: String) -> [String] {
        context(text)?.candidates.map(\.title) ?? []
    }

    // MARK: - Name completion

    @Test("a bare marker offers nothing")
    func bareMarkerOffersNothing() {
        // A context here would capture Enter as "confirm" in ordinary prose
        // any time a marker precedes it (`Ping @` then a plain newline) —
        // wait for at least one typed character.
        #expect(context("@|") == nil)
    }

    @Test("one typed character offers every matching directive")
    func oneCharacterOffersAll() {
        let candidates = titles("@f|")
        #expect(candidates.contains("font"))
    }

    @Test("an exact match to a directive with no required arguments closes the picker")
    func exactFinishedMatchOffersNothing() {
        // `marker` is self-contained with no parameters — fully typing its
        // name is a finished call, not something still being completed.
        #expect(context("@marker|") == nil)
    }

    @Test("an exact match to a directive that still needs arguments stays open")
    func exactUnfinishedMatchStaysOpen() {
        // `glyph` requires a positional argument, so the name alone isn't a
        // finished call yet.
        #expect(context("@glyph|") != nil)
    }

    @Test("a partial name filters")
    func partialNameFilters() {
        #expect(titles("@reg|") == ["region"])
        #expect(titles("@gly|") == ["glyph"])
    }

    @Test("a name match outranks a keyword-only match")
    func nameMatchOutranksKeyword() {
        // `fo` hits `font` by name and `color` by its "foreground" keyword.
        // Both belong in the list; the name match must lead.
        let candidates = titles("@fo|")
        #expect(candidates.first == "font")
        #expect(candidates.contains("color"))
    }

    @Test("keywords match too, and rank below name matches")
    func keywordsMatch() {
        // `country` is a keyword of `region`, not a directive name.
        #expect(titles("@country|") == ["region"])
    }

    @Test("the name context replaces from the marker to the caret")
    func nameReplacementRange() {
        let text = "hello @fo"
        let found = DirectiveCompletionScanner.context(
            in: text as NSString, caret: (text as NSString).length,
            registry: registry, directives: directives, settings: .default
        )
        #expect(found?.replacementRange == NSRange(location: 6, length: 3))
        #expect(found?.prefix == "fo")
    }

    @Test("a name candidate inserts its snippet and reports the caret slot")
    func nameCandidateSnippet() {
        let item = context("@fo|")?.candidates.first
        #expect(item?.insertion == "@font(size: ){}")
        #expect(item?.caretOffset == 12)   // just after "size: "
    }

    @Test("an unmatched name offers nothing")
    func unmatchedNameOffersNothing() {
        #expect(context("@zzz|") == nil)
    }

    // MARK: - Value completion

    @Test("a positional argument offers the directive's values")
    func positionalValues() {
        let candidates = titles("@glyph(sta|")
        #expect(candidates.contains("star.fill"))
        #expect(candidates.allSatisfy { $0.hasPrefix("sta") })
    }

    @Test("an empty argument offers the unfiltered list")
    func emptyArgumentOffersAll() {
        #expect(!titles("@glyph(|").isEmpty)
    }

    @Test("a labelled argument resolves to its own parameter")
    func labelledArgument() {
        let found = context("@glyph(star.fill, color: gr|")
        #expect(found?.candidates.map(\.title) == ["green"])
        if case .argument(let label, let index) = found?.kind {
            #expect(label == "color")
            #expect(index == 1)
        } else {
            Issue.record("expected an argument context")
        }
    }

    @Test("the value context replaces just the typed value")
    func valueReplacementRange() {
        let text = "@glyph(star.fill, color: gr"
        let found = DirectiveCompletionScanner.context(
            in: text as NSString, caret: (text as NSString).length,
            registry: registry, directives: directives, settings: .default
        )
        // "gr" only — not the label, not the preceding argument.
        #expect(found?.replacementRange == NSRange(location: 25, length: 2))
        #expect(found?.prefix == "gr")
    }

    @Test("a name replacement covers text after the caret too")
    func nameReplacementCoversTail() {
        // Caret mid-identifier in an existing name: a pick must replace the
        // WHOLE name, or the characters after the caret ("nt") survive past
        // the inserted snippet.
        let found = context("@fo|nt")
        #expect(found?.replacementRange == NSRange(location: 0, length: 5))
        #expect(found?.prefix == "fo")
    }

    @Test("a value replacement covers text after the caret too")
    func valueReplacementCoversTail() {
        // Caret mid-value inside an existing call: a pick must replace the
        // whole argument value, or the trailing characters ("r") survive
        // past the inserted candidate.
        let found = context("@glyph(sta|r)")
        #expect(found?.replacementRange == NSRange(location: 7, length: 4))
        #expect(found?.prefix == "sta")
    }

    @Test("a closed keyword set completes from the schema alone")
    func schemaDerivedValues() {
        // FontDirective declares weight: .keyword(["regular", "bold"]) and
        // implements no valueCompletions of its own.
        #expect(titles("@font(weight: b|") == ["bold"])
    }

    @Test("a dynamic domain matches on more than one field")
    func flagMatchesCodeAndName() {
        #expect(titles("@region(JP|").contains("JP"))
        #expect(titles("@region(jap|").contains("JP"))
    }

    @Test("a candidate previews the result it will produce")
    func flagCandidatePreviews() {
        let item = context("@region(JP|")?.candidates.first { $0.title == "JP" }
        #expect(item?.detail == "🇯🇵")
        #expect(item?.insertion == "JP")
    }

    @Test("a parameter with no enumerable domain offers nothing")
    func openDomainOffersNothing() {
        // `size` is a length — no list to offer.
        #expect(context("@font(size: 1|") == nil)
    }

    @Test("an unregistered directive's arguments offer nothing")
    func unregisteredArgumentsOfferNothing() {
        #expect(context("@nope(x|") == nil)
    }

    // MARK: - Where the picker must stay shut

    @Test("a closed call offers nothing")
    func closedCallOffersNothing() {
        #expect(context("@glyph(star.fill)| ") == nil)
        #expect(context("@glyph(star.fill) and then|") == nil)
    }

    @Test("the caret inside a container body is not completing arguments")
    func bodyIsNotArguments() {
        #expect(context("@font(size: 18){hel|") == nil)
    }

    @Test("an email address does not open a picker")
    func emailOffersNothing() {
        #expect(context("jason@example|") == nil)
    }

    @Test("a marker run does not open a picker")
    func markerRunOffersNothing() {
        #expect(context("@@fo|") == nil)
    }

    @Test("an escaped marker does not open a picker")
    func escapedMarkerOffersNothing() {
        #expect(context("\\@fo|") == nil)
    }

    @Test("the scan stops at the line start")
    func scanStopsAtLineStart() {
        #expect(context("@font\nplain text|") == nil)
    }

    @Test("a bare marker with no directives registered offers nothing")
    func emptyRegistryOffersNothing() {
        let found = DirectiveCompletionScanner.context(
            in: "@" as NSString, caret: 1, registry: .empty,
            directives: [], settings: .default
        )
        #expect(found == nil)
    }

    @Test("markup delimiters before the marker still open a picker")
    func markupBoundaryOpensPicker() {
        #expect(titles("*@reg|") == ["region"])
        #expect(titles("- @reg|") == ["region"])
        #expect(titles("**@reg|") == ["region"])
    }

    // MARK: - Commit requests

    @Test("a request built from a context and item carries the range and caret")
    func requestFromContextAndItem() {
        let found = context("@fo|")!
        let item = found.candidates[0]
        let request = DirectiveCompletionRequest(documentId: "doc", context: found, item: item)
        #expect(request.replacementRange == found.replacementRange)
        #expect(request.insertion == "@font(size: ){}")
        #expect(request.caretOffset == 12)
    }
}
