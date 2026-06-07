// swift-tools-version: 5.9
import PackageDescription

// MarkdownEngine — a TextKit-2 backed Markdown editor view for macOS.
//
// Embedders import `MarkdownEngine` and supply their own adapters that conform to
// the engine's service protocols (`WikiLinkResolver`, `EmbeddedImageProvider`,
// `SyntaxHighlighter`, `LatexRenderer`). The core engine has zero external
// dependencies.
//
// This build declares only the core `MarkdownEngine` product. The optional
// turnkey bridges (`MarkdownEngineCodeBlocks` → HighlighterSwift,
// `MarkdownEngineLatex` → SwiftMath) are omitted so the package resolves with no
// transitive dependencies; their source folders remain in the tree but are not
// built. Re-add the products + dependencies here to enable them.
let package = Package(
    name: "MarkdownEngine",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "MarkdownEngine", targets: ["MarkdownEngine"]),
    ],
    targets: [
        .target(name: "MarkdownEngine"),
    ]
)
