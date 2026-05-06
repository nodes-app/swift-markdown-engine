//
//  MarkdownStyler+Images.swift
//  MarkdownEngine
//
//  Created by Luca Chen on 16.03.26.
//
//  Image embed (`![[...]]`) styling and layout.
//

import AppKit
import Foundation

extension MarkdownStyler {

    // MARK: Image Embeds ![[Name]]

    static func styleImageEmbeds(_ ctx: StylingContext) -> [StyledRange] {
        var attrs: [StyledRange] = []
        for (idx, token) in ctx.tokens.enumerated() where token.kind == .imageEmbed {
            if MarkdownDetection.isInsideCodeBlock(range: token.range, codeTokens: ctx.codeTokens) { continue }

            let isActive = ctx.activeTokenIndices.contains(idx)
            let rawContent = ctx.nsText.substring(with: token.contentRange)
            guard let reference = ImageEmbedReference(content: rawContent) else {
                appendSecondaryMarkers(for: token, to: &attrs, theme: ctx.configuration.theme)
                continue
            }

            if let image = EmbeddedImageCache.shared.image(for: reference, services: ctx.services) {
                let imageEmbedConfig = ctx.configuration.imageEmbed
                // Determine max width from text container
                let maxWidth: CGFloat = {
                    if let tc = ctx.layoutBridge?.firstTextContainer {
                        let w = tc.containerSize.width - tc.lineFragmentPadding * 2
                        if w > 0 && w < imageEmbedConfig.unreasonableMaxWidth { return w }
                    }
                    return imageEmbedConfig.fallbackMaxWidth
                }()

                let minWidth = imageEmbedConfig.minimumWidth
                let imageSize = image.size
                let targetWidth: CGFloat
                if let rw = reference.requestedWidth, rw > 0 {
                    targetWidth = min(max(rw, minWidth), maxWidth)
                } else {
                    targetWidth = min(imageSize.width, maxWidth)
                }
                let scale = targetWidth / imageSize.width
                let displayWidth = imageSize.width * scale
                let displayHeight = imageSize.height * scale
                let imageBounds = CGRect(x: 0, y: 0, width: displayWidth, height: displayHeight)
                let rendered: Bool
                if isActive {
                    rendered = appendRenderedStandaloneBlock(
                        for: token,
                        rawContent: rawContent,
                        image: image,
                        imageBounds: imageBounds,
                        paragraphSpacingBefore: imageEmbedConfig.paragraphSpacing,
                        paragraphSpacing: imageEmbedConfig.paragraphSpacing,
                        alignment: .left,
                        mode: .visibleSource(imageGap: imageEmbedConfig.imageGap),
                        ctx: ctx,
                        attrs: &attrs
                    )
                } else {
                    rendered = appendRenderedStandaloneBlock(
                        for: token,
                        rawContent: rawContent,
                        image: image,
                        imageBounds: imageBounds,
                        paragraphSpacingBefore: imageEmbedConfig.paragraphSpacing,
                        paragraphSpacing: imageEmbedConfig.paragraphSpacing,
                        alignment: .left,
                        mode: .collapsedSource(markerTexts: ["![[", "]]"]),
                        ctx: ctx,
                        attrs: &attrs
                    )
                }
                if !rendered {
                    appendSecondaryMarkers(for: token, to: &attrs, theme: ctx.configuration.theme)
                }
            } else {
                // Image not found — show syntax with marker coloring (like broken link)
                appendSecondaryMarkers(for: token, to: &attrs, theme: ctx.configuration.theme)
            }
        }
        return attrs
    }
}
