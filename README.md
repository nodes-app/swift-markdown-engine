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

- **Live Markdown styling** — bold, italic, strikethrough, highlight, headings, lists, blockquotes, GFM tables, code, links, task checkboxes, horizontal rules 
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

By default the editor scrolls internally within whatever height SwiftUI
gives it. Set `heightBehavior` to `.fitsContent` to make the editor grow
to fit its content and report that height to SwiftUI, so an enclosing
`ScrollView` scrolls the page instead:

```swift
ScrollView {
    NativeTextViewWrapper(
        text: $text,
        configuration: .init(heightBehavior: .fitsContent)
    )
}
```

- The editor reports `headerHeight + text content height` to SwiftUI;
  no inner scroller appears.
- Typing additional lines grows the block; deleting lines shrinks it.
- An empty document shows one line of height.
- Scroll-wheel events pass through to the enclosing scroll view.
- Composes with `readingWidth`: the centered column is preserved and
  height grows to the column's content height.
- A static scroll-away header's band is included in the reported height.
  The collapse-on-scroll animation is not meaningful in `.fitsContent`
  because there is no internal scroll offset to drive it.
- Switching `heightBehavior` at runtime is supported; the editor
  reconfigures immediately.

**Trade-offs:** `.fitsContent` forces full-document layout so the total
height is known, forgoing TextKit-2 viewport virtualization. This is
fine for small-to-medium inline content; very large documents still work
but lay out in full.

### Reading Column

Give long documents a fixed-width, centered column — and let wide GFM
tables break out of it to the full window width, Google-Docs-style:

```swift
var configuration = MarkdownEditorConfiguration.default
configuration.readingWidth = 650
```

- Text wraps at `readingWidth` and never re-wraps on window resize —
  only the column's position moves, which keeps live resize smooth.
- Tables wider than the column expand up to the full viewport width and
  scroll horizontally beyond that.
- Leave it `nil` (the default) and the editor fills its container
  edge-to-edge, exactly as before.

### Scrolling Header

Host a SwiftUI view above the document body that scrolls away with it —
document metadata, a property table, a contextual toolbar:

```swift
NativeTextViewWrapper(
    text: $text,
    header: AnyView(MyDocumentHeader(document: document)),
    headerCollapsedHeight: 40,
    headerExpanded: isHeaderExpanded
)
```

- The engine hosts the view in an `NSHostingView`, reserves its
  intrinsic height at the top of the scrolled content, and shifts the
  body below it. The header is a sibling of the text view, so it stays
  fully interactive (buttons, text fields, menus).
- `headerExpanded: false` collapses the band to `headerCollapsedHeight`:
  the top row stays visible while the rows below clip away. Toggling
  animates the reveal. Size your header so the content above
  `headerCollapsedHeight` is the part you want to keep visible.
- The hosted content refreshes on every SwiftUI update — bind your
  model into the header view as usual. Inject any required environment
  (`.environmentObject`, `.environment`) into the view *before* wrapping
  it in `AnyView`; the hosting view does not inherit your hierarchy's
  environment.
- The reserved band uses the view's **intrinsic** (ideal) height. Text
  that relies on wrapping at the editor's width can render taller than
  its ideal height and clip at the band's bottom — give wrapping
  content an explicit height (`.frame`/`.fixedSize`) or line limit.
- Composes with `readingWidth`: the header spans the full viewport
  width while the body keeps its centered column.
- An optional `placeholder: NSAttributedString?` renders ghost text at
  the first-line position while the document is empty — below the header
  band, tracking its reveal animation; the first keystroke hides it.
  Style it with the editor's body font so it lines up with the would-be
  first line.
- Pass `header: nil` (the default) and the editor renders exactly as
  before — the header path adds nothing to header-less editors.

The demo app's **Header** toolbar toggle shows the full behavior.

## Demo

A runnable SwiftUI demo lives in [`Demo/`](Demo/MarkdownEngineDemo.xcodeproj).
Open it in Xcode and hit **Run** — the demo references the package via
a local path, so any engine edit rebuilds into the demo on the next run.

> If you're seeing a "missing package product" error, it's almost always
> stale package cache. Use **File → Packages → Reset Package Caches**
> once and rebuild.

## Documentation

Full API documentation is available via DocC. In Xcode, use
**Product → Build Documentation** (`⇧⌃⌘D`).

For local CLI preview, temporarily add the Swift DocC plugin as described in
[CONTRIBUTING.md](CONTRIBUTING.md), then run:

```bash
swift package --disable-sandbox preview-documentation --target MarkdownEngine
```

Once the package is hosted on Swift Package Index, the docs will live at
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
