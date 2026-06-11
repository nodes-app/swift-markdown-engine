//
//  ContentView.swift
//  MarkdownEngine
//
//  Created by Nicolas von Mallinckrodt on 29.04.26.
//

import SwiftUI
import MarkdownEngine

// Optional bridge products. Each is independent — drop either of these
// `#if` blocks (or remove the matching Swift Package product dependency
// from the Xcode project) and the demo still compiles. Code blocks fall
// back to plain monospace; LaTeX falls back to its raw `$…$` source.
#if canImport(MarkdownEngineCodeBlocks)
import MarkdownEngineCodeBlocks
#endif
#if canImport(MarkdownEngineLatex)
import MarkdownEngineLatex
#endif

struct ContentView: View {
    @State private var text: String = sampleMarkdown
    @State private var showHeader = false
    @State private var headerExpanded = true

    var body: some View {
        NativeTextViewWrapper(
            text: $text,
            configuration: configuration,
            header: showHeader ? AnyView(demoHeader) : nil,
            headerCollapsedHeight: 40,
            headerExpanded: headerExpanded
        )
        .toolbar {
            ToolbarItemGroup {
                // Scroll-away header: an embedder-supplied SwiftUI view hosted
                // above the body that scrolls with it. "Expanded" animates
                // between the full content height and `headerCollapsedHeight`
                // (the top row stays visible; the rows below clip away).
                Toggle("Header", isOn: $showHeader)
                Toggle("Expanded", isOn: $headerExpanded)
                    .disabled(!showHeader)
            }
        }
    }

    /// Sample scroll-away header: a fixed top row (kept visible when collapsed)
    /// plus detail rows that reveal/hide with the `headerExpanded` toggle.
    private var demoHeader: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Scroll-away header").font(.headline)
                Spacer()
            }
            .frame(height: 40)   // == headerCollapsedHeight: the always-visible row

            VStack(alignment: .leading, spacing: 6) {
                Text("These rows clip away when the header collapses.")
                Text("The header scrolls with the document body and stays fully interactive.")
                    .foregroundStyle(.secondary)
            }
            .font(.callout)
            .padding(.bottom, 12)
        }
        .padding(.horizontal, 16)
    }

    /// The engine talks to your app through service protocols. Two of them —
    /// `SyntaxHighlighter` and `LatexRenderer` — render the code-block and
    /// LaTeX visuals. The base `MarkdownEngine` ships no-op defaults
    /// (plain monospace, raw `$…$`); the optional `MarkdownEngineCodeBlocks`
    /// and `MarkdownEngineLatex` products ship ready-made bridges backed by
    /// HighlighterSwift and SwiftMath respectively.
    ///
    /// This demo opportunistically plugs in whichever bridges are linked,
    /// so you can see exactly what each one adds.
    private var configuration: MarkdownEditorConfiguration {
        var config = MarkdownEditorConfiguration.default

        #if canImport(MarkdownEngineCodeBlocks)
        // Syntax highlighting for fenced code blocks. Auto-switches between
        // `atom-one-light` and `atom-one-dark` with system appearance.
        config.services.syntaxHighlighter = HighlighterSwiftBridge()
        #endif

        #if canImport(MarkdownEngineLatex)
        // LaTeX rendering for `$inline$` and `$$block$$` math. Uses the
        // Latin Modern math font and tints formulas to match the theme.
        config.services.latex = SwiftMathBridge()
        #endif

        return config
    }
}

/// Builds the demo markdown shown when the editor first loads.
///
/// The text is composed from a fixed header/footer plus three feature
/// sections — inline formatting, block math, and code — that swap between
/// a full showcase and a short "feature unavailable" note depending on
/// which optional bridge products are linked.
///
/// When a bridge is missing, the fallback links to the README section
/// that explains how to enable that feature in your own app.
private var sampleMarkdown: String {
    [
        markdownHeader,
        inlineFormattingSection,
        latexSection,
        codeSection,
        markdownFooter,
    ].joined(separator: "\n\n")
}

private let markdownHeader = """
# MarkdownEngine

A native macOS Markdown editor built on **TextKit 2**, bridged to SwiftUI — brought to you by [nodes-web.com](https://nodes-web.com).

Edit this text live. Formatting updates as you type.

---
"""

/// Inline formatting demo. Drops the inline-LaTeX example sentence when
/// the LaTeX bridge isn't linked, so the reader doesn't see raw `$…$`.
private var inlineFormattingSection: String {
    #if canImport(MarkdownEngineLatex)
    return #"""
    ## Inline formatting

    Mix **bold**, *italic*, and ***both at once***. Reach for `inline code` when a short snippet helps. Inline math fits naturally in prose — the Pythagorean identity says $a^2 + b^2 = c^2$, and Euler's identity famously claims $e^{i\pi} + 1 = 0$.
    """#
    #else
    return """
    ## Inline formatting

    Mix **bold**, *italic*, and ***both at once***. Reach for `inline code` when a short snippet helps.
    """
    #endif
}

/// Block LaTeX demo when the `MarkdownEngineLatex` bridge is linked;
/// otherwise a short note pointing to the README section that explains
/// how to enable LaTeX rendering.
private var latexSection: String {
    #if canImport(MarkdownEngineLatex)
    return #"""
    ## Block math

    $$
    \int_{-\infty}^{\infty} e^{-x^2}\,dx = \sqrt{\pi}
    $$

    $$
    \frac{\partial}{\partial t}\Psi(\mathbf{r}, t) = -\frac{i}{\hbar}\hat{H}\,\Psi(\mathbf{r}, t)
    $$
    """#
    #else
    return """
    ## LaTeX

    LaTeX (`$inline$` and `$$block$$`) is parsed but not rendered without the optional `MarkdownEngineLatex` product. See [LaTeX Rendering](https://github.com/nodes-app/swift-markdown-engine#latex-rendering) in the README to wire it up.
    """
    #endif
}

/// Fenced code-block demo when the `MarkdownEngineCodeBlocks` bridge is
/// linked; otherwise a plain monospace example and a link to the
/// README's Code Blocks section.
private var codeSection: String {
    #if canImport(MarkdownEngineCodeBlocks)
    return #"""
    ## Code

    Swift, with syntax highlighting:

    ```swift
    import SwiftUI
    import MarkdownEngine

    struct Editor: View {
        @State private var text = "# Hello"

        var body: some View {
            NativeTextViewWrapper(text: $text)
                .frame(minWidth: 640, minHeight: 480)
        }
    }
    ```

    And a little JSON:

    ```json
    {
      "engine": "MarkdownEngine",
      "features": ["latex", "code", "wiki-links"],
      "version": 1.0
    }
    ```
    """#
    #else
    return #"""
    ## Code

    Fenced code blocks render as plain monospace without the optional `MarkdownEngineCodeBlocks` product. See [Code Blocks](https://github.com/nodes-app/swift-markdown-engine#code-blocks) in the README for syntax-highlighted output:

    ```swift
    let greeting = "Hello, world!"
    ```
    """#
    #endif
}

private let markdownFooter = """
---

Built by [nodes-web.com](https://nodes-web.com).
"""
