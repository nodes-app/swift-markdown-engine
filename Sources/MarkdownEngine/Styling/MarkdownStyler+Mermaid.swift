//
//  MarkdownStyler+Mermaid.swift
//  MarkdownEngine
//
//  Renders ```mermaid fenced blocks to an image via the embedder's
//  MermaidRenderer service, emitted through the same collapsed-source path that
//  block-LaTeX and tables use (the source stays in the document; the user sees
//  the rendered diagram). Gated by `configuration.renderMermaid`, so a host can
//  show the raw fence in Code view by turning the flag off there.
//

import AppKit

extension MarkdownStyler {

    static func styleMermaidBlocks(_ ctx: StylingContext) -> [StyledRange] {
        guard ctx.configuration.renderMermaid else { return [] }
        var attrs: [StyledRange] = []
        let ns = ctx.nsText

        for token in ctx.tokens where token.kind == .codeBlock {
            let parts = MarkdownASTStyler.codeBlockParts(token.range, ns)
            guard parts.language?.lowercased() == "mermaid" else { continue }

            let source = ns.substring(with: parts.content).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !source.isEmpty,
                  let result = ctx.services.mermaid.render(mermaid: source, theme: ctx.configuration.theme)
            else { continue }

            // Synthesize a token describing the fenced block so the standalone
            // collapse path can hide the source and show the image in its place.
            let blockToken = MarkdownToken(
                kind: .codeBlock,
                range: token.range,
                contentRange: parts.content,
                markerRanges: [parts.openFence, parts.closeFence]
            )
            let imageBounds = CGRect(x: 0, y: 0, width: result.size.width, height: result.size.height)
            let containerWidth = effectiveContainerWidth(for: ctx)
            let isWide = result.size.width > containerWidth + 0.5
            let mode: RenderedStandaloneBlockMode = isWide
                ? .collapsedSourceScrollable(
                    markerTexts: [],
                    displayWidth: containerWidth,
                    sourceID: stableMermaidSourceID(for: source, range: token.range)
                )
                : .collapsedSource(markerTexts: [])

            _ = appendRenderedStandaloneBlock(
                for: blockToken,
                rawContent: ns.substring(with: parts.content),
                image: result.image,
                imageBounds: imageBounds,
                paragraphSpacingBefore: ctx.baseDefaultLineHeight * 0.5,
                paragraphSpacing: ctx.baseDefaultLineHeight * 0.5,
                alignment: .center,
                mode: mode,
                ctx: ctx,
                attrs: &attrs
            )
            // Tag the collapsed block so a click can be detected → open a zoom view.
            attrs.append((token.range, [.mermaidSource: source]))
        }
        return attrs
    }

    private static func stableMermaidSourceID(for source: String, range: NSRange) -> Int {
        var hasher = Hasher()
        hasher.combine("mermaid")
        hasher.combine(source)
        hasher.combine(range.location)
        return hasher.finalize()
    }
}
