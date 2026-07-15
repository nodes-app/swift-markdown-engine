//
//  TableImageCacheTests.swift
//  MarkdownEngine
//
//  Created by Luca Chen on 07.07.26.
//

import AppKit
import Foundation
import Testing
@testable import MarkdownEngine

@Suite("Table image cache")
struct TableImageCacheTests {

    private func makeContext(
        for source: String,
        configuration: MarkdownEditorConfiguration = .default
    ) -> MarkdownStyler.StylingContext {
        let font = NSFont.systemFont(ofSize: 15)
        return MarkdownStyler.StylingContext(
            nsText: source as NSString,
            tokens: [],
            codeTokens: [],
            activeTokenIndices: [],
            baseFont: font,
            layoutBridge: nil,
            baseDefaultLineHeight: 18,
            codeBackgroundColor: .windowBackgroundColor,
            latexMarkerFont: font,
            configuration: configuration,
            wikiLinkIDProvider: { _ in nil }
        )
    }

    @Test func differentExtensionRegistriesDoNotShareCacheEntries() throws {
        let source = "| a | b |\n|---|---|\n| ==x== | 2 |"
        let parsed = try #require(MarkdownStyler.parseTableSource(source))
        let aqua = try #require(NSAppearance(named: .aqua))
        var extConfig = MarkdownEditorConfiguration.default
        extConfig.extensions = [HighlightExtension()]
        // Render under the extension config first, then under the plain config:
        // the second call must be a fresh render, never the cached image (the
        // cell would show a highlight the plain config doesn't have).
        _ = MarkdownStyler.tableImage(
            for: source, parsed: parsed,
            ctx: makeContext(for: source, configuration: extConfig),
            appearance: aqua, availableWidth: 2000)
        let plain = MarkdownStyler.tableImage(
            for: source, parsed: parsed,
            ctx: makeContext(for: source),
            appearance: aqua, availableWidth: 2000)
        #expect(plain.rendered, "plain-config table must not reuse the extension-config image")
    }

    @Test func secondRequestIsServedFromCache() throws {
        let source = "| alpha | beta |\n|---|---|\n| 1 | 2 |"
        let parsed = try #require(MarkdownStyler.parseTableSource(source))
        let ctx = makeContext(for: source)
        let aqua = try #require(NSAppearance(named: .aqua))

        let first = MarkdownStyler.tableImage(for: source, parsed: parsed, ctx: ctx, appearance: aqua, availableWidth: 2000)
        let second = MarkdownStyler.tableImage(for: source, parsed: parsed, ctx: ctx, appearance: aqua, availableWidth: 2000)

        #expect(first.rendered)
        #expect(!second.rendered)
        #expect(first.image === second.image)
    }

    @Test func appearanceChangeRendersFresh() throws {
        let source = "| gamma | delta |\n|---|---|\n| 3 | 4 |"
        let parsed = try #require(MarkdownStyler.parseTableSource(source))
        let ctx = makeContext(for: source)
        let aqua = try #require(NSAppearance(named: .aqua))
        let dark = try #require(NSAppearance(named: .darkAqua))

        _ = MarkdownStyler.tableImage(for: source, parsed: parsed, ctx: ctx, appearance: aqua, availableWidth: 2000)
        let darkResult = MarkdownStyler.tableImage(for: source, parsed: parsed, ctx: ctx, appearance: dark, availableWidth: 2000)

        #expect(darkResult.rendered)
    }

    // The key must cover every color renderTable draws with — mutedText paints
    // the border and header fill, so a theme differing only there is a miss.
    @Test func mutedTextChangeRendersFresh() throws {
        let source = "| epsilon | zeta |\n|---|---|\n| 7 | 8 |"
        let parsed = try #require(MarkdownStyler.parseTableSource(source))
        let aqua = try #require(NSAppearance(named: .aqua))

        var themed = MarkdownEditorConfiguration.default
        themed.theme.mutedText = .systemPink

        _ = MarkdownStyler.tableImage(for: source, parsed: parsed, ctx: makeContext(for: source), appearance: aqua, availableWidth: 2000)
        let repainted = MarkdownStyler.tableImage(
            for: source, parsed: parsed,
            ctx: makeContext(for: source, configuration: themed), appearance: aqua, availableWidth: 2000
        )

        #expect(repainted.rendered)
    }

    // NSColor descriptions are not identities: two named dynamic colors sharing
    // a name describe identically. The key must use resolved components instead.
    @Test func sameNamedDynamicColorsDoNotCollide() throws {
        let source = "| eta | theta |\n|---|---|\n| 9 | 10 |"
        let parsed = try #require(MarkdownStyler.parseTableSource(source))
        let aqua = try #require(NSAppearance(named: .aqua))

        var blueBody = MarkdownEditorConfiguration.default
        blueBody.theme.bodyText = NSColor(name: "body") { _ in .systemBlue }
        var redBody = MarkdownEditorConfiguration.default
        redBody.theme.bodyText = NSColor(name: "body") { _ in .systemRed }

        _ = MarkdownStyler.tableImage(
            for: source, parsed: parsed,
            ctx: makeContext(for: source, configuration: blueBody), appearance: aqua, availableWidth: 2000
        )
        let redRender = MarkdownStyler.tableImage(
            for: source, parsed: parsed,
            ctx: makeContext(for: source, configuration: redBody), appearance: aqua, availableWidth: 2000
        )

        #expect(redRender.rendered)
    }
}
