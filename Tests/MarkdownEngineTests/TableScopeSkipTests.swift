//
//  TableScopeSkipTests.swift
//  MarkdownEngine
//
//  Created by Luca Chen on 12.07.26.
//
//  styleTables used to substring + parse/hash EVERY table in the document on
//  every keystroke (and write .spellingState over each one, unclipped by the
//  restyle scope). Out-of-scope inactive tables whose length is unique — no
//  other table can share their content, so no duplicate's occurrence index
//  depends on their hash — are skipped entirely now.
//

import AppKit
import Foundation
import Testing
@testable import MarkdownEngine

@Suite("styleTables scope skip")
struct TableScopeSkipTests {

    private func makeContext(
        text: String,
        scopeBounds: (lo: Int, hi: Int)?,
        activeTokenIndices: Set<Int> = []
    ) -> MarkdownStyler.StylingContext {
        _ = NSApplication.shared   // styleTables reads NSApp.effectiveAppearance
        let tokens = MarkdownTokenizer.parseTokensViaAST(in: text)
        let font = NSFont.systemFont(ofSize: 15)
        var ctx = MarkdownStyler.StylingContext(
            nsText: text as NSString,
            tokens: tokens,
            codeTokens: [],
            activeTokenIndices: activeTokenIndices,
            baseFont: font,
            layoutBridge: nil,
            baseDefaultLineHeight: 18,
            codeBackgroundColor: .windowBackgroundColor,
            latexMarkerFont: font,
            configuration: .default,
            wikiLinkIDProvider: { _ in nil }
        )
        ctx.scopeBounds = scopeBounds
        return ctx
    }

    private func tableRanges(in text: String) -> [NSRange] {
        MarkdownTokenizer.parseTokensViaAST(in: text)
            .filter { $0.kind == .table }
            .map(\.range)
    }

    @Test func outOfScopeUniqueTableEmitsNothing() throws {
        let text = "| alpha | beta |\n|---|---|\n| 1 | 2 |\n\nplain paragraph text here"
        let tableRange = try #require(tableRanges(in: text).first)
        // Scope: only the trailing paragraph, far past the table.
        let scopeLo = NSMaxRange(tableRange) + 2
        let ctx = makeContext(text: text, scopeBounds: (lo: scopeLo, hi: (text as NSString).length))

        let attrs = MarkdownStyler.styleTables(ctx)

        let touchingTable = attrs.filter { NSIntersectionRange($0.range, tableRange).length > 0 }
        #expect(touchingTable.isEmpty)
    }

    @Test func inScopeTableStillEmitsItsAttributes() throws {
        let text = "| alpha | beta |\n|---|---|\n| 1 | 2 |\n\nplain paragraph text here"
        let tableRange = try #require(tableRanges(in: text).first)
        let ctx = makeContext(text: text, scopeBounds: (lo: 0, hi: NSMaxRange(tableRange)))

        let attrs = MarkdownStyler.styleTables(ctx)

        let touchingTable = attrs.filter { NSIntersectionRange($0.range, tableRange).length > 0 }
        #expect(!touchingTable.isEmpty)
        #expect(touchingTable.contains { $0.attributes[.spellingState] as? Int == 0 })
    }

    @Test func outOfScopeDuplicatesSkipWhenNothingRenders() throws {
        // Two IDENTICAL tables, scope far away from both: no table renders
        // this pass, so no occurrence index is consumed — BOTH must be
        // skipped even though they share a length (the 533-similar-tables
        // perf doc showed the unique-length heuristic never firing).
        let table = "| dup | dup |\n|---|---|\n| x | y |"
        let text = table + "\n\nmiddle\n\n" + table + "\n\ntrailing paragraph of prose"
        let ranges = tableRanges(in: text)
        #expect(ranges.count == 2)
        let last = try #require(ranges.last)
        let scopeLo = NSMaxRange(last) + 2
        let ctx = makeContext(text: text, scopeBounds: (lo: scopeLo, hi: (text as NSString).length))

        let attrs = MarkdownStyler.styleTables(ctx)

        for range in ranges {
            let touching = attrs.filter { NSIntersectionRange($0.range, range).length > 0 }
            #expect(touching.isEmpty)
        }
    }

    @Test func duplicateTablesKeepStableOccurrenceBookkeeping() throws {
        // Two IDENTICAL tables; the second is in scope, the first is not.
        // The first must still be hashed (same length ⇒ potential duplicate),
        // so the second's occurrence index stays 1 — observable through its
        // spellingState emission staying on the slow path.
        let table = "| dup | dup |\n|---|---|\n| x | y |"
        let text = table + "\n\nmiddle words\n\n" + table
        let ranges = tableRanges(in: text)
        #expect(ranges.count == 2)
        let second = try #require(ranges.last)
        let ctx = makeContext(text: text, scopeBounds: (lo: second.location, hi: NSMaxRange(second)))

        let attrs = MarkdownStyler.styleTables(ctx)

        // The out-of-scope FIRST duplicate still runs meta (its spellingState
        // emission is the marker for "not skipped").
        let first = try #require(ranges.first)
        let touchingFirst = attrs.filter { NSIntersectionRange($0.range, first).length > 0 }
        #expect(touchingFirst.contains { $0.attributes[.spellingState] as? Int == 0 })
    }
}
