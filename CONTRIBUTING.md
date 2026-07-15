# Contributing to MarkdownEngine

Thanks for your interest. **MarkdownEngine is maintained by one person —
expect 1–2 weeks for review.** Small fixes and documentation tweaks are
welcome as PRs directly; for non-trivial features please open an issue
first so we can talk through the design.

> **New here?** Start with [ARCHITECTURE.md](ARCHITECTURE.md) — a
> codemap that walks each directory in the order text flows through
> the engine.

## Development setup

```bash
git clone https://github.com/nodes-app/swift-markdown-engine.git
cd swift-markdown-engine
swift build
swift test
```

Open `Package.swift` in Xcode for a graphical environment. The runnable
demo is in `Demo/MarkdownEngineDemo.xcodeproj` — open and **Run** to see
your changes against a real app target.

### Local DocC preview

Temporarily add the [swift-docc-plugin](https://github.com/swiftlang/swift-docc-plugin)
to `Package.swift`, then `swift package --disable-sandbox preview-documentation
--target MarkdownEngine`. It's intentionally not a permanent dependency — the
core product stays free of optional tooling.

## Reporting bugs

Include:

- A minimal reproducer (the smallest Markdown input + code that triggers
  it)
- macOS, Xcode, and Swift versions
- Expected vs. actual behavior

Screen recordings welcome.

## Pull requests

- One logical change per PR, branched from `main`
- Tests for new tokenizer / styler / service / extension behavior in
  `Tests/MarkdownEngineTests/`
- DocC comments for any public-API change; update `Demo/` if relevant
- One-line entry in `CHANGELOG.md` under `[Unreleased]`
- `swift build` and `swift test` must be green; CI runs the same checks

## Design constraints

Non-negotiable for the core `MarkdownEngine` target:

- **Don't add external dependencies to the core `MarkdownEngine`
  target.** App-specific behaviors plug in through the four service
  protocols (`WikiLinkResolver`, `EmbeddedImageProvider`,
  `SyntaxHighlighter`, `LatexRenderer`) instead. The two existing
  bridge products (`MarkdownEngineCodeBlocks` → HighlighterSwift,
  `MarkdownEngineLatex` → SwiftMath) are the deliberate exception so
  consumers can opt in. New bridges or new core deps need an issue
  first.
- **New constructs are extensions, not core grammar.** A construct like
  `==highlight==` (inline) or a `::: … :::` fenced block belongs in
  `Sources/MarkdownEngine/Extensions/` as a `MarkdownExtension` — see
  `HighlightExtension` / `ContainerExtension` as templates — never a new case
  threaded through the parser, styler, and renderer. This keeps the core pure
  markdown and each construct isolated. Image/overlay-rendered constructs
  (tables, math) are the exception — they still need core work; open an issue
  first.
- **Public surface stays small.** Favor `internal`; new public symbols
  need a DocC comment.

## Commit messages

Imperative subject, blank line, then a paragraph explaining *why*:

```
Tokenize escaped backticks inside fenced code blocks

The previous tokenizer treated `\`` inside ``` … ``` as a token
delimiter, which broke any code block containing escaped backtick
examples. The new behavior matches CommonMark.
```

The "what" is in the diff.

## License

By contributing, you agree that your contributions are licensed under
the [Apache 2.0 License](LICENSE).
