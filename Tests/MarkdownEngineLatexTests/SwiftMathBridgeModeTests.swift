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
    @Test("Display mode typesets block formulas separately from inline cache entries")
    func displayMode() throws {
        _ = NSApplication.shared
        let bridge = SwiftMathBridge()
        let latex = #"\sum_{i=1}^{n} x_i"#
        let inline = try #require(bridge.render(latex: latex, fontSize: 20, theme: .default))
        let display = try #require(bridge.render(latex: latex, mode: .display, fontSize: 20, theme: .default))

        #expect(display.size.height > inline.size.height)
        #expect(display.size.width < inline.size.width)
    }
}
