//
//  SwiftMathBridgeModeTests.swift
//  MarkdownEngineLatexTests
//

import AppKit
import Testing
import MarkdownEngine
import MarkdownEngineLatex

@MainActor
@Suite("SwiftMath render modes")
struct SwiftMathBridgeModeTests {
    @Test("Mode-less rendering keeps the historical text style")
    func modeLessMatchesInline() throws {
        _ = NSApplication.shared
        let bridge = SwiftMathBridge()
        let latex = #"\sum_{i=1}^{n} x_i"#
        let implicit = try #require(bridge.render(latex: latex, fontSize: 20, theme: .default))
        let inline = try #require(bridge.render(latex: latex, mode: .inline, fontSize: 20, theme: .default))

        #expect(implicit.size == inline.size)
        #expect(implicit.baselineOffset == inline.baselineOffset)
    }

    @Test("Display mode typesets limits above and below the operator")
    func displayIsTallerThanInline() throws {
        _ = NSApplication.shared
        let bridge = SwiftMathBridge()
        let latex = #"\sum_{i=1}^{n} x_i"#
        let inline = try #require(bridge.render(latex: latex, mode: .inline, fontSize: 20, theme: .default))
        let display = try #require(bridge.render(latex: latex, mode: .display, fontSize: 20, theme: .default))

        // Limits move from beside the operator to above/below it: taller, narrower.
        #expect(display.size.height > inline.size.height)
        #expect(display.size.width < inline.size.width)
    }

    @Test("Mode participates in the cache key")
    func modeSeparatesCacheEntries() throws {
        _ = NSApplication.shared
        let bridge = SwiftMathBridge()
        let latex = #"\int_{0}^{1} f(x)\,dx"#
        // Warm the cache in inline mode first; a mode-blind key would then serve
        // the inline image back for the display request.
        let inline = try #require(bridge.render(latex: latex, mode: .inline, fontSize: 20, theme: .default))
        let display = try #require(bridge.render(latex: latex, mode: .display, fontSize: 20, theme: .default))

        #expect(display.size != inline.size)
    }
}
