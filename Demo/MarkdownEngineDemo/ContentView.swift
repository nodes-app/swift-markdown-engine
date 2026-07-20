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

    // Engine modes, flipped live from the toolbar.
    @State private var isReadOnly = false
    @State private var showRawSource = false
    @State private var useReadingColumn = false

    // Base font size; all relative sizing (headings, code, math) tracks it.
    @State private var fontSize: CGFloat = 16

    // Scroll-away header demo.
    @State private var showHeader = false
    @State private var headerExpanded = true

    var body: some View {
        NativeTextViewWrapper(
            text: $text,
            configuration: configuration,
            fontSize: fontSize,
            isEditable: !isReadOnly,
            placeholder: NSAttributedString(
                string: "Empty document — start typing, markdown styles live…",
                attributes: [
                    .font: NSFont.systemFont(ofSize: fontSize),
                    .foregroundColor: NSColor.secondaryLabelColor,
                ]
            ),
            header: showHeader ? AnyView(demoHeader) : nil,
            headerCollapsedHeight: 40,
            headerExpanded: headerExpanded
        )
        // `readingWidth` is applied when the underlying NSView is built, so
        // flipping the reading column recreates the editor via `.id`. The
        // `text` binding survives; scroll position resets — fine for a demo.
        .id(useReadingColumn)
        .toolbar {
            ToolbarItemGroup {
                Toggle(isOn: $isReadOnly) {
                    Label("Read-only", systemImage: isReadOnly ? "lock" : "lock.open")
                }
                .help("Read-only: the styled document stays scrollable and selectable, editing is off")

                Toggle(isOn: $showRawSource) {
                    Label("Raw source", systemImage: "chevron.left.forwardslash.chevron.right")
                }
                .help("Raw markdown source: no styling, no syntax hiding")

                Toggle(isOn: $useReadingColumn) {
                    Label("Reading column", systemImage: "arrow.right.and.line.vertical.and.arrow.left")
                }
                .help("Centered fixed-width reading column — wide tables still break out to full width")

                ControlGroup {
                    Button {
                        fontSize = max(10, fontSize - 2)
                    } label: {
                        Label("Smaller text", systemImage: "textformat.size.smaller")
                    }
                    .disabled(fontSize <= 10)

                    Button {
                        fontSize = min(28, fontSize + 2)
                    } label: {
                        Label("Larger text", systemImage: "textformat.size.larger")
                    }
                    .disabled(fontSize >= 28)
                }
                .help("Base font size — headings, code, and math scale relative to it")

                Menu {
                    Toggle("Show header", isOn: $showHeader)
                    Toggle("Expanded", isOn: $headerExpanded)
                        .disabled(!showHeader)
                } label: {
                    Label("Header", systemImage: "rectangle.topthird.inset.filled")
                }
                .help("Scroll-away header: an embedder-supplied SwiftUI view hosted above the document")
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

        // Opt-in constructs beyond pure markdown. The core engine no longer
        // knows `==highlight==` or `~~strikethrough~~` — they are extensions
        // you register. Unregistered syntax stays literal text.
        config.extensions = [HighlightExtension(), StrikethroughExtension()]

        // Toolbar-driven modes.
        config.rawSourceMode = showRawSource
        config.readingWidth = useReadingColumn ? 620 : nil

        return config
    }
}

/// Builds the demo markdown shown when the editor first loads.
///
/// The text is composed from a fixed header/footer plus feature sections.
/// Three of them — inline formatting, block math, and code — swap between
/// a full showcase and a short "feature unavailable" note depending on
/// which optional bridge products are linked.
///
/// When a bridge is missing, the fallback links to the README section
/// that explains how to enable that feature in your own app.
private var sampleMarkdown: String {
    [
        markdownHeader,
        inlineFormattingSection,
        blocksSection,
        taskListSection,
        extensionSection,
        tableSection,
        latexSection,
        codeSection,
        markdownFooter,
    ].joined(separator: "\n\n")
}

/// Blockquote + list demo: quotes keep inline styling; lists auto-continue
/// on Return, renumber, and change nesting with Tab / Shift-Tab.
private let blocksSection = """
## Blockquotes & lists

> Blockquotes keep full **inline** styling — and quote markers hide like every other marker.

Lists auto-continue on Return; Tab and Shift-Tab move the nesting level:

- Unordered lists
  - nest two spaces per level
    - up to three levels deep

1. Ordered lists renumber as you edit
2. and auto-continue too
"""

/// Task-list demo: click a checkbox to toggle it. The glyphs are SF Symbols;
/// embedders can swap them via `TaskCheckboxStyle` (`config.taskCheckbox`).
private let taskListSection = """
## Task lists

- [x] Draw checkboxes as SF Symbols
- [ ] Click a box to toggle it
- [ ] Ship it
"""

/// Extension seam demo: `==highlight==` and `~~strikethrough~~` are NOT part
/// of the core grammar anymore — they're supplied by the opt-in
/// `HighlightExtension` and `StrikethroughExtension` registered above.
private let extensionSection = """
## Extensions

The engine core parses pure markdown; extra constructs are opt-in extensions. \
This ==highlighted text== comes from `HighlightExtension`, and this \
~~struck-through text~~ from `StrikethroughExtension`. Unregistered, the exact \
same characters would stay literal markdown. Nesting works too: \
==with *italic* inside== and ~~also *nested*~~.
"""

/// Table layout demo: the first table's cells WRAP to the available width
/// (CSS auto-layout style); the second has so many columns that even the
/// longest-word minimums don't fit — it stays wide and scrolls horizontally.
private let tableSection = """
## Tables

Cells wrap to the available width:

| Novel | Opening line |
|---|---|
| Der Zauberberg (1924) | "Ein einfacher junger Mensch reiste im Hochsommer von Hamburg, seiner Vaterstadt, nach Davos-Platz im Graubündischen." |
| The Master and Margarita (1966–67) | "At the sunset hour of one warm spring day two men were to be seen at Patriarch's Ponds." (trans. Michael Glenny) |
| The Picture of Dorian Gray (1890) | "The studio was filled with the rich odour of roses, and when the light summer wind stirred amidst the trees of the garden, there came through the open door the heavy scent of the lilac, or the more delicate perfume of the pink-flowering thorn." |

Too many columns → horizontal scroll instead of crushed cells:

| Movement | Landmark novel | Narrative signature | Characteristic preoccupations | Philosophical undercurrents | Contemporaneous reception | Posthumous reputation | Author | Structural device | Central symbol | Typical setting | Enduring influence |
|---|---|---|---|---|---|---|---|---|---|---|---|
| Modernism | Der Zauberberg | Essayistic time-dilation | Sanatorium cosmopolitanism | Schopenhauer-inflected pessimism | Immediate bestseller | Cornerstone of literary modernism | Thomas Mann | Bildungsroman inversion | The mountain as timeless enclosure | Alpine sanatorium | Shaped the European novel of ideas |
| Menippean satire | The Master and Margarita | Novel-within-a-novel | Cowardice and censorship | Faustian epigraph | Suppressed, samizdat-circulated | Perennial Russian favorite | Mikhail Bulgakov | Interleaved dual narratives | The devil as satirical mirror | Soviet Moscow and biblical Jerusalem | Model for satire under censorship |
| Aestheticism | The Picture of Dorian Gray | Epigrammatic wit | Portrait-as-conscience | Paterian hedonism | Scandalized reviewers | Perpetually adapted | Oscar Wilde | Portrait as moral ledger | The aging portrait | Fin de siècle London | Touchstone for art for art’s sake |
"""

private let markdownHeader = """
# MarkdownEngine

A native macOS Markdown editor built on **TextKit 2**, bridged to SwiftUI — brought to you by [nodes-web.com](https://nodes-web.com).

Edit this text live. Formatting updates as you type — and the toolbar flips engine modes at runtime: read-only, raw markdown source, and a centered reading column.

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

"""
