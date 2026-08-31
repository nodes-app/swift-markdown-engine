# Changelog

All notable changes to swift-markdown-engine are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added
- **Directive seam (parsing)**: opt-in named inline commands with typed
  arguments, for constructs that need a name and parameters rather than
  delimiters. A `MarkdownDirective` declares a name, a form — self-contained
  (`@pagebreak`) or container (`@font(size: 18){text}`) — and a parameter
  schema; register instances via `MarkdownEditorConfiguration.directives`.
  Directives never emit ranges and project into the AST as extension-shaped
  nodes under a reserved `directive.` id namespace, so marker shrink, caret
  reveal, token projection, incremental restyle, and rich copy apply unchanged.
  The directive registry folds into the existing grammar fingerprint, so a
  directive-free registry is byte-identical to before. The marker defaults to
  `@` and is configurable per registry and per directive; unregistered names
  stay literal text. Styling and autocomplete follow separately. A directive whose body
  contains a span claimed by an earlier pass — a code span or a backslash
  escape — stays literal as a whole; constructs claimed in the same pass or
  later (`$…$`, links, emphasis, nesting) compose normally.
- **Directive styling**: a container directive's `style` composes over the font
  inherited at that point in the tree, so `@font(size: 18){**bold**}` is bold
  AND 18pt rather than one overwriting the other. `FontDirective` and
  `ColorDirective` ship as opt-in reference directives, off by default like the
  bundled extensions. `MarkdownHTMLRenderer.html(from:extensions:directives:)`
  takes the registered set so rich copy matches what is on screen.
- `NativeTextViewWrapper.onTextMutation` reports exact, completed native edits
  for embedders that maintain their own source authority or mirror edits into
  another presentation.
- `MarkdownEditorConfiguration.thematicBreak` (`ThematicBreakStyle`) gives each
  thematic-break marker its own look. CommonMark treats `---`, `***` and `___`
  as one construct with one rendering, so an embedder who wanted a novel-style
  star divider on `***` had no way to ask for one without inventing syntax.
  Setting `asteriskMark` draws that string centred in the text container in
  place of the full-width rule; `dashMark` and `underscoreMark` do the same for
  their markers. All three default to nil, so every existing embedder keeps the
  rule it already has. Presentation only — the source text is untouched, the
  caret still reveals the raw `***`, the construct still exports as `<hr>`, and
  a document written this way reads correctly in any other editor. The mark is
  a literal string rather than a symbol name, so pick one whose glyphs exist in
  every font you ship: a glyph the body font lacks does not draw as tofu, it
  silently falls back to another typeface (`⁂` asked for in a serif renders as
  Helvetica), and the engine cannot tell that from a deliberate choice. A mark carries a `scale` (a multiple of the
  body font size, 1 by default), and above 1 the break's line grows to fit
  rather than the mark overlapping its neighbours. Marks are centred on their
  INK rather than their layout box, because a glyph like `*` is drawn high in
  its em — its optical centre sits about a quarter of the font size above the
  lowercase centre, and that gap grows with the size, so box-centring would let
  a larger mark climb toward the top of its line.

### Changed
- An ordered list's painted number no longer reverts to the source digit under
  the caret or a selection. The number is positional, so in a run written
  `1./1./1.` a click inside a marker — or a select-all — flipped every number
  below an insertion back to whatever the file happens to say. The source marker
  is hidden by size now, like every other marker the engine hides: a selection
  repaints selected glyphs opaque, so a colour-hidden marker came back under the
  highlight and collided with the number drawn over it. The marker's
  caret-crossing restyle signal went with the reveal.

### Performance
- Scoped restyles inside a contiguous list parse and style only intersecting
  items instead of rebuilding the whole list block. Marker, indentation,
  line-break, programmatic, and undo/redo edits still widen ordered-list runs
  when downstream display numbers can change.

### Fixed
- A live swap of `MarkdownEditorConfiguration` now reaches the styler. Only a
  handful of fields (`heightBehavior`, `rawSourceMode`, `lists`, and the
  fingerprint-gated `services` / `extensions` / `directives`) used to sync in
  `updateNSView`; everything else — `theme`, `paragraph`, `link`, `markers`,
  `codeBlock`, `inlineCode`, `taskCheckbox`, `blockquote`, `headings`,
  `imageEmbed`, `blockLatex`, `inlineLatex`, `thematicBreak`,
  `cursorFollowsSpanInk` — was captured once in `makeCoordinator` and never
  refreshed, so an embedder flipping between two configurations (a light/dark
  palette toggle, a heading-metric change, a link-ink update) kept whatever
  those fields were at first mount. `updateNSView` now compares the pure-style
  fields via an internal `styleSignature`, copies them across when they
  differ, and forces a rebuild so the new palette / metrics reach text
  storage. The fingerprint-gated paths above stay as they were — services and
  grammar changes still restyle through their own branches, and a
  configuration whose style fields are unchanged pays only a struct compare.
  Value-typed configuration sub-structs (`MarkdownEditorTheme`, `MarkerStyle`,
  `HeadingStyle`, `LinkStyle`, `ParagraphStyle`, and the rest) now conform to
  `Equatable` so the compare is a synthesized member-by-member check rather
  than a bespoke traversal.

## [0.12.0] - 2026-08-10

### Added
- `onPersistScrollOffset` / `restoreScrollOffset` on `NativeTextViewWrapper` —
  scroll memory an embedder can keep somewhere that outlives the editor. The
  engine's own per-document offsets live on the coordinator, so an embedder that
  routes to a different screen and back lost them: nothing recorded the offset on
  the way out (there was no `dismantleNSView` at all), and the restore was gated
  on a document switch, which a remount is not — `makeCoordinator` seeds
  `documentId`, so the first update pass never looks like one. Teardown now hands
  the offset over, and the restore is latched instead of gated, retrying for a
  bounded few passes because the first pass after a remount still carries the
  embedder's empty buffer. Both closures are asked at call time, so the
  embedder's own retention rules can see changes made on the way out. Passing
  neither leaves behavior unchanged.

- `NSAttributedString.Key.markdownBlockBackground` — a background painted
  across the whole line box by `MarkdownTextLayoutFragment` instead of the
  glyph box AppKit's `.backgroundColor` covers. Embedder extensions can use it
  wherever a fill should read as a block.

### Changed
- **Inline parse cost is linear in the spans per region, not quadratic.** Every
  pass after the first consulted the claimed ranges by scanning the whole array
  — once per character in `scanEscapes` and `collectDelimiterRuns`, once per
  candidate in `scanLinkFamily` — and `buildTree` decided containment by testing
  each span against every other. The passes walk the string left to right and
  claimed ranges never partially overlap, so a cursor over the sorted ranges answers both
  questions in amortised constant time, and sorting spans by start ascending /
  length descending turns containment into a single ordered walk. A paragraph of
  240 code spans parses in 0.5ms rather than 33ms; 6x the spans now costs 6x the
  parse instead of ~30x. Affects every claimed-span construct — code, escapes,
  links, images, wiki links, inline LaTeX, emphasis, and extension spans. No
  parse result changes.
- `==highlight==` fills the line box. AppKit paints `.backgroundColor` over
  ascent + descent only, so the marker fell short of the line height by the
  leading plus `paragraph.lineHeightExtraSpacing`, and a highlight that wrapped
  came out as a stack of bands. `HighlightExtension` returns
  `.markdownBlockBackground` now, so the block is continuous at any font size.
  Table cells rasterize their own text and keep the glyph-box fill.

### Fixed
- Bare URLs and emails survive rich copy as real links. The editor styler
  linkifies them with `NSDataDetector`, but the HTML renderer emitted them as
  plain text, so the pasteboard's HTML/RTF/web-archive flavors carried no anchor
  at all, and whether a copied URL arrived clickable was left to the receiving
  app — Apple Mail runs its own detection and linkifies anyway, a consumer that
  takes the rich flavor verbatim pastes dead text. `MarkdownHTMLRenderer` now
  wraps detector matches in `<a href>` (emails as `mailto:`) using the same
  system detector as the styler; the RTF and web-archive flavors are derived
  from that HTML, so all three inherit the link. Explicit `[title](url)` links
  were already correct; a URL-shaped run inside a link's own title stays plain
  so anchors never nest, and code spans remain excluded, matching the styler.
  Table cells are unaffected: they render no inline markup on the copy path.
- Markdown link labels may hold inline code and escaped punctuation —
  ``[`App`](/tmp/App.swift:56)`` stayed literal. Code spans and escapes are
  claimed before links so they stay opaque, and the link pass rejected every
  candidate overlapping a claimed span, including one lying entirely inside the
  label. Spans contained in the label are permitted now, links act as
  containers when the tree is built, and partial overlaps or spans crossing the
  label boundary are still rejected.
- Initially narrow tables reflow when the editor width shrinks instead of
  retaining stale image geometry until an unrelated full restyle.

## [0.11.0] - 2026-07-31

### Added
- **Ordered lists render their position.** An item's number is computed from its
  place in the run and painted over the source digits, so typing, deleting,
  merging and pasting renumber live. The `.md` file is never rewritten — the
  source stays valid CommonMark whatever it says. The whole source marker is
  hidden as one unit and the slot is kerned to the display width, so the dot
  travels with the digits at any digit count; the raw digits are revealed while
  they are edited.
- `MarkdownEditorConfiguration.cursorFollowsSpanInk` (opt-in, off by default):
  the caret and the I-beam take the ink of the extension span they sit in. It
  matters for an extension that INVERTS its content — dark ink on a light block
  — where both cursors are otherwise drawn in the block's own color and
  disappear inside it. `InvertedIBeamCursor` recolors the live `NSCursor.iBeam`
  image, which keeps the system shape and the user's pointer size.

### Fixed
- Find-in-document no longer erases other backgrounds. Clearing its highlights
  removed `.backgroundColor` across the whole document, which blanked extension
  spans, code fences and table cells until some unrelated restyle repainted
  them. Find now marks its own backgrounds and restyles only the paragraphs it
  touched.

### Performance
- **Large notes open ~14× faster.** Measured on a 346k-char / 5,241-block note
  (Release): first open 19.5 s → 1.35 s, warm open 1.1 s → 590 ms, switching
  away 440 ms → 115 ms. Styling is built on a detached string and transferred
  with one `setAttributedString` — per-key `addAttribute` on live TextKit-2
  storage left weak tombstones in Foundation's attribute-intern table, which
  turned quadratic. The restyle apply uses a paragraph overlap index above 32
  paragraphs, the redundant second full-document parse and the re-entrant
  full-document layout during rebuild are gone, and the SwiftMath render cache
  persists to disk (717 ms → 35 ms on relaunch, byte-identical geometry).
- **Editing long ordered lists.** One Return in an 800-item loose list:
  944 ms → 67 ms (was quadratic in list length). Typing in a 1,600-item ordered
  list: 89 ms → 41 ms per key. Resolving the caret ink across 1,600 spans:
  0.134 ms → 0.002 ms per keystroke.

### Known limitations
- A list item's continuation line is a paragraph and ends the run, so a
  multi-line item switches numbering off below it.
- A loose list keeps stale numbers after a pure digit edit (a digit edit is not
  classified as structural).
- Ordered task items (`1. [ ] x`) consume a number but render none.

## [0.10.1] - 2026-07-22

### Added
- Custom SF Symbols for task checkboxes: `MarkdownEditorConfiguration` accepts
  custom unchecked and checked symbols for `- [ ]` / `- [x]` task-list items
  (opt-in; the defaults are unchanged).

### Fixed
- List markers no longer disappear while a selection covers them, and selecting
  a list item now reveals its raw marker syntax like other inline constructs.
- An unclosed ``` fence no longer swallows the rest of the document: typing an
  opening fence above existing content left every block below it (tables,
  block LaTeX, thematic breaks, links) unrendered until the closing fence was
  typed. A fence now forms a code block only once its closing fence exists.

## [0.10.0] - 2026-07-15

### Added
- **Extension seam**: opt-in constructs beyond pure markdown. A
  `MarkdownExtension` contributes an inline form (`==highlight==`), a fenced
  block form (`::: … :::`), or both — plus content attributes and an HTML
  wrapper for the clean-copy path; register instances via
  `MarkdownEditorConfiguration.extensions`. Extensions never emit ranges — the
  parser derives all geometry, so a misbehaving extension can at worst restyle
  its own construct. Marker/fence hiding, caret reveal, incremental restyle,
  table cells, and rich copy are handled generically. Registered extensions can
  change at runtime; all parse caches key on the registry.
- `HighlightExtension` (`==text==`) and `StrikethroughExtension` (`~~text~~`),
  the former built-ins repackaged as extensions, and `ContainerExtension`
  (`::: … :::`), the first fenced block extension.

### Changed
- **Breaking**: `==highlight==` and `~~strikethrough~~` are no longer part of
  the core grammar. Unregistered, the syntax stays literal text. To keep the
  previous behavior:
  `configuration.extensions = [HighlightExtension(), StrikethroughExtension()]`.
  The formatting actions (context menu, `applyHighlightRequest` /
  `applyStrikethroughRequest`) still insert/remove the markers either way;
  construct detection (toggle-off, selection state) requires the extension.

### Fixed
- A pre-existing incremental-parse gap surfaced by the seam review:
  backspace-joining two paragraphs could leave transiently wrong styling
  (extra spacing or a stray emphasis/code span across the join) until the next
  edit re-parsed the region.

## [0.9.0] - 2026-07-13

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
- Find & replace: two optional bus notifications, `replaceCurrent` (replace the
  focused match and advance) and `replaceAll` (replace every match in one undo
  step, back-to-front so ranges stay valid). Both edit the engine's displayed
  text with proper `shouldChangeText`/`didChangeText` undo registration and
  report the remaining count via `findResults`. Purely additive — embedders that
  don't set the bus names are unaffected.
- Clean clipboard: ⌘C copies the selection as rich text (RTF + `com.apple.webarchive`)
  built from the AST rather than the raw storage form, and paste converts HTML to
  Markdown. Wiki-link `[[Name|UUID]]` side-channels no longer leak into copied text.

### Fixed
- Find/jump scroll now works without a reading column. The TextKit 2
  fragment-enumeration scroll path (with `.ensuresLayout`) runs universally
  instead of only when `readingWidth` was set; the unreliable
  `NSTextView.scrollRangeToVisible` (which routes through the absent TextKit 1
  layout manager for off-screen content) is now only the last-resort fallback.
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
- Wiki links: UUID-robust labels/embeds and keyboard navigation in the inline
  autocomplete list.

### Contributors
- Find/jump scroll fix and find & replace by @ChristineTham
- Inline syntax-marker color fix by @sospartan
- rawSourceMode, clean clipboard, web-link edit zone, and wiki-link robustness by @luca-chen198

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
