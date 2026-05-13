# Contributing to MarkdownEngine

Thanks for your interest in helping out. This document covers the basics.

## Reporting Bugs

Open a GitHub issue with:

- A clear title summarizing the bug
- A minimal reproducer (the smallest Markdown input + code that triggers it)
- macOS version, Xcode version, and Swift version
- Expected vs actual behavior

If you can paste a screen recording or screenshot, please do.

## Suggesting a Feature

Open a GitHub issue **before** writing code for a non-trivial feature, so
we can talk through the design and avoid wasted effort. Small fixes and
documentation tweaks are welcome as PRs directly.

## Development Setup

Start by forking the repository on GitHub, then clone your fork locally:

```bash
git clone https://github.com/YOUR-USERNAME/swift-markdown-engine.git
cd swift-markdown-engine
git remote add upstream https://github.com/nodes-app/swift-markdown-engine.git
git fetch upstream
swift build
swift test
```

Open `Package.swift` in Xcode for a graphical environment, or use the
command line — both work.

Before starting work, create a branch from the latest upstream `main`:

```bash
git checkout main
git pull upstream main
git checkout -b your-change-name
```

### Generating documentation locally

To preview the DocC catalog locally, add the swift-docc plugin to
`Package.swift` temporarily:

```swift
dependencies: [
    .package(url: "https://github.com/swiftlang/swift-docc-plugin", from: "1.4.0")
]
```

Then run:

```bash
swift package --disable-sandbox preview-documentation --target MarkdownEngine
```

The plugin is intentionally **not** a permanent dependency to keep the
shipped package's transitive deps at zero.

## Coding Conventions

- Follow the [Swift API Design Guidelines](https://www.swift.org/documentation/api-design-guidelines/)
- Public symbols **must** carry triple-slash documentation comments
- Indent with 4 spaces
- Use `// MARK: -` to group related members in larger files
- Keep file headers minimal; the file path implies what it contains
- Favor `internal` over `public` — the smaller the public surface, the
  easier the package is to evolve
- Avoid adding external dependencies. The engine ships with zero deps; that
  is a design constraint, not an accident

## Tests

- Add unit tests for any new tokenizer / styler / service behavior
- Tests live in `Tests/MarkdownEngineTests/`
- Run with `swift test`
- Tests must pass on macOS 14+ with the latest stable Xcode

## Pull Requests

- Branch from `main`
- Keep the change focused — one logical change per PR
- Include test coverage for new behavior
- Update `CHANGELOG.md` under `[Unreleased]` with a one-line summary
- Update DocC docs for any public-API change
- Make sure `swift build` and `swift test` are green locally before
  opening the PR; CI will run the same checks

## Commit Messages

Imperative, concise:

```
Tokenize escaped backticks inside fenced code blocks

The previous tokenizer treated `\`` inside ``` … ``` as a token delimiter,
which broke any code block containing escaped backtick examples. The new
behavior matches CommonMark.
```

A short subject line, an empty line, then a paragraph (or two) explaining
*why* the change exists. The "what" is in the diff.

## License

By contributing, you agree that your contributions will be licensed under
the [MIT License](LICENSE).
