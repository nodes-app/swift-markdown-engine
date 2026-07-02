# Changelog

All notable changes to swift-markdown-engine are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added
- `MarkdownEditorConfiguration.rawSourceMode`: present the document as raw
  Markdown source — no syntax hiding, no markdown styling, and no wiki-link
  display transform (`[[Name|UUID]]` shows verbatim). The editor keeps base
  font/paragraph styling and stays fully editable; smart Markdown input
  handling (list continuation, `$$`/`![[` auto-wrap, ⇧⇥ outdent) is disabled
  while raw. Runtime switching is supported and rebuilds the document
  immediately; the current document's undo stack is dropped on a switch
  because undo actions recorded against the other mode's display text would
  replay at stale ranges. Default `false` — existing embedders are unaffected.

### Fixed
- Inline syntax markers (`**`, `*`, `~~`, `==`) now use `mutedText` foreground
  color while the caret is inside the corresponding span, matching the existing
  behavior of inline code backticks and link/wiki-link brackets. This makes
  highlight `==` markers visually distinct from body text in edit state.
- Web links `[text](url)` now share the wiki-link "edit zone": clicking the outer
  ~30% of the link's first/last visible character places the caret just outside the
  markers (before `[` / after `)`) and reveals the source for editing instead of
  navigating, matching `[[…]]` behavior. Previously the edit zone only resolved
  `.wikiLink` tokens, so a web link dropped the caret between its brackets and did
  not reveal. Middle-of-link clicks still navigate; read-only links stay navigable.
- Auto-linking (`NSDataDetector`) no longer linkifies a URL that sits inside a
  markdown or wiki link's own range. A link's `(url)` previously got its own
  competing `.link` attribute on top of the link — making the raw URL independently
  navigable and offsetting the click edit zone. Bare URLs outside links still
  autolink; URLs inside code were already excluded.

## [0.8.0] - 2026-06-28

### Added
- `MarkdownEditorBus.findQuery` / `findResults`: query-based in-document find. The host posts a
  search string (+ current index) and the engine matches against its OWN displayed text,
  highlighting in display coordinates and posting the match count back. This is correct where the
  displayed text differs from the source — e.g. node links rendered shorter than `[[Name|UUID]]`,
  LaTeX, or images — which the legacy `findScrollToRange` (host-computed source-coordinate ranges)
  highlighted at the wrong offset. Opt-in; `findScrollToRange` is unchanged for existing embedders.
- `NativeTextView.isCursorExcluded: ((CGPoint) -> Bool)?` — embedder-supplied
  predicate that suppresses the edit-mode I-beam cursor when the mouse is inside
  a defined exclusion zone (e.g. a formatting toolbar). When the closure returns
  `true`, `mouseMoved:` skips calling `super.mouseMoved` to avoid NSTextView's
  built-in I-beam cursor, setting the arrow cursor instead. Exposed through
  `NativeTextViewWrapper.isCursorExcluded`.
- `NativeTextViewWrapper.onBuildContextMenu: ((NSMenu, NSRange) -> NSMenu)?` —
  embedder hook to build the editor's right-click menu. The engine hands over the
  default `NSMenu` + the current selection; the embedder returns the menu to show
  (driving the `didMarkdown*` actions through the bus). Keeps the engine UI-free.
- `==highlight==` inline markup: double-equals markers around text apply a
  background color (configurable via `MarkdownEditorTheme.highlightColor`,
  default `.systemOrange.withAlphaComponent(0.4)`). Content is recursively parsed so nested emphasis,
  code, etc. work inside highlights.
- `MarkdownEditorBus.applyHighlightRequest` /
  `selectionHighlightDidChange`: bus notification names for driving a
  highlight toolbar button from host UI.
- `MarkdownEditorBus` extended with nine new notification types for
  formatting toolbar integration: `applyStrikethroughRequest`,
  `applyInlineCodeRequest`, `applyBlockquoteRequest`,
  `applyUnorderedListRequest`, `applyOrderedListRequest`,
  `applyLinkRequest`, `applyCodeBlockRequest`,
  `applyHorizontalRuleRequest`, `applyImageRequest`. Embedders wire
  these into `NotificationCenter` to trigger formatting from
  external UI (toolbars, menus) without reaching into the editor's
  view hierarchy.
- New formatting actions on the coordinator (callable directly or
  via the bus above): `didMarkdownStrikethrough`, `didMarkdownInlineCode`,
  `didMarkdownBlockquote`, `didMarkdownLink`, `didMarkdownCodeBlock`,
  `didMarkdownHorizontalRule`, `didMarkdownImage`.
- Word-boundary detection in inline formatting: when the cursor is
  placed inside an English word with no active text selection, bold,
  italic, strikethrough, and inline-code actions now auto-select the
  containing word before wrapping. If no word character is adjacent
  to the cursor, empty markers are inserted as before. The cursor's
  relative offset within the word is preserved after wrapping
  (e.g. `wo|rd` → `**wo|rd**`).
- Headless test suite for formatting actions (`FormattingActionTests`
  — 21 tests covering bold, strikethrough, inline code, blockquote,
  link, code block, horizontal rule, and image insertion).

### Changed
- The engine no longer ships a built-in right-click "Format" context menu — menus
  are now embedder-supplied via `onBuildContextMenu` (above). The system rich-text
  "Font" submenu (Bold/Italic/Show Colors…) is stripped from the default menu, since
  those font traits don't apply to Markdown.

### Fixed
- Blockquote removal no longer doubles trailing newlines when the
  original line already carries one.

## [0.7.1] - 2026-06-20

### Added
- `MarkdownEditorConfiguration.heightBehavior` (`.scrolls` default / `.fitsContent`):
  in `.fitsContent` the editor grows to its content height and reports it to
  SwiftUI, so an enclosing `ScrollView` scrolls the page instead of a nested
  internal scroller. Opt-in, off by default — no change for existing embedders. (#75)
- `BlockquoteStyle` configuration struct with `extraLineHeight` to control line
  spacing inside blockquotes, following the `ListStyle.extraLineHeight` /
  `ParagraphStyle.lineHeightExtraSpacing` pattern. Defaults to `0` (no extra
  spacing), preserving existing rendering. (#76)

### Fixed
- Mouse-wheel / trackball scrolling no longer clamps back at the bottom past a
  stale-small content-height measurement. (#71)
- Inspector clip mask and caret reveal at the document end. (#73)
- Scroll position is remembered per document across switches, and Writing Tools
  results stay styled and visible after accept. (#70)
- Empty-file placeholder no longer clips to one line after a view rebuild. (#69)

### Added
- Scroll-away header: `NativeTextViewWrapper` gains `header: AnyView?`,
  `headerCollapsedHeight: CGFloat`, and `headerExpanded: Bool`. The engine
  hosts the supplied SwiftUI view above the document body, scrolling with
  it; collapsing animates the reserved band down to `headerCollapsedHeight`
  (the top row stays visible, lower rows clip away). The hosted content
  refreshes on every SwiftUI update and stays fully interactive. Composes
  with `readingWidth`. See the README's *Scrolling Header* section.

### Changed
- The scroll view's `documentView` is now always an engine-internal
  container view (hosting the text view, the optional scroll-away header,
  and the reading column's breakout overlays) rather than sometimes the
  `NSTextView` itself. Embedders that reached into
  `scrollView.documentView` expecting an `NSTextView` must adapt — the
  document view's class was never API.
- **Breaking**: The editor's enclosing scroll view no longer applies a
  hard-coded `top: 55.4` content inset. The default is now `0` on every
  edge, matching the most common embedding case where the editor fills
  its container exactly. Embedders that previously relied on the engine
  reserving header space (e.g. for a translucent toolbar) must opt in
  explicitly:

  ```swift
  var config = MarkdownEditorConfiguration.default
  config.safeAreaInsets = SafeAreaInsets(top: 55.4)
  ```

### Added
- `SafeAreaInsets` struct exposing `top` / `leading` / `trailing` / `bottom`
  inset knobs for the editor's enclosing scroll view, configurable via
  `MarkdownEditorConfiguration.safeAreaInsets`.
- `MarkdownASTStyler` now stamps `.spellingState: 0` on fenced code blocks
  and inline `` `code` `` spans, completing the engine's existing
  spell-check suppression convention (links, wiki-links, LaTeX, and tables
  already carry the same attribute). The system spell-checker no longer
  underlines tokens inside code regions even when continuous spell
  checking is enabled.

### Fixed
- Undo is now kept per `documentId`, so Cmd+Z keeps working after switching
  files. The single reused `NSTextView` previously wiped its undo manager on
  every document switch; the editor now vends a per-document `UndoManager`
  (via the new `undoManager(for:)` delegate method) whose undo/redo stack
  survives switching away and back. (#77)
- A document's surviving undo stack is dropped when its text is reloaded
  *changed* while it was switched away (e.g. renaming a node rewrites the
  `[[label]]` in every file that links it), so Cmd+Z can no longer replay
  stale ranges against the rewritten content. (#78)
- `NativeTextViewWrapper` keeps links clickable and text selectable
  when `isEditable: false`; `isSelectable` is no longer coupled to
  `isEditable`. (#31)
- `NativeTextViewWrapper` now applies its initial styling pass even when
  the bound text starts at its final value (e.g. supplied as a SwiftUI
  `@State` initializer). Previously the editor would render the raw
  Markdown source until the user clicked into the document, because the
  coordinator's `lastSyncedText` already matched the bound text at first
  `updateNSView`. The early-return now also requires `didInitialFormatting`
  to be true, which only flips after the first styling pass completes.

### Added
- Initial public API surface:
  - `NativeTextViewWrapper` — SwiftUI bridge for the AppKit-backed editor
  - `MarkdownEditorConfiguration` — every spacing / sizing / behavior knob
  - `MarkdownEditorTheme` — color palette, defaults to system colors
  - `MarkdownEditorServices` — container for the four service protocols
  - Service protocols: `WikiLinkResolver`, `EmbeddedImageProvider`,
    `SyntaxHighlighter`, `LatexRenderer`
  - No-op default implementations: `NoOpWikiLinkResolver`,
    `NoOpEmbeddedImageProvider`, `PlainTextSyntaxHighlighter`,
    `NoOpLatexRenderer`
  - `WikiLinkService` — bidirectional storage / display roundtrip helper
  - `PasteboardImageReader` — pasteboard image inspection helpers
  - Selection / replacement value types: `WikiLinkSelection`,
    `InlineSelectionState`, `InlineReplacementRequest`, `CodeBlockSelection`
  - `CodeBlockButton` — drop-in copy button overlay
- DocC documentation catalog with landing page and topic groups
- Triple-slash documentation comments on the full public API surface

[Unreleased]: https://github.com/nodes-app/swift-markdown-engine/compare/0.7.1...HEAD
[0.7.1]: https://github.com/nodes-app/swift-markdown-engine/compare/0.7.0...0.7.1
