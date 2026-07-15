# Architecture

## Source layout

```bash
Sources/
├── MarkdownEngine/                          # core target — zero deps
│   ├── Configuration/                       # MarkdownEditorConfiguration + MarkdownEditorTheme
│   ├── Extensions/                          # the extension seam: MarkdownExtension + bundled opt-ins
│   ├── Services/                            # 4 protocols, no-op defaults, WikiLinkService
│   ├── Parser/                              # two-phase AST: BlockParser → InlineParser → DocumentAST (+ token projection)
│   ├── Styling/                             # MarkdownASTStyler (AST walk) + MarkdownStyler facade for NSImage passes
│   ├── Renderer/                            # LayoutBridge, MarkdownTextLayoutFragment, EmbeddedImageCache
│   ├── Input/                               # MarkdownInputHandler + MarkdownListHandler
│   ├── TextView/
│   │   ├── NativeTextViewWrapper.swift      # SwiftUI entry point (NSViewRepresentable)
│   │   ├── NativeTextViewContainer.swift    # the scroll view's documentView: header band + text column stacking
│   │   ├── ScrollingHeaderController.swift  # scroll-away header: hosting, collapse/expand, teardown
│   │   ├── ClampedScrollView.swift          # scroll range clamped to real content height
│   │   ├── NativeTextView/                  # AppKit subclass + UX extensions (paste, drag-select, …)
│   │   └── Coordinator/                     # NSTextViewDelegate split by concern (restyling, find, …)
│   └── MarkdownEngine.docc/                 # DocC catalog
├── MarkdownEngineCodeBlocks/                # opt-in SPM product — pulls in HighlighterSwift
│   └── HighlighterSwiftBridge.swift         # SyntaxHighlighter conformance
└── MarkdownEngineLatex/                     # opt-in SPM product — pulls in SwiftMath
    └── SwiftMathBridge.swift                # LatexRenderer conformance
```

The rest of this file is a per-directory tour, in the order text flows
through the engine.

## [`Parser/`](Sources/MarkdownEngine/Parser): text → AST → tokens

A two-phase AST pipeline following CommonMark's model — block structure first,
inline content second. There is no regex tokenizer anymore; the structural
regexes are gone, replaced by hand-written scanners and a real syntax tree.

1. **`BlockParser`** splits the document into a flat, gap-free (tiling)
   sequence of `Block`s: `heading`, `paragraph`, `blockquote`, `list`,
   `fencedCode`, `blockLatex`, `table`, `thematicBreak`, `blank`. Hand-written
   line scanners. It memoizes the last parse (UTF-16 buffer cache) so the
   per-keystroke callers share one line-scan.
2. **`InlineParser`** turns a single inline-bearing block's text into an inline
   AST (`[InlineNode]`) with correct CommonMark precedence: code spans →
   escapes → link family (`![[…]]`, `[[…]]`, `![…](…)`, `[…](…)`, `~~…~~`,
   `$…$`) → emphasis (`*`/`_` delimiter runs) → `buildTree`. Each pass claims
   spans only in regions not already claimed, so there are never partial
   overlaps and the tree is a clean containment tree.
3. **`MarkdownAST` / `DocumentAST.parse`** combines the two into the semantic
   document AST — `[BlockNode]`, each inline-bearing block carrying its parsed
   `[InlineNode]` children in absolute document coordinates. `BlockNode`,
   `InlineNode`, and `ListItem` are defined here.

**Tokens are now a projection of the AST, not the source of truth.**
`MarkdownTokenizer` is just a namespace; its entry point `parseTokensViaAST`
(implemented in **`BlockScopedTokenizer`** — the live tokenization pipeline)
walks each `BlockParser` block and emits the legacy flat `[MarkdownToken]`
shape: block-level tokens (heading, blockquote, fenced code, table, block
LaTeX) come from **`BlockLevelTokenizer`** (hand scanners), inline tokens from
the AST via **`InlineASTAdapter`** (`[InlineNode]` → `[MarkdownToken]`). Token
shapes are reproduced 1:1 from the old regex tokenizer (parity-checked), so the
consumers that still read tokens — the NSImage render passes, code-block
handling, `MarkdownInputHandler`, `ContextMenu`, and `MarkdownDetection`
(caret-aware active-token indices) — keep working unchanged.

**Invariant:** Ranges everywhere are absolute UTF-16 `NSRange`s into the source
(the editor is TextKit-2 / `NSTextView`-based, so UTF-16 offsets are the native
currency).

**Invariant:** Parsing is incremental. With `scopedRanges`, `DocumentAST.parse`
parses inlines only for blocks intersecting the edit, and `BlockScopedTokenizer`
memoizes per-block tokens (substring → tokens, FIFO-capped) — so a keystroke
re-parses one block, not the whole document (≈ O(edit)).

## [`Extensions/`](Sources/MarkdownEngine/Extensions): opt-in constructs beyond pure markdown

`MarkdownExtension` contributes an inline span form (`InlineSyntax`, e.g.
`==highlight==`), a fenced block form (`BlockSyntax`, e.g. `::: … :::`), or
both — plus content attributes and an HTML wrapper for the clean-copy path.
Registered via `MarkdownEditorConfiguration.extensions`; unregistered syntax
stays literal text. Extensions never emit ranges — the parser derives all
geometry — and every parse cache keys on the registry fingerprint, so the
registered set can change at runtime.

**Invariant:** built-in constructs always classify first; an extension can
never take text away from core markdown.

## [`Services/`](Sources/MarkdownEngine/Services): how does the engine talk to your app?

`MarkdownEditorServices.swift` declares the four service protocols. Each is
called synchronously when its construct is styled or rendered: `WikiLinkResolver`
while styling wiki-links, `EmbeddedImageProvider` from the image-embed render
pass, `SyntaxHighlighter` from code styling, `LatexRenderer` from the LaTeX
render passes.

`WikiLinkService.swift` handles the dual-form storage / display transform —
storage is `[[Name|<id>]]`, display is `[[Name]]`. The coordinator runs it both
ways every time `rebuildTextStorageAndStyle()` fires.

**Invariant:** Service callbacks are synchronous. If an embedder's
implementation is slow, it caches (both bundled bridges do); the engine never
async-renders.

**Invariant:** Wiki-link storage and display are different strings. Display IDs
never leak into the binding.

## [`Styling/`](Sources/MarkdownEngine/Styling): how does the AST become attributes?

`MarkdownASTStyler.styleAttributes()` is the live styler. It walks the document
AST and emits `[StyledRange]`, **composing** attributes on descent: a heading
sets a large bold font, descending into bold adds the bold trait (keeping the
size), into italic adds italic — so nested / combined inline styles stack
instead of overwriting each other. (Composition is what the old flat pass
pipeline got wrong, e.g. the shrinking bold in `# **n*o*des**`.)

`MarkdownStyler.styleAttributes()` (`MarkdownStyler.swift:43`) is now a thin
facade: it builds the `StylingContext`, runs the AST styler for all text
styling, then appends the passes that still render **NSImages** and therefore
still consume tokens — block / inline LaTeX (`+Latex`), image embeds and image
links (`+Images`), and rendered tables (`+Tables`). `MarkdownStyler+TaskCheckboxes`
and `+BulletMarkers` no longer style (the AST styler does); they keep only the
caret / selection range helpers (`taskSyntaxRange`, `bulletSyntaxRange`,
`hrLineRange`) the text-view delegate uses.

If the coordinator passes `scopedRanges`, only the intersecting blocks are
re-styled — the optimization that keeps per-keystroke restyling cheap.

**Invariant:** Markers shrink, they don't disappear. Inactive markers render at
`hiddenMarkerFontSize`; they're never removed from text storage. Every
selection / copy / find / undo bug downstream traces back to violating this.

## [`Renderer/`](Sources/MarkdownEngine/Renderer): TextKit 2 layout

Thin wrappers around `NSTextLayoutManager` (`LayoutBridge.swift`), a custom
`MarkdownTextLayoutFragment` for precise positioning, and `EmbeddedImageCache`
keyed by an embedder-supplied fingerprint so images and LaTeX results
invalidate when the embedder says so.

## [`Input/`](Sources/MarkdownEngine/Input): typing-time helpers

`MarkdownInputHandler.swift` handles auto-wrap for `$…$` / `$$…$$` / `![[…]]`.
`MarkdownListHandler.swift` handles list continuation, indent / outdent, and
task-checkbox toggling on Enter / Tab / Backspace. Both run synchronously inside
the text-view delegate.

## [`TextView/`](Sources/MarkdownEngine/TextView): NSTextView + SwiftUI bridge

The entry point is `NativeTextViewWrapper.swift` — an `NSViewRepresentable` that
owns the coordinator and the configured text view.

The scroll view's `documentView` is **always** `NativeTextViewContainer`, never
the text view itself. The container stacks up to three kinds of siblings in a
flipped coordinate space: the optional scroll-away header band at the top (a
clipped `NSHostingView` managed by `ScrollingHeaderController`, reserved height
mirrored into `container.headerHeight`), the `NativeTextView` at
`y = headerHeight` (centered at a fixed width when
`configuration.readingWidth` is set), and — in reading-column mode — the
full-width wide-table breakout overlays. Anything that converts between
text-view-local rects and scroll/document space must lift by the text view's
origin inside the container (`convert(_:to:)` or `frame.origin`); see
`viewRect(forCharacterRange:)` and the find-in-document paths for the pattern.

Two sub-folders matter:

- `NativeTextView/` — extensions on the AppKit subclass (paste, drag-select
  boost, spell policy, caret workarounds, frame/overscroll management)
- `Coordinator/` — `NSTextViewDelegate` glue, split by concern (restyling,
  writing-tools, find, code-blocks, inline selection, autocorrect)

Application of `[StyledRange]` to text storage happens in
`Coordinator/NativeTextViewCoordinator+Restyling.swift` →
`rebuildTextStorageAndStyle()`, which tokenizes via `parseTokensViaAST` and
calls `MarkdownStyler.styleAttributes()`.

## [`Configuration/`](Sources/MarkdownEngine/Configuration): the tunables

`MarkdownEditorConfiguration` is a struct of structs — one nested group per
concern (headings, codeBlock, blockLatex, overscroll, markers, lists, …) —
passed by reference into the styler via the `StylingContext`.
`MarkdownEditorTheme` is its colour sub-field.
