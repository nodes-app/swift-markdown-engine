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

    /// Registers/unregisters BOTH opt-in seams at once. The document is written
    /// so that flipping this off is the whole explanation of what is core
    /// markdown and what is not: Part 3 falls back to literal text, Parts 1-2
    /// don't move a pixel.
    @State private var seamsEnabled = true

    // Base font size; all relative sizing (headings, code, math) tracks it.
    @State private var fontSize: CGFloat = 16

    // Directive autocomplete. The engine detects the trigger and supplies the
    // ranked candidates; drawing the list is the embedder's job — this whole
    // picker is ~60 lines, and it serves BOTH directive names and argument
    // values because the engine reports them through one context type.
    @State private var completion: DirectiveCompletionContext?
    @State private var completionAnchor: CGRect = .zero
    @State private var completionIndex = 0
    @State private var pendingCompletion: DirectiveCompletionRequest?

    // Scroll-away header demo.
    @State private var showHeader = false
    @State private var headerExpanded = true

    var body: some View {
        NativeTextViewWrapper(
            text: $text,
            configuration: configuration,
            fontSize: fontSize,
            isEditable: !isReadOnly,
            onCaretRectChange: { completionAnchor = $0 },
            onInlinePreviewKey: handleCompletionKey,
            onDirectiveCompletion: { context in
                completion = context
                completionIndex = 0
            },
            pendingDirectiveCompletion: $pendingCompletion,
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
        .overlay(alignment: .topLeading) { completionPicker }
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

                Toggle(isOn: $seamsEnabled) {
                    Label("Opt-in seams", systemImage: "puzzlepiece.extension")
                }
                .help("Register/unregister the extensions and directives of Part 3 — everything they contribute falls back to literal text")

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

    // MARK: - Directive autocomplete

    /// The picker. The engine ships no UI — it reports WHAT to offer and
    /// WHERE, and routes keys; everything below is ordinary SwiftUI.
    ///
    /// One list serves both completion kinds: `.name` while typing `@fo`, and
    /// `.argument` while typing inside `@icon(sta`. The rows differ only in
    /// what each candidate chose to preview — an SF Symbol, a flag, an emoji.
    @ViewBuilder
    private var completionPicker: some View {
        if let completion, !completion.candidates.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(completion.candidates.prefix(8).enumerated()), id: \.offset) { index, item in
                    completionRow(item, isSelected: index == completionIndex)
                        .contentShape(Rectangle())
                        .onTapGesture { commit(item) }
                }
            }
            .padding(4)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.separator))
            .shadow(radius: 12, y: 4)
            .frame(width: 280, alignment: .leading)
            // `onCaretRectChange` arrives already viewport-relative — scroll
            // offset and any header band are accounted for — so it maps
            // straight onto the editor's own frame.
            .offset(x: completionAnchor.minX, y: completionAnchor.maxY + 4)
            .allowsHitTesting(true)
        }
    }

    private func completionRow(_ item: DirectiveCompletionItem, isSelected: Bool) -> some View {
        HStack(spacing: 8) {
            // A candidate previews its own result: the flag, the emoji, or
            // the symbol it will draw.
            if let detail = item.detail {
                Text(detail).frame(width: 20)
            } else if let symbol = item.symbolName {
                Image(systemName: symbol).frame(width: 20)
            } else {
                Color.clear.frame(width: 20, height: 1)
            }
            Text(item.title)
                .fontWeight(isSelected ? .semibold : .regular)
            if !item.subtitle.isEmpty {
                Text(item.subtitle)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .font(.callout)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(isSelected ? Color.accentColor.opacity(0.18) : .clear,
                    in: RoundedRectangle(cornerRadius: 5))
    }

    /// ↑/↓/↵/Esc while the picker is open. Returning `true` consumes the key
    /// so it never reaches the editor; `false` lets normal editing proceed.
    private func handleCompletionKey(_ key: InlinePreviewKey) -> Bool {
        guard let completion, !completion.candidates.isEmpty else { return false }
        let count = min(completion.candidates.count, 8)
        switch key {
        case .moveUp:
            completionIndex = (completionIndex - 1 + count) % count
            return true
        case .moveDown:
            completionIndex = (completionIndex + 1) % count
            return true
        case .confirm, .confirmAndOpen:
            commit(completion.candidates[completionIndex])
            return true
        case .cancel:
            self.completion = nil
            return true
        }
    }

    private func commit(_ item: DirectiveCompletionItem) {
        guard let completion else { return }
        // `documentId` matches the wrapper's default; the engine ignores a
        // request aimed at a different document.
        pendingCompletion = DirectiveCompletionRequest(
            documentId: "default", context: completion, item: item
        )
        self.completion = nil
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

        // ── The two opt-in seams (Part 3 of the document) ───────────────────
        // Neither is core markdown. Both are registered here and nowhere else,
        // and the "Opt-in seams" toggle empties both lists at runtime so you
        // can watch the same characters fall back to literal text.

        // Seam 1 — DELIMITER-shaped constructs. The core engine does not know
        // `==highlight==` or `~~strikethrough~~`; these two extensions supply
        // them.
        config.extensions = seamsEnabled ? [HighlightExtension(), StrikethroughExtension()] : []

        // Seam 2 — NAMED constructs with typed arguments, for what a pair of
        // delimiters cannot express. The marker defaults to `@` and is
        // configurable via `config.directiveSettings`.
        config.directives = seamsEnabled ? [FontDirective(), ColorDirective()] : []

        // The second opt-in seam: named inline commands with typed arguments,
        // for constructs that need a name and parameters rather than
        // delimiters. The marker defaults to `@` and is configurable via
        // `config.directiveSettings`.
        // Only `Font` and `Color` come from the engine — both are pure
        // presentation. `Icon`, `Flag`, `Emoji`, and `PageBreak` live in this
        // demo's own `DemoDirectives.swift`, because curated data and print
        // semantics are app concerns, not engine primitives.
        config.directives = [
            FontDirective(), ColorDirective(),
            IconDirective(), FlagDirective(), EmojiDirective(), PageBreakDirective(),
        ]

        // Toolbar-driven modes.
        config.rawSourceMode = showRawSource
        config.readingWidth = useReadingColumn ? 620 : nil

        return config
    }
}

/// Builds the demo markdown shown when the editor first loads.
///
/// Ordered in three parts by WHERE a construct comes from, because that is the
/// question a reader of this demo actually has:
///
///   Part 1  core markdown — link `MarkdownEngine`, done
///   Part 2  optional products — one extra SPM dependency each, visuals only
///   Part 3  opt-in seams — registered in `MarkdownEditorConfiguration`
///
/// Part 2's sections swap to a short "not linked" note when the bridge product
/// is missing; Part 3's sections turn into literal text when the "Opt-in seams"
/// toolbar toggle is off. Those two fallbacks are the demo's whole argument:
/// everything in Part 1 is unaffected by either.
private var sampleMarkdown: String {
    [
        markdownHeader,
        corePartHeader,
        inlineFormattingSection,
        blocksSection,
        taskListSection,
        tableSection,
        optionalPartHeader,
        codeSection,
        mathSection,
        seamsPartHeader,
        extensionSection,
        directiveSection,
        markdownFooter,
    ].joined(separator: "\n\n")
}

// MARK: - Part dividers

private let corePartHeader = """
---

# Part 1 · Core markdown

Everything under this heading is the engine itself — no registration, no extra \
package products. Link `MarkdownEngine` and you have all of it. Neither toolbar \
toggle below changes a single character of this part.
"""

private let optionalPartHeader = """
---

# Part 2 · Optional products

Two visuals live behind separate Swift Package products because they pull in \
third-party dependencies: `MarkdownEngineCodeBlocks` (HighlighterSwift) and \
`MarkdownEngineLatex` (SwiftMath). Note what they are and aren't — the markdown \
is PARSED either way; without the product you get the fallback visual, not \
literal text. That is what separates Part 2 from Part 3.
"""

private let seamsPartHeader = """
---

# Part 3 · Opt-in seams

Nothing below is markdown. Every construct here exists only because something \
was registered in `MarkdownEditorConfiguration` — and unregistered, the exact \
same characters are literal text.

**Flip “Opt-in seams” off in the toolbar** and watch this part collapse into \
plain text while Parts 1 and 2 stay put. That is the whole distinction.
"""

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
## Extensions — delimiter-shaped

`config.extensions = [HighlightExtension(), StrikethroughExtension()]`

An extension is a PAIR OF DELIMITERS plus how to style what's between them. \
This ==highlighted text== comes from `HighlightExtension`, this \
~~struck-through text~~ from `StrikethroughExtension`. Nesting works like any \
core construct: ==with *italic* inside== and ~~also *nested*~~.

Turn the seams off and both sentences above keep their `==` and `~~` as \
ordinary characters — the core grammar has never heard of them.
"""

/// Directive seam demo: `@font(…){…}` and `@color(…){…}` are supplied by the
/// opt-in `FontDirective` and `ColorDirective` registered above.
///
/// The point of the section is COMPOSITION — a directive contributes a font
/// transform to the styler's walk, so it stacks with whatever encloses it and
/// with whatever it encloses, in both directions. That is why directives are
/// scoped to a body instead of running "from here on": the effect lives in the
/// tree, not in the document position.

/// Directive seam demo: `@font(…){…}` and `@color(…){…}` are supplied by the
/// opt-in `FontDirective` and `ColorDirective` registered above.
///
/// The point of the section is COMPOSITION — a directive contributes a font
/// transform to the styler's walk, so it stacks with whatever encloses it and
/// with whatever it encloses, in both directions. That is why directives are
/// scoped to a body instead of running "from here on": the effect lives in the
/// tree, not in the document position.
private let directiveSection = """
## Directives

The other opt-in seam: named inline commands with typed arguments, for \
constructs that need a name and parameters rather than delimiters. \
Unregistered, `@anything` stays literal text — and a bare `@` in prose or an \
address like jason@example.com never opens one.

Sizes can be absolute — @font(size: 24){twenty-four point} — or relative to the \
surrounding text: @font(size: 0.75em){three-quarter em} and @font(size: 150%){one-and-a-half}.

Composition is the whole idea. Inside a directive, markup keeps the \
directive's size: @font(size: 20){**bold**, *italic*, and ***both***}. Outside, \
the directive keeps its context — the same call in a heading stays bold:

### Headings compose too: @font(size: 28){bigger, still a heading}

Colours work the same way, and directives nest: @color(red){red text}, \
@color(blue){blue text}, and @font(size: 22){@color(purple){big and purple}}.

The other form is self-contained: no body, and it draws a glyph in place of \
its own source. @icon(star.fill, color: yellow) marks a favourite, \
@icon(checkmark.circle.fill, color: green) a finished item, \
@icon(exclamationmark.triangle.fill, color: orange) a warning — sized to \
whatever text surrounds them, so @font(size: 26){they grow too: @icon(bolt.fill, color: blue)}.

Put the caret inside any directive to reveal its source; move away and the \
syntax collapses back to just the styled text or the glyph — exactly like \
every other marker. The characters are never deleted, so selection, find, \
copy, and undo all still see them.

### Autocomplete

**Type `@` anywhere below to try it.** The picker offers every registered \
directive; keep typing to filter, ↑/↓ to move, ↵ to insert, Esc to dismiss.

It completes ARGUMENT VALUES too, which is where it earns its keep. Inside \
`@flag(` you get country codes matched on the code *or* the country name — \
type `jap` and get `JP` @flag(JP). Inside `@emoji(` you get names with the \
glyph previewed: @emoji(tada) @emoji(rocket) @emoji(ship). Inside `@icon(` \
you get SF Symbols, and inside `@color(` the palette.

Each directive declares its own parameters, so the picker knows what to offer \
without the editor knowing anything about flags, emoji, or symbols. \
Only `@font` and `@color` come from the engine. `@icon`, `@flag`, `@emoji`, \
and `@pagebreak` are defined in this demo's own `DemoDirectives.swift` — \
30–60 lines each, schema and completions included — because curated data and \
print semantics belong to the app, not the editor.
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

Edit this text live. Formatting updates as you type — and the toolbar flips engine modes at runtime: read-only, raw markdown source, a centered reading column, and the opt-in seams.

This document is ordered by WHERE each construct comes from, because that is the thing worth knowing before you adopt any of it:

1. **Core markdown** — link `MarkdownEngine`, nothing else to do.
2. **Optional products** — one extra SPM dependency each. They change how something LOOKS, never whether it parses.
3. **Opt-in seams** — registered in your configuration. Unregistered, the same characters are literal text.
"""

/// Inline formatting demo — core only. The inline-math example lives in
/// `mathSection` under Part 2, so this part stays true to its heading: nothing
/// here depends on a product or a registration.
private let inlineFormattingSection = """
## Inline formatting

Mix **bold**, *italic*, and ***both at once***. Reach for `inline code` when a short snippet helps.
"""

/// Math demo when the `MarkdownEngineLatex` bridge is linked; otherwise a short
/// note pointing to the README section that explains how to enable it.
///
/// The `$…$` syntax is CORE — the parser claims it either way. Only the visual
/// comes from the product, which is exactly the Part 2 / Part 3 distinction.
private var mathSection: String {
    #if canImport(MarkdownEngineLatex)
    return #"""
    ## Math — `MarkdownEngineLatex`

    Inline math fits naturally in prose — the Pythagorean identity says $a^2 + b^2 = c^2$, and Euler's identity famously claims $e^{i\pi} + 1 = 0$. Block math gets its own centered line:

    $$
    \int_{-\infty}^{\infty} e^{-x^2}\,dx = \sqrt{\pi}
    $$

    $$
    \frac{\partial}{\partial t}\Psi(\mathbf{r}, t) = -\frac{i}{\hbar}\hat{H}\,\Psi(\mathbf{r}, t)
    $$
    """#
    #else
    return """
    ## Math — `MarkdownEngineLatex` not linked

    `$inline$` and `$$block$$` math is still parsed and still claims its span — it just renders as its own source without the optional `MarkdownEngineLatex` product. See [LaTeX Rendering](https://github.com/nodes-app/swift-markdown-engine#latex-rendering) in the README to wire it up.
    """
    #endif
}

/// Fenced code-block demo when the `MarkdownEngineCodeBlocks` bridge is
/// linked; otherwise a plain monospace example and a link to the
/// README's Code Blocks section.
private var codeSection: String {
    #if canImport(MarkdownEngineCodeBlocks)
    return #"""
    ## Code — `MarkdownEngineCodeBlocks`

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
    ## Code — `MarkdownEngineCodeBlocks` not linked

    Fenced code blocks are still parsed and still get their own block — they just render as plain monospace without the optional `MarkdownEngineCodeBlocks` product. See [Code Blocks](https://github.com/nodes-app/swift-markdown-engine#code-blocks) in the README for syntax-highlighted output:

    ```swift
    let greeting = "Hello, world!"
    ```
    """#
    #endif
}

private let markdownFooter = """
---

"""

