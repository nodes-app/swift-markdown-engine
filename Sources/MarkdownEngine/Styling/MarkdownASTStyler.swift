//
//  MarkdownASTStyler.swift
//  MarkdownEngine
//
//  Phase 2.5 — the AST-native styler. Walks the document AST and emits
//  [StyledRange], COMPOSING attributes on descent: a heading sets a large bold
//  font, descending into bold adds the bold trait (keeping the size), into
//  italic adds italic — so nested/combined inline styles stack instead of
//  overwriting each other (the flaw in the flat 18-pass styler, e.g. the
//  shrinking bold in `# **n*o*des**`).
//
//  Built incrementally behind the existing styler; not wired until complete
//  and visually verified. Covered so far: heading/paragraph/blockquote blocks;
//  inline emphasis (font composition), strikethrough, inline code, markdown
//  links, wiki links. Still TODO: images, image embeds, inline LaTeX, escapes,
//  autolinks, marker-shrinking, paragraph styles, code/table/latex blocks,
//  bullets, task checkboxes, horizontal rules.
//

import AppKit
import Foundation

enum MarkdownASTStyler {

    static func styleAttributes(
        text: String,
        fontName: String,
        fontSize: CGFloat,
        caretLocation: Int = -1,
        wikiLinkIDProvider: @escaping (NSRange) -> String? = { _ in nil },
        configuration: MarkdownEditorConfiguration = .default
    ) -> [StyledRange] {
        let baseFont = NSFont(name: fontName, size: fontSize) ?? .systemFont(ofSize: fontSize)
        let codeFontSize = round(fontSize * configuration.codeBlock.fontSizeScale)
        let hiddenSize = configuration.markers.hiddenMarkerFontSize
        let ctx = Ctx(
            ns: text as NSString,
            fontName: fontName,
            baseFont: baseFont,
            codeFont: configuration.services.syntaxHighlighter.codeFont(size: codeFontSize),
            codeBackground: configuration.services.syntaxHighlighter.backgroundColor(),
            inlineMarkerFont: NSFont(name: fontName, size: hiddenSize) ?? .systemFont(ofSize: hiddenSize),
            caret: caretLocation,
            config: configuration,
            wikiLinkID: wikiLinkIDProvider
        )
        let blocks = DocumentAST.parse(text)
        var attrs: [StyledRange] = []
        for block in blocks {
            styleBlock(block, font: baseFont, ctx: ctx, into: &attrs)
        }
        shrinkInactiveMarkers(in: blocks, ctx: ctx, into: &attrs)
        return attrs
    }

    /// Shared inputs threaded through the walk.
    private struct Ctx {
        let ns: NSString
        let fontName: String
        let baseFont: NSFont
        let codeFont: NSFont
        let codeBackground: NSColor
        let inlineMarkerFont: NSFont
        let caret: Int
        let config: MarkdownEditorConfiguration
        let wikiLinkID: (NSRange) -> String?

        func isActive(_ range: NSRange) -> Bool { NSLocationInRange(caret, range) }
        var theme: MarkdownEditorTheme { config.theme }
    }

    // MARK: - Blocks

    private static func styleBlock(_ block: BlockNode, font: NSFont, ctx: Ctx, into attrs: inout [StyledRange]) {
        switch block {
        case .paragraph(_, let inlines):
            styleInlines(inlines, font: font, ctx: ctx, into: &attrs)

        case .heading(let level, let range, let markers, let inlines):
            let multiplier = ctx.config.headings.fontMultiplier(for: level)
            let headingBase = NSFont(name: ctx.fontName, size: ctx.baseFont.pointSize * multiplier)
                ?? .systemFont(ofSize: ctx.baseFont.pointSize * multiplier)
            let headingFont = adding(.bold, to: headingBase)
            attrs.append((range, [.font: headingFont]))
            for marker in markers {
                attrs.append((marker, [.foregroundColor: ctx.theme.headingMarker]))
            }
            styleInlines(inlines, font: headingFont, ctx: ctx, into: &attrs)

        case .blockquote(_, let inlines):
            styleInlines(inlines, font: font, ctx: ctx, into: &attrs)   // bar/indent/muting in 2.5c

        case .codeBlock, .blockLatex, .table, .thematicBreak, .blank:
            break   // block rendering ported in later increments
        }
    }

    // MARK: - Inlines (composing)

    private static func styleInlines(_ nodes: [InlineNode], font: NSFont, ctx: Ctx, into attrs: inout [StyledRange]) {
        for node in nodes {
            switch node {
            case .text:
                break

            case .emphasis(let kind, _, let markers, let children):
                let composed = adding(traits(for: kind), to: font)
                attrs.append((content(of: markers), [.font: composed]))
                styleInlines(children, font: composed, ctx: ctx, into: &attrs)

            case .strikethrough(_, let markers, let children):
                attrs.append((content(of: markers), [
                    .strikethroughStyle: NSUnderlineStyle.single.rawValue,
                    .strikethroughColor: ctx.theme.strikethroughColor,
                ]))
                styleInlines(children, font: font, ctx: ctx, into: &attrs)

            case .code(let range, let contentRange):
                attrs.append((contentRange, [.font: ctx.codeFont, .backgroundColor: ctx.codeBackground]))
                let markerAttrs: [NSAttributedString.Key: Any] = ctx.isActive(range)
                    ? [.foregroundColor: ctx.theme.mutedText, .font: ctx.codeFont]
                    : [.foregroundColor: ctx.theme.mutedText.withAlphaComponent(ctx.config.markers.inlineCodeMarkerAlpha),
                       .font: ctx.inlineMarkerFont]
                for marker in markers(of: range, content: contentRange) { attrs.append((marker, markerAttrs)) }

            case .link(let range, let textRange, let url, let markers, let children):
                styleLink(range: range, textRange: textRange, url: url, markers: markers, children: children, font: font, ctx: ctx, into: &attrs)

            case .wikiLink(let range, let name, _, let markers):
                styleWikiLink(range: range, name: name, markers: markers, ctx: ctx, into: &attrs)

            case .image, .imageEmbed, .inlineLatex, .escape:
                break   // ported in later increments
            }
        }
    }

    private static func styleLink(
        range: NSRange, textRange: NSRange, url urlRange: NSRange, markers: [NSRange],
        children: [InlineNode], font: NSFont, ctx: Ctx, into attrs: inout [StyledRange]
    ) {
        attrs.append((range, [.spellingState: 0]))
        var urlString = ctx.ns.substring(with: urlRange)
        if !urlString.contains("://") { urlString = "https://\(urlString)" }
        let isActive = ctx.isActive(range)
        if let url = URL(string: urlString) {
            if isActive {
                attrs.append((textRange, [
                    .foregroundColor: ctx.theme.link.withAlphaComponent(ctx.config.link.activeLinkAlpha),
                ]))
            } else {
                attrs.append((textRange, [
                    .link: url,
                    .underlineStyle: NSUnderlineStyle.single.rawValue,
                    .foregroundColor: ctx.theme.link,
                ]))
            }
        }
        for marker in markers { attrs.append((marker, [.foregroundColor: ctx.theme.mutedText])) }
        styleInlines(children, font: font, ctx: ctx, into: &attrs)
    }

    private static func styleWikiLink(
        range: NSRange, name: NSRange, markers: [NSRange], ctx: Ctx, into attrs: inout [StyledRange]
    ) {
        attrs.append((range, [.spellingState: 0]))
        let nodeName = ctx.ns.substring(with: name)
        let linkID = ctx.wikiLinkID(range)
        var contentAttrs: [NSAttributedString.Key: Any] = [:]
        if let linkID { contentAttrs[.wikiLinkID] = linkID }
        if !ctx.isActive(range) {
            let exists = ctx.config.services.wikiLinks.resolve(displayName: nodeName, range: name)?.exists ?? false
            if exists {
                contentAttrs[.link] = linkID ?? nodeName
            } else {
                contentAttrs[.foregroundColor] = ctx.theme.disabledText
            }
        }
        if !contentAttrs.isEmpty { attrs.append((name, contentAttrs)) }
        for marker in markers { attrs.append((marker, [.foregroundColor: ctx.theme.mutedText])) }
    }

    // MARK: - Marker shrinking (hide syntax of inactive nodes)

    /// Inactive nodes' markers collapse to a tiny, negatively-kerned font so the
    /// `**`/`#`/`>`/`[]()` syntax visually disappears. Code spans, inline code,
    /// inline LaTeX and image embeds manage their own markers and are skipped.
    private static func shrinkInactiveMarkers(in blocks: [BlockNode], ctx: Ctx, into attrs: inout [StyledRange]) {
        for block in blocks {
            switch block {
            case .heading(_, let range, let markers, let inlines):
                if !ctx.isActive(range) { shrink(markers, ctx: ctx, into: &attrs) }
                shrinkInlineMarkers(inlines, ctx: ctx, into: &attrs)
            case .paragraph(_, let inlines), .blockquote(_, let inlines):
                shrinkInlineMarkers(inlines, ctx: ctx, into: &attrs)
            case .codeBlock, .blockLatex, .table, .thematicBreak, .blank:
                break
            }
        }
    }

    private static func shrinkInlineMarkers(_ nodes: [InlineNode], ctx: Ctx, into attrs: inout [StyledRange]) {
        for node in nodes {
            switch node {
            case .emphasis(_, let range, let markers, let children):
                if !ctx.isActive(range) { shrink(markers, ctx: ctx, into: &attrs) }
                shrinkInlineMarkers(children, ctx: ctx, into: &attrs)
            case .strikethrough(let range, let markers, let children):
                if !ctx.isActive(range) { shrink(markers, ctx: ctx, into: &attrs) }
                shrinkInlineMarkers(children, ctx: ctx, into: &attrs)
            case .link(let range, _, _, let markers, let children):
                if !ctx.isActive(range) {
                    shrink(markers, ctx: ctx, into: &attrs)
                    if markers.count >= 4 {   // also hide the "(url)" run
                        let hide = NSRange(location: markers[2].location,
                                           length: NSMaxRange(markers[3]) - markers[2].location)
                        attrs.append((hide, [.font: ctx.inlineMarkerFont, .foregroundColor: NSColor.clear]))
                    }
                }
                shrinkInlineMarkers(children, ctx: ctx, into: &attrs)
            case .wikiLink(let range, _, _, let markers):
                if !ctx.isActive(range) { shrink(markers, ctx: ctx, into: &attrs) }
            case .image(let range, _, _, let markers):
                if !ctx.isActive(range) { shrink(markers, ctx: ctx, into: &attrs) }
            case .escape(let range, _, let marker):
                if !ctx.isActive(range) { shrink([marker], ctx: ctx, into: &attrs) }
            case .text, .code, .imageEmbed, .inlineLatex:
                break   // own marker handling / not shrunk
            }
        }
    }

    private static func shrink(_ markers: [NSRange], ctx: Ctx, into attrs: inout [StyledRange]) {
        for marker in markers {
            attrs.append((marker, [.font: ctx.inlineMarkerFont, .kern: -ctx.inlineMarkerFont.pointSize]))
        }
    }

    // MARK: - Helpers

    private static func traits(for kind: EmphasisKind) -> NSFontDescriptor.SymbolicTraits {
        switch kind {
        case .italic: return .italic
        case .bold: return .bold
        case .boldItalic: return [.bold, .italic]
        }
    }

    private static func adding(_ extra: NSFontDescriptor.SymbolicTraits, to font: NSFont) -> NSFont {
        let merged = font.fontDescriptor.symbolicTraits.union(extra)
        return NSFont(descriptor: font.fontDescriptor.withSymbolicTraits(merged), size: font.pointSize) ?? font
    }

    private static func content(of markers: [NSRange]) -> NSRange {
        let start = NSMaxRange(markers[0])
        return NSRange(location: start, length: markers[1].location - start)
    }

    /// The two backtick marker ranges of an inline code span (range minus content).
    private static func markers(of range: NSRange, content: NSRange) -> [NSRange] {
        [
            NSRange(location: range.location, length: content.location - range.location),
            NSRange(location: NSMaxRange(content), length: NSMaxRange(range) - NSMaxRange(content)),
        ]
    }
}
