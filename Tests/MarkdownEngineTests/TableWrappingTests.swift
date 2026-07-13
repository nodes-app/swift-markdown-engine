//
//  TableWrappingTests.swift
//  MarkdownEngine
//
//  Created by Luca Chen on 13.07.26.
//
//  Obsidian-style table layout: when a table's natural width exceeds the
//  available container width, columns share the available width and cell
//  text WRAPS onto multiple lines instead of growing the table sideways
//  (the horizontal-scroll overlay remains only for tables whose per-column
//  minimums genuinely don't fit).
//

import AppKit
import Foundation
import Testing
@testable import MarkdownEngine

@Suite("Table cell wrapping")
struct TableWrappingTests {

    private let wideSource = """
    | Rechtsform | Gründungskosten | Laufende Kosten |
    |---|---|---|
    | Einzelunternehmen (Kleingewerbe) | 20–60€ Gewerbeanmeldung, jeder Gesellschafter meldet einzeln an | ~0€, nur Steuerberater optional, dreihundert bis achthundert Euro |
    | GbR | Notar und Handelsregister etwa dreihundert bis fünfhundert Euro | Gesellschaftervertrag empfohlen, Anwalt fünfhundert bis eintausendfünfhundert |
    """

    private func render(_ source: String, availableWidth: CGFloat) throws -> NSImage {
        let parsed = try #require(MarkdownStyler.parseTableSource(source))
        let font = NSFont.systemFont(ofSize: 15)
        var ctx = MarkdownStyler.StylingContext(
            nsText: source as NSString,
            tokens: [],
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
        ctx.scopeBounds = nil
        let aqua = try #require(NSAppearance(named: .aqua))
        return MarkdownStyler.tableImage(
            for: source, parsed: parsed, ctx: ctx,
            appearance: aqua, availableWidth: availableWidth
        ).image
    }

    @Test func wideTableWrapsToTheAvailableWidth() throws {
        let image = try render(wideSource, availableWidth: 650)
        #expect(image.size.width <= 650.5)
    }

    @Test func wrappingGrowsTheRowsInstead() throws {
        let narrowRender = try render(wideSource, availableWidth: 650)
        let wideRender = try render(wideSource, availableWidth: 4000)
        // Same content in less width must occupy more height (wrapped lines).
        #expect(narrowRender.size.height > wideRender.size.height + 10)
    }

    // W3C auto layout: columns never shrink below their longest unbreakable
    // word — when even those minimums don't fit, the table stays WIDER than
    // the container and the horizontal-scroll overlay takes over.
    @Test func manyColumnsFallBackToHorizontalScroll() throws {
        let source = """
        | Rechtsformvergleich | Gründungskostenaufstellung | Haftungsbeschränkung | Steuerberaterkosten | Handelsregistereintrag | Stammkapitalanforderung |
        |---|---|---|---|---|---|
        | Einzelunternehmen | Gewerbeanmeldung | unbeschränkt | optional | nein | keines |
        """
        let image = try render(source, availableWidth: 500)
        // The longest-word minimums of six columns can't fit in 500pt — the
        // table must stay wider and scroll horizontally, not crush the columns.
        #expect(image.size.width > 500.5)
    }

    @Test func columnsNeverShrinkBelowTheLongestWord() throws {
        let source = """
        | A | B |
        |---|---|
        | Donaudampfschifffahrtsgesellschaftskapitän | x |
        """
        let image = try render(source, availableWidth: 200)
        // The unbreakable word is wider than 200 — the table must exceed the
        // available width rather than break mid-word.
        #expect(image.size.width > 200.5)
    }

    @Test func smallTableKeepsItsNaturalWidth() throws {
        let source = "| a | b |\n|---|---|\n| 1 | 2 |"
        let image = try render(source, availableWidth: 650)
        // Far below the available width — no artificial stretching.
        #expect(image.size.width < 200)
    }

    @Test func differentAvailableWidthsRenderFreshImages() throws {
        let source = "| wrapcache | test |\n|---|---|\n| some fairly long sentence that needs wrapping in narrow layouts | x |"
        let parsed = try #require(MarkdownStyler.parseTableSource(source))
        let font = NSFont.systemFont(ofSize: 15)
        let ctx = MarkdownStyler.StylingContext(
            nsText: source as NSString,
            tokens: [], codeTokens: [], activeTokenIndices: [],
            baseFont: font, layoutBridge: nil, baseDefaultLineHeight: 18,
            codeBackgroundColor: .windowBackgroundColor, latexMarkerFont: font,
            configuration: .default, wikiLinkIDProvider: { _ in nil }
        )
        let aqua = try #require(NSAppearance(named: .aqua))

        let first = MarkdownStyler.tableImage(for: source, parsed: parsed, ctx: ctx, appearance: aqua, availableWidth: 300)
        let second = MarkdownStyler.tableImage(for: source, parsed: parsed, ctx: ctx, appearance: aqua, availableWidth: 900)
        let third = MarkdownStyler.tableImage(for: source, parsed: parsed, ctx: ctx, appearance: aqua, availableWidth: 300)

        #expect(first.rendered)
        #expect(second.rendered)          // width is part of the cache key
        #expect(!third.rendered)          // same width again → cache hit
        #expect(first.image.size.width != second.image.size.width)
    }
}
