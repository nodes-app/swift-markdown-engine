<p align="center">                                                                                               
<img width="128" alt="MDE-iOS-Default-1024x1024@1x" src="https://github.com/user-attachments/assets/88905708-9336-4cfe-8ce8-2be20866e89f" />
</p>

<h1 align="center">SwiftMarkdownEngine</h1>  

<p align="center">
  <a href="https://swift.org"><img src="https://img.shields.io/badge/Swift-5.9+-F05138?logo=swift&logoColor=white" alt="Swift 5.9+" /></a>
  <a href="https://developer.apple.com/macos/"><img src="https://img.shields.io/badge/Platforms-macOS%2014+-lightgrey" alt="Platforms macOS 14+" /></a>
  <a href="LICENSE"><img src="https://img.shields.io/badge/License-Apache%202.0-yellow.svg" alt="License: Apache 2.0" /></a>
  <a href="https://github.com/nodes-app/swift-markdown-engine/actions/workflows/ci.yml"><img src="https://github.com/nodes-app/swift-markdown-engine/actions/workflows/ci.yml/badge.svg" alt="CI" /></a>
</p>



<video src="https://github.com/user-attachments/assets/b61ed622-0e9a-4e91-9de5-9cd6c53752e5"
       autoplay loop muted playsinline
       width="100%">
</video>


A native AppKit Markdown editor for macOS, built on TextKit 2 and bridged to SwiftUI. Brought to you by **[Nodes](https://apps.apple.com/de/app/nodes-by-the-werk/id6745401961)**. Live styling, wiki-link support, fenced code blocks with syntax highlighting, LaTeX rendering, embedded images, and GitHub-style task
checkboxes.

## Features

- **Live Markdown styling** — bold, italic, headings, lists, blockquotes, GFM tables, code, links, task checkboxes, horizontal rules
- **Extensions** — opt-in constructs beyond CommonMark (`==highlight==`, `~~strikethrough~~`, …); add your own via [`MarkdownExtension`](#extensions)
- **Wiki-style linking** with two-form storage / display roundtripping
  (`[[Name|<id>]]` ↔ `[[Name]]`)
- **Image embeds** — both `![[Name]]` (Obsidian-style, embedder supplies the                           
  bytes) and standard Markdown `![alt](url)`
- **LaTeX** — both block (`$$ … $$`) and inline (`$…$`), embedder supplies
  the renderer
- **Code blocks** with embedder-supplied syntax highlighting and overlayable
  copy buttons
- **Reading column** — opt-in fixed-width centered column, wide tables
  break out to the full window width (`readingWidth`)
- **Scroll-away header** — host your own SwiftUI view above the document;
  it scrolls with the content and collapses to a pinned top row
- **TextKit 2** layout for accurate, modern text rendering
- **Writing Tools** integration on macOS 15.1+
- **Comfortable bottom overscroll** so the caret never pins to the viewport
  edge while typing
- **Drag-select autoscroll boost** for long documents
- **Spelling & grammar** with code/LaTeX/wiki-link suppression

## Installation

```swift
dependencies: [
    .package(url: "https://github.com/nodes-app/swift-markdown-engine", from: "0.1.0")
],
targets: [
    .target(
        name: "YourApp",
        dependencies: [
            .product(name: "MarkdownEngine", package: "swift-markdown-engine"),
        ]
    )
]
```

Or in Xcode: **File → Add Package Dependencies…** and paste the repo URL.

The package ships three library products — add only what you need:

| Product | Use when |
|---|---|
| `MarkdownEngine` | You want the editor only. Zero external dependencies. |
| `MarkdownEngineCodeBlocks` | You want the full visual code-block experience — background fill, monospace font, and syntax highlighting — without writing your own bridge. Pulls in [HighlighterSwift](https://github.com/smittytone/HighlighterSwift) transitively. See [Customization → Code Blocks](#code-blocks). |
| `MarkdownEngineLatex` | You want LaTeX formula rendering without writing your own bridge. Pulls in [SwiftMath](https://github.com/mgriebling/SwiftMath) transitively. See [Customization → LaTeX Rendering](#latex-rendering). |

## Quick Start

```swift
import SwiftUI
import MarkdownEngine

struct EditorScreen: View {
    @State private var text: String = "# Hello, *world*"

    var body: some View {
        NativeTextViewWrapper(text: $text)
    }
}
```

That's it. See [Customization](#customization) below for syntax
highlighting, themes, wiki-link state, and more.

> **Displaying multiple editors?** Pass a stable, unique
> `documentId: "your-doc-id"` so undo history and pending replacements
> stay scoped to each editor instance.

## Customization

### Service Protocols

The engine talks to your app through four service protocols, each with
a no-op default so you only implement what you actually need:

| Protocol | What you supply | Ready-made bridge / suggested library |
|---|---|---|
| `WikiLinkResolver` | Resolve a `[[Name]]` to a stable opaque id | (your data model) |
| `EmbeddedImageProvider` | Look up an `NSImage` for `![[Name]]` | (your asset store) |
| `SyntaxHighlighter` | Highlight code blocks for a given language | **`HighlighterSwiftBridge`** ([recommended](#code-blocks)) — built on [HighlighterSwift](https://github.com/smittytone/HighlighterSwift) |
| `LatexRenderer` | Render a LaTeX string to an `NSImage` | **`SwiftMathBridge`** ([recommended](#latex-rendering)) — built on [SwiftMath](https://github.com/mgriebling/SwiftMath) |

Implement what you need and pass it through `MarkdownEditorServices`:

```swift
struct MyResolver: WikiLinkResolver {
    func resolve(displayName: String, range: NSRange) -> WikiLinkResolution? {
        myIndex[displayName].map { WikiLinkResolution(id: $0, exists: true) }
    }
}

configuration.services = MarkdownEditorServices(
    wikiLinks: MyResolver()
    // images, syntaxHighlighter, latex omitted → no-op defaults
)
```

Each protocol and its no-op default are documented in DocC.

### Extensions

The core engine parses pure markdown. Extra constructs like `==highlight==`,
`~~strikethrough~~`, and `::: … :::` container blocks are opt-in extensions:

```swift
var config = MarkdownEditorConfiguration()
config.extensions = [HighlightExtension(), StrikethroughExtension(), ContainerExtension()]
```

Unregistered syntax stays literal text. An extension contributes an inline
form (`InlineSyntax`), a fenced block form (`BlockSyntax`), or both — plus the
attributes for its content and an HTML wrapper for rich copy. The parser owns
all geometry, marker/fence hiding, caret reveal, and incremental restyling, so
extensions behave identically to built-ins and cannot affect neighboring
constructs. Conform to `MarkdownExtension` to add your own.

### Code Blocks

**Recommended path: depend on the `MarkdownEngineCodeBlocks` product
and use the bundled `HighlighterSwiftBridge`.** Rolling your own
`SyntaxHighlighter` has subtle footguns the bridge already handles —
line-height metrics across light/dark themes, appearance-change
observation, layout-pass timing, font name extraction from the theme,
and CSS-theme-derived background colors. Use the bundle unless you
specifically need a non-HighlighterSwift library.

```swift
import MarkdownEngineCodeBlocks

var configuration = MarkdownEditorConfiguration.default
configuration.services = MarkdownEditorServices(
    syntaxHighlighter: HighlighterSwiftBridge()
)
```

The bridge auto-switches between `atom-one-light` and `atom-one-dark`
with system appearance. Different theme names or a pinned single theme
are configurable via init params — see DocC.

Need a different highlighter library entirely? Implement
`SyntaxHighlighter` yourself (see [Service Protocols](#service-protocols)
above for the declaration) and reference the bundled bridge in
`Sources/MarkdownEngineCodeBlocks/` as a working example.

### LaTeX Rendering

**Recommended path: depend on the `MarkdownEngineLatex` product and use
the bundled `SwiftMathBridge`.** Hand-rolling a `LatexRenderer` has
real footguns the bridge already handles — appearance-aware text color,
zero-sized output guards (`lockFocus` crashes on 0×0 images),
window-vs-NSApp appearance distinction, single-letter padding, and an
internal cache keyed by (latex, font size, appearance, theme color).

```swift
import MarkdownEngineLatex

var configuration = MarkdownEditorConfiguration.default
configuration.services = MarkdownEditorServices(
    latex: SwiftMathBridge()
)
```

The bridge uses the Latin Modern math font and tints formulas with
`MarkdownEditorTheme.latexLightModeText` / `latexDarkModeText`. Pass
`singleLetterPaddingBottom:` to override the engine's matching default.

### Theming

Every color the editor puts on screen reads from `MarkdownEditorTheme`:

```swift
var theme = MarkdownEditorTheme.default
theme.bodyText = .labelColor
theme.findMatchHighlight = NSColor(named: "MyAccent")!

var configuration = MarkdownEditorConfiguration.default
configuration.theme = theme
```

Defaults map to `NSColor` dynamic system colors, so light/dark mode
keeps working without extra code.

### Tuning

`MarkdownEditorConfiguration` exposes every spacing / sizing / behavior
knob the engine has, grouped by concern:

```swift
var configuration = MarkdownEditorConfiguration.default
configuration.codeBlock.fontSizeScale = 0.9
configuration.headings.fontMultipliers = [2.4, 1.8, 1.4, 1.1, 0.9, 0.75]
configuration.overscroll.percent = 0.4
configuration.lists.helpersEnabled = false
configuration.safeAreaInsets = SafeAreaInsets(top: 56)   // headroom under a translucent toolbar
```

### Wiki-Links & Replacement State

Two optional bindings on `NativeTextViewWrapper` let you observe
wiki-link state and push inline replacements programmatically. Pass
only what you need — each is independent and defaults to a no-op:

```swift
NativeTextViewWrapper(
    text: $text,
    isWikiLinkActive: $isWikiLinkActive,
    pendingInlineReplacement: $pendingReplacement
)
```

- `isWikiLinkActive` — the wrapper sets this to `true` while the caret
  sits inside a `[[Name]]` link, so you can present a contextual UI.
- `pendingInlineReplacement` — assign a non-nil value to push a
  replacement (e.g. an autocomplete result); the engine consumes it
  and clears the binding.

### Height Behavior

By default the editor scrolls internally. Set `heightBehavior` to
`.fitsContent` to make it grow to fit its content and report that height to
SwiftUI, so an enclosing `ScrollView` scrolls the page instead:

```swift
ScrollView {
    NativeTextViewWrapper(text: $text, configuration: .init(heightBehavior: .fitsContent))
}
```

Composes with `readingWidth` and the scrolling header, and is switchable at
runtime. `.fitsContent` lays out the whole document (no viewport
virtualization), so prefer it for small-to-medium content. See
``HeightBehavior`` in DocC for the full behavior.

### Reading Column

Give long documents a fixed-width centered column; wide GFM tables break out
to the full window width, Google-Docs-style:

```swift
configuration.readingWidth = 650
```

Text wraps at `readingWidth` and never re-wraps on resize (only the column's
position moves), keeping live resize smooth. Leave it `nil` (default) to fill
the container edge-to-edge.

### Scrolling Header

Host a SwiftUI view above the document body that scrolls away with it —
metadata, a property table, a contextual toolbar:

```swift
NativeTextViewWrapper(
    text: $text,
    header: AnyView(MyDocumentHeader(document: document)),
    headerCollapsedHeight: 40,
    headerExpanded: isHeaderExpanded
)
```

The engine hosts it in an `NSHostingView`, reserves its intrinsic height, and
keeps it fully interactive. `headerExpanded: false` collapses to
`headerCollapsedHeight` (top row stays, rows below clip away, animated). Inject
any required environment *before* wrapping in `AnyView`, and give wrapping
content an explicit height so it doesn't clip at the band's bottom. Composes
with `readingWidth`; an optional `placeholder:` shows ghost text while empty;
`header: nil` (default) adds nothing. The demo's **Header** toggle shows it.

## Demo

A runnable SwiftUI demo lives in [`Demo/`](Demo/MarkdownEngineDemo.xcodeproj).
Open it in Xcode and hit **Run** — the demo references the package via
a local path, so any engine edit rebuilds into the demo on the next run.

> If you're seeing a "missing package product" error, it's almost always
> stale package cache. Use **File → Packages → Reset Package Caches**
> once and rebuild.

## Documentation

Full API docs ship as DocC. In Xcode: **Product → Build Documentation**
(`⇧⌃⌘D`); for local CLI preview see [CONTRIBUTING.md](CONTRIBUTING.md). Once
hosted on Swift Package Index, docs will live at
`https://swiftpackageindex.com/nodes-app/swift-markdown-engine/documentation`.

## Requirements & Status

- macOS 14 or later (15.1+ for Apple Writing Tools integration)
- Swift 5.9 / Xcode 15 or later

MarkdownEngine is currently **pre-1.0**. The public API may change between
minor releases as it stabilizes. Production use is fine — pin a specific
version (`0.x.y`) in your `Package.swift`.

## Contributing

Bug reports, ideas, and pull requests are welcome.

- [ARCHITECTURE.md](ARCHITECTURE.md) — codemap and pipeline guide for
  contributors
- [CONTRIBUTING.md](CONTRIBUTING.md) — setup, PR process, and design
  constraints

## License

MarkdownEngine is released under the Apache 2.0 License. See [LICENSE](LICENSE)
for the full text.

---
Built by small team from Germany. Day-to-day on [Instagram](https://www.instagram.com/nodes.app).
