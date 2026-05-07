# MarkdownEngine

[![Swift 5.9](https://img.shields.io/badge/Swift-5.9+-F05138?logo=swift&logoColor=white)](https://swift.org)
[![Platforms macOS 14+](https://img.shields.io/badge/Platforms-macOS%2014+-lightgrey)](https://developer.apple.com/macos/)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
[![CI](https://github.com/nodes-app/swift-markdown-engine/actions/workflows/ci.yml/badge.svg)](https://github.com/nodes-app/swift-markdown-engine/actions/workflows/ci.yml)

A native AppKit Markdown editor for macOS, built on TextKit 2 and bridged to
SwiftUI. Live styling, wiki-link support, fenced code blocks with syntax
highlighting, LaTeX rendering, embedded images, and GitHub-style task
checkboxes — with **zero external dependencies**.

## Features

- **Live Markdown styling** — bold, italic, headings, lists, code, links,
  task checkboxes, horizontal rules
- **Wiki-style linking** with two-form storage / display roundtripping
  (`[[Name|<id>]]` ↔ `[[Name]]`)
- **Image embeds** — `![[Name]]` syntax, embedder supplies the bytes
- **LaTeX** — both block (`$$ … $$`) and inline (`$…$`), embedder supplies
  the renderer
- **Code blocks** with embedder-supplied syntax highlighting and overlayable
  copy buttons
- **TextKit 2** layout for accurate, modern text rendering
- **Writing Tools** integration on macOS 15.1+
- **Comfortable bottom overscroll** so the caret never pins to the viewport
  edge while typing
- **Drag-select autoscroll boost** for long documents
- **Spelling & grammar** with code/LaTeX/wiki-link suppression

## Architecture

The engine is built around four small service protocols you implement in
your app:

| Protocol | What you supply | Suggested library |
|---|---|---|
| `WikiLinkResolver` | Resolve a `[[Name]]` to a stable opaque id | (your data model) |
| `EmbeddedImageProvider` | Look up an `NSImage` for `![[Name]]` | (your asset store) |
| `SyntaxHighlighter` | Highlight code blocks for a given language | [HighlighterSwift](https://github.com/smittytone/HighlighterSwift), [Splash](https://github.com/JohnSundell/Splash) |
| `LatexRenderer` | Render a LaTeX string to an `NSImage` | [SwiftMath](https://github.com/mgriebling/SwiftMath) |

All four ship with no-op default implementations so the editor renders
plain Markdown out of the box. Drop in real implementations as you need
them — the engine itself stays free of any of those transitive dependencies.

## Installation

Add MarkdownEngine to your `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/nodes-app/swift-markdown-engine", from: "0.1.0")
],
targets: [
    .target(
        name: "YourApp",
        dependencies: ["MarkdownEngine"]
    )
]
```

Or in Xcode: **File → Add Package Dependencies…** and paste the repo URL.

## Quick Start

```swift
import SwiftUI
import MarkdownEngine

struct EditorScreen: View {
    @State private var text: String = "# Hello, *world*"
    @State private var isLinkActive: Bool = false
    @State private var pendingReplacement: InlineReplacementRequest?

    var body: some View {
        NativeTextViewWrapper(
            text: $text,
            isWikiLinkActive: $isLinkActive,
            pendingInlineReplacement: $pendingReplacement,
            configuration: .default,
            fontName: "SF Pro",
            documentId: "doc-1"
        )
    }
}
```

That's it. The default configuration ships with no-op services, so the
editor renders Markdown and accepts edits immediately.

## Demo

A runnable SwiftUI demo lives in [`Demo/`](Demo/MarkdownEngineDemo.xcodeproj).
Open [`Demo/MarkdownEngineDemo.xcodeproj`](Demo/MarkdownEngineDemo.xcodeproj)
in Xcode and hit **Run** — the demo references the package via a local
path, so Xcode resolves it on first open and any engine edit rebuilds
into the demo on the next run.

> If you're seeing a "missing package product" error, it's almost always
> stale package cache from a previous Xcode session. Use **File →
> Packages → Reset Package Caches** once and rebuild.

## Customizing the Theme

Every color the editor puts on screen is read from `MarkdownEditorTheme`:

```swift
var theme = MarkdownEditorTheme.default
theme.bodyText = .labelColor
theme.headingMarker = .secondaryLabelColor
theme.findMatchHighlight = NSColor(named: "MyAccent")!

var configuration = MarkdownEditorConfiguration.default
configuration.theme = theme
```

Defaults map to `NSColor` dynamic system colors so light / dark mode
switching keeps working without extra code.

## Wiring Up Services

```swift
struct MyResolver: WikiLinkResolver {
    func resolve(displayName: String, range: NSRange) -> WikiLinkResolution? {
        guard let id = myIndex[displayName] else { return nil }
        return WikiLinkResolution(id: id, exists: true)
    }
}

struct MyImages: EmbeddedImageProvider {
    func image(for ref: EmbeddedImageRequest) -> NSImage? {
        myImageStore.load(name: ref.name)
    }
    func fingerprint() -> AnyHashable { myImageStore.version }
}

let services = MarkdownEditorServices(
    wikiLinks: MyResolver(),
    images:    MyImages(),
    syntaxHighlighter: MyHighlighter(),
    latex:     MyLatexRenderer()
)

var configuration = MarkdownEditorConfiguration.default
configuration.services = services
```

## Tuning Behavior

`MarkdownEditorConfiguration` exposes every spacing / sizing / behavior
knob the engine has, grouped by concern:

```swift
var configuration = MarkdownEditorConfiguration.default
configuration.codeBlock.fontSizeScale = 0.9
configuration.headings.fontMultipliers = [2.4, 1.8, 1.4, 1.1, 0.9, 0.75]
configuration.overscroll.percent = 0.4
configuration.lists.helpersEnabled = false  // disable list editing helpers
```

## Documentation

Full API documentation is available via DocC:

```bash
swift package generate-documentation --target MarkdownEngine
```

In Xcode: **Product → Build Documentation** (`⇧⌃⌘D`).

Once the package is hosted on Swift Package Index, the docs will live at
`https://swiftpackageindex.com/nodes-app/swift-markdown-engine/documentation`.

## Requirements

- macOS 14 or later
- Swift 5.9 or later
- Xcode 15 or later
- macOS 15.1+ for Apple Writing Tools integration

## Status

MarkdownEngine is currently **pre-1.0**. The public API may change between
minor releases as it stabilizes. Production use is fine — pin a specific
version (`0.x.y`) in your `Package.swift`.

## Contributing

Bug reports, ideas, and pull requests are welcome. See
[CONTRIBUTING.md](CONTRIBUTING.md) for the development setup, coding
conventions, and PR process.

## License

MarkdownEngine is released under the MIT License. See [LICENSE](LICENSE)
for the full text.
