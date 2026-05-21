// swift-tools-version: 5.9
import PackageDescription

// MarkdownEngine — a TextKit-2 backed Markdown editor view for macOS.
//
// Embedders import `MarkdownEngine` and supply their own adapters that
// conform to the engine's service protocols (`WikiLinkResolver`,
// `EmbeddedImageProvider`, `SyntaxHighlighter`, `LatexRenderer`). The engine
// itself has zero external dependencies.
//
// Users who want turnkey adapters for the two highest-friction protocols
// (code-block styling/highlighting, LaTeX rendering) can additionally
// depend on the `MarkdownEngineCodeBlocks` and/or `MarkdownEngineLatex`
// products, which ship pre-built bridges backed by HighlighterSwift and
// SwiftMath respectively. Both products are opt-in: the core
// `MarkdownEngine` library stays free of those transitive dependencies
// at link time.
let package = Package(
    name: "MarkdownEngine",
    platforms: [.macOS(.v14), .iOS(.v16)],
    products: [
        .library(name: "MarkdownEngine", targets: ["MarkdownEngine"]),
        .library(name: "MarkdownEngineCodeBlocks", targets: ["MarkdownEngineCodeBlocks"]),
        .library(name: "MarkdownEngineLatex", targets: ["MarkdownEngineLatex"]),
    ],
    dependencies: [
        .package(url: "https://github.com/smittytone/HighlighterSwift", from: "3.0.0"),
        .package(url: "https://github.com/mgriebling/SwiftMath", from: "1.7.0"),
    ],
    targets: [
        .target(name: "MarkdownEngine"),
        .target(
            name: "MarkdownEngineCodeBlocks",
            dependencies: [
                "MarkdownEngine",
                .product(name: "Highlighter", package: "HighlighterSwift"),
            ]
        ),
        .target(
            name: "MarkdownEngineLatex",
            dependencies: [
                "MarkdownEngine",
                .product(name: "SwiftMath", package: "SwiftMath"),
            ]
        ),
        .testTarget(
            name: "MarkdownEngineTests",
            dependencies: ["MarkdownEngine"]
        )
    ]
)
