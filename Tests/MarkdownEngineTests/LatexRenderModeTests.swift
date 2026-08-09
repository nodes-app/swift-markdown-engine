//
//  LatexRenderModeTests.swift
//  MarkdownEngineTests
//

import AppKit
import Testing
@testable import MarkdownEngine

@MainActor
@Suite("LaTeX render modes")
struct LatexRenderModeTests {
    private struct LegacyRenderer: LatexRenderer {
        func render(
            latex: String,
            fontSize: CGFloat,
            theme: MarkdownEditorTheme
        ) -> LatexRenderResult? {
            guard latex == #"\sum_{i=1}^{n} x_i"# else { return nil }
            return testLatexResult
        }
    }

    private struct ModeCheckingRenderer: LatexRenderer {
        let expectedLatex: String
        let expectedMode: LatexRenderMode

        func render(
            latex: String,
            fontSize: CGFloat,
            theme: MarkdownEditorTheme
        ) -> LatexRenderResult? {
            nil
        }

        func render(
            latex: String,
            mode: LatexRenderMode,
            fontSize: CGFloat,
            theme: MarkdownEditorTheme
        ) -> LatexRenderResult? {
            guard latex == expectedLatex, mode == expectedMode else { return nil }
            return testLatexResult
        }
    }

    private static func configuration(latex: any LatexRenderer) -> MarkdownEditorConfiguration {
        var configuration = MarkdownEditorConfiguration.default
        configuration.services = MarkdownEditorServices(latex: latex)
        return configuration
    }

    @Test("Existing renderers receive unchanged delimiter-free LaTeX")
    func legacyRendererFallback() {
        let renderer: any LatexRenderer = LegacyRenderer()
        let rendered = renderer.render(
            latex: #"\sum_{i=1}^{n} x_i"#,
            mode: .display,
            fontSize: 14,
            theme: .default
        )

        #expect(rendered != nil)
    }

    @Test("Block and inline styling route their existing token mode")
    func blockAndInlineRouting() {
        _ = NSApplication.shared

        let block = #"\sum_{i=1}^{n} x_i"#
        let blockAttributes = MarkdownStyler.styleAttributes(
            text: "$$\n\(block)\n$$",
            fontName: "Helvetica",
            fontSize: 14,
            caretLocation: 0,
            activeTokenIndices: [],
            configuration: Self.configuration(
                latex: ModeCheckingRenderer(expectedLatex: block, expectedMode: .display)
            )
        )
        #expect(blockAttributes.contains { $0.attributes[.latexImage] != nil })

        let inlineAttributes = MarkdownStyler.styleAttributes(
            text: "before $x$ after",
            fontName: "Helvetica",
            fontSize: 14,
            caretLocation: 0,
            activeTokenIndices: [],
            configuration: Self.configuration(
                latex: ModeCheckingRenderer(expectedLatex: "x", expectedMode: .inline)
            )
        )
        #expect(inlineAttributes.contains { $0.attributes[.latexImage] != nil })
    }

    @Test("Table math is inline")
    func tableRouting() {
        _ = NSApplication.shared
        let configuration = Self.configuration(
            latex: ModeCheckingRenderer(expectedLatex: "x", expectedMode: .inline)
        )
        let cell = MarkdownStyler.formattedCellString(
            "$x$",
            baseFont: .systemFont(ofSize: 14),
            header: false,
            theme: configuration.theme,
            codeBackgroundColor: .clear,
            latex: configuration.services.latex,
            extensions: []
        )

        #expect(cell.string == "\u{FFFC}")
    }

    @Test("A renderer implementing neither overload renders nothing")
    func emptyRendererProducesNoImage() {
        struct EmptyRenderer: LatexRenderer {}

        let renderer: any LatexRenderer = EmptyRenderer()
        #expect(renderer.render(latex: "x", mode: .display, fontSize: 14, theme: .default) == nil)
        #expect(renderer.render(latex: "x", fontSize: 14, theme: .default) == nil)
    }
}

private var testLatexResult: LatexRenderResult {
    let size = CGSize(width: 20, height: 10)
    return LatexRenderResult(image: NSImage(size: size), size: size, baselineOffset: 2)
}
