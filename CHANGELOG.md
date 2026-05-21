# Changelog

All notable changes to swift-markdown-engine are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Changed
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

### Fixed
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

[Unreleased]: https://github.com/nodes-app/swift-markdown-engine/compare/HEAD
