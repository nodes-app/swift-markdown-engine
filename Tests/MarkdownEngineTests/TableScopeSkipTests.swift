//
//  TableScopeSkipTests.swift
//  MarkdownEngine
//
//  Created by Luca Chen on 12.07.26.
//
//  styleTables used to substring + parse/hash + write .spellingState for
//  EVERY table in the document per keystroke. Now a table only does that
//  work when it renders (inactive + in scope) or shares a length with a
//  rendering table (duplicate-sourceID stability). Typing prose renders no
//  table → all skip. Table sources here are unique so they never warm the
//  shared image cache used by TableImageCacheTests.
//

import AppKit
import Foundation
import SwiftUI
import Testing
@testable import MarkdownEngine

@Suite("styleTables scope skip")
struct TableScopeSkipTests {

    private func makeContext(
        text: String,
        scopeBounds: (lo: Int, hi: Int)?
    ) -> MarkdownStyler.StylingContext {
        _ = NSApplication.shared   // styleTables reads NSApp.effectiveAppearance
        let tokens = MarkdownTokenizer.parseTokensViaAST(in: text)
        let font = NSFont.systemFont(ofSize: 15)
        var ctx = MarkdownStyler.StylingContext(
            nsText: text as NSString,
            tokens: tokens,
            codeTokens: [],
            activeTokenIndices: [],
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

    // Typing prose far from the tables renders none → every table skips.
    @Test func outOfScopeTablesEmitNothing() throws {
        let table = "| kappa | lambda |\n|---|---|\n| 5 | 6 |"
        let text = table + "\n\nmiddle\n\n" + table + "\n\ntrailing paragraph of prose"
        let ranges = tableRanges(in: text)
        #expect(ranges.count == 2)
        let last = try #require(ranges.last)
        let ctx = makeContext(text: text, scopeBounds: (lo: NSMaxRange(last) + 2, hi: (text as NSString).length))

        let attrs = MarkdownStyler.styleTables(ctx)

        for range in ranges {
            #expect(attrs.filter { NSIntersectionRange($0.range, range).length > 0 }.isEmpty)
        }
    }

    // The spell checker must never paint squiggles on table source: the
    // collapsed ~1pt source line under the rendered image shows them as a
    // stray red dot (proven live: `🔴 SPELL … inTable=true APPLIED`).
    @Test @MainActor func spellcheckSuppressionCoversTables() {
        _ = NSApplication.shared
        let text = "| alpha | beta |\n|---|---|\n| Setapp | 2 |\n\nprose"
        let coordinator = NativeTextViewCoordinator(
            text: .constant(text),
            fontName: "SF Pro Text",
            fontSize: 14,
            isWikiLinkActive: .constant(false),
            onLinkClick: nil,
            onInlineSelectionChange: nil
        )
        let typoRange = (text as NSString).range(of: "Setapp")

        #expect(coordinator.isInsideSpellcheckSuppressedToken(range: typoRange, in: text))
        #expect(coordinator.isInsideSpellcheckSuppressedToken(location: typoRange.location, in: text))
        let proseRange = (text as NSString).range(of: "prose")
        #expect(!coordinator.isInsideSpellcheckSuppressedToken(range: proseRange, in: text))
    }

    // A table inside the restyle scope must still emit its attributes.
    @Test func inScopeTableStillEmitsItsAttributes() throws {
        let text = "| mu | nu |\n|---|---|\n| 7 | 8 |\n\nplain paragraph text here"
        let tableRange = try #require(tableRanges(in: text).first)
        let ctx = makeContext(text: text, scopeBounds: (lo: 0, hi: NSMaxRange(tableRange)))

        let attrs = MarkdownStyler.styleTables(ctx)

        let touching = attrs.filter { NSIntersectionRange($0.range, tableRange).length > 0 }
        #expect(!touching.isEmpty)
        #expect(touching.contains { $0.attributes[.spellingState] as? Int == 0 })
    }
}
