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
// products, which ship pre-built bridges backed by a bundled highlight.js
// and SwiftMath respectively. Both products are opt-in: the core
// `MarkdownEngine` library stays free of them at link time.
//
// The grammar is its own Foundation-only target, `MarkdownEngineSyntax`,
// which `MarkdownEngine` depends on and re-exports. It is also a library
// product, for an app that reads documents without the editor.
let package = Package(
    name: "MarkdownEngine",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "MarkdownEngine", targets: ["MarkdownEngine"]),
        .library(name: "MarkdownEngineSyntax", targets: ["MarkdownEngineSyntax"]),
        .library(name: "MarkdownEngineCodeBlocks", targets: ["MarkdownEngineCodeBlocks"]),
        .library(name: "MarkdownEngineLatex", targets: ["MarkdownEngineLatex"]),
    ],
    dependencies: [
        .package(url: "https://github.com/mgriebling/SwiftMath", from: "1.7.0"),
    ],
    targets: [
        .target(name: "MarkdownEngineSyntax"),
        .target(name: "MarkdownEngine", dependencies: ["MarkdownEngineSyntax"]),
        .target(
            name: "MarkdownEngineCodeBlocks",
            dependencies: ["MarkdownEngine"],
            resources: [
                .copy("Resources/highlight.min.js"),
                .copy("Resources/highlight.js-LICENSE.txt"),
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
            name: "MarkdownEngineSyntaxTests",
            dependencies: ["MarkdownEngineSyntax"]
        ),
        .testTarget(
            name: "MarkdownEngineTests",
            dependencies: ["MarkdownEngine", "MarkdownEngineSyntax"]
        ),
        .testTarget(
            name: "MarkdownEngineCodeBlocksTests",
            dependencies: ["MarkdownEngine", "MarkdownEngineCodeBlocks"]
        ),
        .testTarget(
            name: "MarkdownEngineLatexTests",
            dependencies: ["MarkdownEngine", "MarkdownEngineLatex"]
        )
    ]
)
