//
//  MarkdownEngineDecouplingTests.swift
//  MarkdownEngineTests
//
//  Smoke tests guarding the engine's decoupling boundary. Each test
//  exercises a protocol-default-implementation path so we catch
//  regressions where engine code accidentally re-introduces a
//  dependency on a concrete app type or singleton.
//

import Testing
import Foundation
import AppKit
@testable import MarkdownEngine

@Suite("Markdown engine decoupling")
struct MarkdownEngineDecouplingTests {

    // MARK: NoOp services stay inert

    @Test func noOpResolverReturnsNil() {
        let resolver = NoOpWikiLinkResolver()
        #expect(resolver.resolve(displayName: "Anything", range: NSRange(location: 0, length: 8)) == nil)
    }

    @Test func noOpImageProviderReturnsNil() {
        let provider = NoOpEmbeddedImageProvider()
        let request = EmbeddedImageRequest(name: "nope")
        #expect(provider.image(for: request) == nil)
    }

    @Test func noOpLatexRendererReturnsNil() {
        let renderer = NoOpLatexRenderer()
        let result = renderer.render(latex: "x^2", fontSize: 14, theme: .default)
        #expect(result == nil)
    }

    @Test func plainTextSyntaxHighlighterReturnsNoHighlighting() {
        let highlighter = PlainTextSyntaxHighlighter()
        #expect(highlighter.highlight(code: "let x = 1", language: "swift") == nil)
        #expect(highlighter.appearanceDidChangeNotification == nil)
    }

    // MARK: WikiLinkService roundtrip

    @Test func wikiLinkRoundtripsThroughDisplayAndStorage() {
        let storage = "Before [[Apple|11111111-2222-3333-4444-555555555555]] after"
        let display = WikiLinkService.makeDisplayState(from: storage)
        #expect(display.display == "Before [[Apple]] after")
        #expect(display.metadata.count == 1)
        let firstID = display.metadata.values.first?.id
        #expect(firstID == "11111111-2222-3333-4444-555555555555")
    }

    @Test func wikiLinkServiceLeavesPlainTextUntouched() {
        let storage = "no links here"
        let display = WikiLinkService.makeDisplayState(from: storage)
        #expect(display.display == storage)
        #expect(display.metadata.isEmpty)
    }

    // MARK: Tokenizer remains pure

    @Test func tokenizerParsesBoldEmphasisAndCode() {
        let tokens = MarkdownTokenizer.parseTokens(in: "**bold** *italic* `code`")
        let kinds = tokens.map(\.kind)
        #expect(kinds.contains(.bold))
        #expect(kinds.contains(.italic))
        #expect(kinds.contains(.inlineCode))
    }

    @Test func tokenizerParsesStrikethrough() {
        let tokens = MarkdownTokenizer.parseTokens(in: "before ~~deleted~~ after")
        let strike = tokens.first { $0.kind == .strikethrough }
        #expect(strike != nil)
        #expect(strike?.markerRanges.count == 2)
        #expect(strike?.markerRanges.first?.length == 2)
        #expect(strike?.markerRanges.last?.length == 2)
    }

    @Test func tokenizerDoesNotMatchTripleTilde() {
        let tokens = MarkdownTokenizer.parseTokens(in: "~~~not strikethrough~~~")
        #expect(!tokens.contains { $0.kind == .strikethrough })
    }

    // MARK: Default services container is fully wired with no-ops

    @Test func defaultServicesAreAllNoOps() {
        let services = MarkdownEditorServices.default
        #expect(services.wikiLinks is NoOpWikiLinkResolver)
        #expect(services.images is NoOpEmbeddedImageProvider)
        #expect(services.syntaxHighlighter is PlainTextSyntaxHighlighter)
        #expect(services.latex is NoOpLatexRenderer)
    }

    @Test func defaultBusHasNoNotificationNames() {
        let bus = MarkdownEditorBus.default
        #expect(bus.applyBoldRequest == nil)
        #expect(bus.applyItalicRequest == nil)
        #expect(bus.applyHeadingRequest == nil)
        #expect(bus.selectionBoldDidChange == nil)
        #expect(bus.selectionItalicDidChange == nil)
        #expect(bus.findScrollToRange == nil)
        #expect(bus.findClearHighlights == nil)
    }

    // MARK: Bullet normalization

    @Test func dashBulletNormalizesToCanonicalBullet() {
        let input = "- 你好\nplain line\n- second"
        let output = MarkdownLists.normalizeBulletMarkers(input)
        #expect(output == "\t• 你好\nplain line\n\t• second")
    }

    @Test func tabIndentedDashBulletKeepsItsDepth() {
        let input = "- top\n\t- nested\n\t\t- deeper"
        let output = MarkdownLists.normalizeBulletMarkers(input)
        #expect(output == "\t• top\n\t\t• nested\n\t\t\t• deeper")
    }

    @Test func horizontalRuleIsNotNormalizedAsBullet() {
        let input = "before\n---\nafter"
        let output = MarkdownLists.normalizeBulletMarkers(input)
        #expect(output == input)
    }

    @Test func dashInsideFencedCodeBlockIsLeftAlone() {
        let input = "```\n- not a bullet\n```\n- real bullet"
        let output = MarkdownLists.normalizeBulletMarkers(input)
        #expect(output == "```\n- not a bullet\n```\n\t• real bullet")
    }

    @Test func textWithoutDashBulletsIsReturnedUntouched() {
        let input = "no bullets here\nstill nothing"
        let output = MarkdownLists.normalizeBulletMarkers(input)
        #expect(output == input)
    }

    // MARK: Styler runs end-to-end with defaults

    @Test func stylerProducesAttributesWithDefaultServices() {
        let text = "# Heading\n\n**bold** and `code`"
        let ranges = MarkdownStyler.styleAttributes(
            text: text,
            fontName: NSFont.systemFont(ofSize: 14).fontName,
            fontSize: 14,
            caretLocation: 0,
            activeTokenIndices: [],
            configuration: .default
        )
        #expect(!ranges.isEmpty)
    }
}
