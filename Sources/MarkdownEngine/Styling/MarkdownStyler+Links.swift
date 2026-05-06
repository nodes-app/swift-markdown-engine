//
//  MarkdownStyler+Links.swift
//  MarkdownEngine
//
//  Created by Luca Chen on 16.03.26.
//
//  Auto-detected URLs, [text](url) Markdown links, and [[Name]] wiki links.
//

import AppKit
import Foundation

extension MarkdownStyler {

    // MARK: Auto-detected plain URLs

    static func styleAutoLinks(_ ctx: StylingContext) -> [StyledRange] {
        var attrs: [StyledRange] = []
        guard let detector = MarkdownStyler.linkDataDetector else { return attrs }

        // Scope to edited paragraphs when provided; avoids full-doc URL scan per keystroke.
        let rangesToScan: [NSRange]
        if let scoped = ctx.scopedRanges, !scoped.isEmpty {
            rangesToScan = scoped.compactMap { range in
                let clipped = NSIntersectionRange(range, ctx.fullRange)
                return clipped.length > 0 ? clipped : nil
            }
        } else {
            rangesToScan = [ctx.fullRange]
        }

        for range in rangesToScan {
            detector.enumerateMatches(in: ctx.text, options: [], range: range) { match, _, _ in
                guard let match = match, let url = match.url else { return }
                if MarkdownDetection.isInsideCodeBlock(range: match.range, codeTokens: ctx.codeTokens) { return }
                attrs.append((match.range, [.link: url]))
            }
        }
        return attrs
    }

    // MARK: Wiki Links [[Name]]

    static func styleWikiLinks(_ ctx: StylingContext, wikiLinkIDProvider: (NSRange) -> String?) -> [StyledRange] {
        var attrs: [StyledRange] = []
        for (index, token) in ctx.tokens.enumerated() where token.kind == .wikiLink {
            if MarkdownDetection.isInsideCodeBlock(range: token.range, codeTokens: ctx.codeTokens) { continue }
            attrs.append((token.range, [NSAttributedString.Key.spellingState: 0]))
            let nodeName = ctx.nsText.substring(with: token.contentRange)
            let linkID = wikiLinkIDProvider(token.range)
            var contentAttributes: [NSAttributedString.Key: Any] = [:]
            if let linkID {
                contentAttributes[.wikiLinkID] = linkID
            }
            let isActive = ctx.activeTokenIndices.contains(index)
            // Check if the linked node actually exists, using whichever resolver
            // the embedder supplied via configuration.services.
            let nodeExists: Bool = {
                if let resolution = ctx.services.wikiLinks.resolve(displayName: nodeName, range: token.contentRange) {
                    return resolution.exists
                }
                return false
            }()
            if !isActive {
                if nodeExists {
                    contentAttributes[.link] = linkID ?? nodeName
                } else {
                    contentAttributes[.foregroundColor] = ctx.configuration.theme.disabledText
                }
            }
            if !contentAttributes.isEmpty {
                attrs.append((token.contentRange, contentAttributes))
            }
            for markerRange in token.markerRanges {
                attrs.append((markerRange, [.foregroundColor: ctx.configuration.theme.mutedText]))
            }
        }
        return attrs
    }

    // MARK: Markdown Links [Text](URL)

    static func styleMarkdownLinks(_ ctx: StylingContext) -> [StyledRange] {
        var attrs: [StyledRange] = []
        for (idx, token) in ctx.tokens.enumerated() where token.kind == .link {
            if MarkdownDetection.isInsideCodeBlock(range: token.range, codeTokens: ctx.codeTokens) { continue }
            attrs.append((token.range, [NSAttributedString.Key.spellingState: 0]))
            let fullMatch = ctx.nsText.substring(with: token.range)
            if let urlStart = fullMatch.firstIndex(of: "("), let urlEnd = fullMatch.lastIndex(of: ")") {
                let rawUrl = String(fullMatch[fullMatch.index(after: urlStart)..<urlEnd])
                var urlCandidate = rawUrl
                if !urlCandidate.contains("://") {
                    urlCandidate = "https://\(urlCandidate)"
                }
                let isActive = ctx.activeTokenIndices.contains(idx)
                if let url = URL(string: urlCandidate) {
                    if isActive {
                        attrs.append((token.contentRange, [
                            .foregroundColor: ctx.configuration.theme.link.withAlphaComponent(ctx.configuration.link.activeLinkAlpha)
                        ]))
                    } else {
                        attrs.append((token.contentRange, [
                            .link: url,
                            .underlineStyle: NSUnderlineStyle.single.rawValue,
                            .foregroundColor: ctx.configuration.theme.link
                        ]))
                    }
                }
                for m in token.markerRanges {
                    attrs.append((m, [.foregroundColor: ctx.configuration.theme.mutedText]))
                }
            }
        }
        return attrs
    }
}
