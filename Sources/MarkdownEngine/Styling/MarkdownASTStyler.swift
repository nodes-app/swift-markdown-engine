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
        scopedRanges: [NSRange]? = nil,
        configuration: MarkdownEditorConfiguration = .default
    ) -> [StyledRange] {
        let baseFont = NSFont(name: fontName, size: fontSize) ?? .systemFont(ofSize: fontSize)
        let baseLineHeight = ceil(baseFont.ascender - baseFont.descender + baseFont.leading)
        let baseParagraphSpacing = ceil(baseLineHeight * configuration.paragraph.spacingFactor)
        let codeFontSize = round(fontSize * configuration.codeBlock.fontSizeScale)
        let hiddenSize = configuration.markers.hiddenMarkerFontSize
        let ns = text as NSString
        let codeFont = configuration.services.syntaxHighlighter.codeFont(size: codeFontSize)
        let codeLineHeight = ceil(codeFont.ascender - codeFont.descender + codeFont.leading)
        let codePara = NSMutableParagraphStyle()
        codePara.lineBreakMode = .byCharWrapping
        codePara.lineSpacing = 0
        codePara.paragraphSpacingBefore = configuration.codeBlock.paragraphSpacing
        codePara.paragraphSpacing = configuration.codeBlock.paragraphSpacing
        codePara.headIndent = configuration.codeBlock.horizontalIndent
        codePara.firstLineHeadIndent = configuration.codeBlock.horizontalIndent
        codePara.tailIndent = -configuration.codeBlock.horizontalIndent
        codePara.minimumLineHeight = codeLineHeight
        codePara.maximumLineHeight = codeLineHeight
        let ctx = Ctx(
            ns: ns,
            fontName: fontName,
            baseFont: baseFont,
            baseLineHeight: baseLineHeight,
            baseParagraphSpacing: baseParagraphSpacing,
            codeFont: codeFont,
            codeBackground: configuration.services.syntaxHighlighter.backgroundColor(),
            codeParagraphStyle: codePara,
            inlineMarkerFont: NSFont(name: fontName, size: hiddenSize) ?? .systemFont(ofSize: hiddenSize),
            caret: caretLocation,
            config: configuration,
            wikiLinkID: wikiLinkIDProvider,
            scopedRanges: scopedRanges
        )
        let blocks = DocumentAST.parse(text, scopedRanges: scopedRanges)
        var attrs: [StyledRange] = []
        for block in blocks where ctx.inScope(block.range) {
            styleBlock(block, font: baseFont, ctx: ctx, into: &attrs)
        }
        shrinkInactiveMarkers(in: blocks, ctx: ctx, into: &attrs)

        // Text/regex passes (AST-agnostic); AST code ranges drive the "skip inside code" checks.
        let codeRanges = collectCodeRanges(in: blocks)
        let checkboxRanges = collectCheckboxRanges(in: blocks)
        styleAutoLinks(ctx: ctx, codeRanges: codeRanges, into: &attrs)
        styleIncompleteLinkBrackets(ctx: ctx, codeRanges: codeRanges, checkboxRanges: checkboxRanges, into: &attrs)
        return attrs
    }

    // MARK: - Text/regex-based passes (ported 1:1, AST-agnostic)

    private static func collectCodeRanges(in blocks: [BlockNode]) -> [NSRange] {
        var ranges: [NSRange] = []
        func walk(_ nodes: [InlineNode]) {
            for node in nodes {
                switch node {
                case .code(let range, _): ranges.append(range)
                case .emphasis(_, _, _, let children), .strikethrough(_, _, let children),
                     .highlight(_, _, let children), .link(_, _, _, _, let children): walk(children)
                default: break
                }
            }
        }
        for block in blocks {
            switch block {
            case .codeBlock(let range): ranges.append(range)
            case .paragraph(_, let inlines), .heading(_, _, _, let inlines), .blockquote(_, let inlines):
                walk(inlines)
            case .list(_, let items):
                for item in items { walk(item.inlines) }
            default: break
            }
        }
        return ranges
    }

    private static func isInCode(_ range: NSRange, _ codeRanges: [NSRange]) -> Bool {
        codeRanges.contains { NSIntersectionRange($0, range).length > 0 }
    }

    /// Checkbox boxes (`[ ]`/`[x]`), excluded so the incomplete-link pass doesn't repaint their brackets.
    private static func collectCheckboxRanges(in blocks: [BlockNode]) -> [NSRange] {
        var ranges: [NSRange] = []
        for block in blocks {
            if case .list(_, let items) = block {
                for item in items where item.checkbox != nil { ranges.append(item.checkbox!) }
            }
        }
        return ranges
    }

    private static func regex(_ pattern: String, _ anchored: Bool = true) -> NSRegularExpression? {
        try? NSRegularExpression(pattern: pattern, options: anchored ? [.anchorsMatchLines] : [])
    }

    /// Tag a thematic-break line for a full-width rule (AST-driven); suppressed while the caret edits it.
    private static func styleThematicBreak(range: NSRange, ctx: Ctx, into attrs: inout [StyledRange]) {
        var hr = range
        while hr.length > 0 {
            let last = ctx.ns.character(at: NSMaxRange(hr) - 1)
            guard last == 0x0A || last == 0x0D else { break }
            hr.length -= 1
        }
        guard hr.length > 0,
              !(NSLocationInRange(ctx.caret, hr) || ctx.caret == NSMaxRange(hr)) else { return }
        attrs.append((hr, [.foregroundColor: NSColor.clear, .thematicBreak: true]))
        attrs.append((hr, [.paragraphStyle: NSMutableParagraphStyle()]))
    }

    /// AST list-item decoration: indent paragraph, `•` bullet, checkbox + strikethrough, all caret-aware.
    private static func styleListItem(_ item: ListItem, ctx: Ctx, into attrs: inout [StyledRange]) {
        guard ctx.config.lists.helpersEnabled else { return }

        // Line content (item line minus its trailing newline).
        var line = item.range
        while line.length > 0 {
            let last = ctx.ns.character(at: NSMaxRange(line) - 1)
            guard last == 0x0A || last == 0x0D else { break }
            line.length -= 1
        }

        // 1. Indent paragraph style (hanging indent so wrapped lines align).
        let wsRange = NSRange(location: item.range.location, length: item.marker.location - item.range.location)
        let ws = ctx.ns.substring(with: wsRange)
        let markerGroup = NSRange(location: item.marker.location,
                                  length: item.contentRange.location - item.marker.location)
        let markerWidth = (ctx.ns.substring(with: markerGroup) as NSString)
            .size(withAttributes: [.font: ctx.baseFont]).width
        let depthIndent = CGFloat(MarkdownLists.indentLevel(from: ws)) * ctx.config.lists.indentPerLevel
        let extraSpacing = (item.checkbox != nil && !item.checked)
            ? HeadingHelpers.checkboxExtraSpacing(font: ctx.baseFont, configuration: ctx.config.checkbox)
            : 0
        let ps = NSMutableParagraphStyle()
        let lineHeight = ctx.baseLineHeight + ctx.config.lists.extraLineHeight
        ps.minimumLineHeight = lineHeight
        ps.maximumLineHeight = lineHeight
        ps.lineSpacing = 0
        ps.paragraphSpacing = ctx.baseParagraphSpacing
        ps.paragraphSpacingBefore = 0
        ps.tabStops = []
        ps.defaultTabInterval = ctx.config.lists.indentPerLevel
        ps.firstLineHeadIndent = ctx.config.lists.indentPerLevel
        ps.headIndent = ctx.config.lists.indentPerLevel + depthIndent + markerWidth + extraSpacing
        attrs.append((line, [.paragraphStyle: ps]))

        // 2. Marker decoration (suppressed while the caret edits the syntax).
        if let box = item.checkbox {
            let syntax = NSRange(location: item.marker.location, length: NSMaxRange(box) - item.marker.location)
            if NSLocationInRange(ctx.caret, syntax) || ctx.caret == NSMaxRange(box) { return }
            let spacer = NSRange(location: NSMaxRange(item.marker), length: box.location - NSMaxRange(item.marker))
            attrs.append((item.marker, [.foregroundColor: NSColor.clear]))
            if spacer.length > 0 { attrs.append((spacer, [.foregroundColor: NSColor.clear])) }
            attrs.append((box, [.taskCheckbox: item.checked, .foregroundColor: NSColor.clear]))
            if item.checked, NSMaxRange(item.range) > NSMaxRange(box) {
                attrs.append((NSRange(location: NSMaxRange(box), length: NSMaxRange(item.range) - NSMaxRange(box)), [
                    .strikethroughStyle: NSUnderlineStyle.single.rawValue,
                    .strikethroughColor: ctx.theme.strikethroughColor,
                ]))
            }
        } else if !item.ordered {
            let syntax = NSRange(location: item.marker.location,
                                 length: item.contentRange.location - item.marker.location)
            if NSLocationInRange(ctx.caret, syntax) { return }
            attrs.append((item.marker, [.bulletMarker: true, .foregroundColor: NSColor.clear]))
        }
    }

    private static func styleAutoLinks(ctx: Ctx, codeRanges: [NSRange], into attrs: inout [StyledRange]) {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { return }
        for scan in ctx.scanRanges {
            detector.enumerateMatches(in: ctx.text, range: scan) { match, _, _ in
                guard let match, let url = match.url, !isInCode(match.range, codeRanges) else { return }
                attrs.append((match.range, [.link: url]))
            }
        }
    }

    private static func styleIncompleteLinkBrackets(ctx: Ctx, codeRanges: [NSRange], checkboxRanges: [NSRange], into attrs: inout [StyledRange]) {
        let patterns = [#"\[\]"#, #"\[\[\]\]"#, #"\[[^\]\r\n]*$"#, #"\[[^\]\r\n]+\](?!\()"#,
                        #"\[[^\]\r\n]+\]\([^)\r\n]*$"#, #"\[[^\]\r\n]+\]\(\)"#]
        let muted = ctx.theme.mutedText
        let faded = ctx.theme.incompleteLink.withAlphaComponent(ctx.config.link.incompleteLinkAlpha)
        for pattern in patterns {
            guard let re = regex(pattern, false) else { continue }
            for scan in ctx.scanRanges {
              for m in re.matches(in: ctx.text, options: [], range: scan)
                  where !isInCode(m.range, codeRanges) && !isInCode(m.range, checkboxRanges) {
                for (i, ch) in ctx.ns.substring(with: m.range).enumerated() {
                    let r = NSRange(location: m.range.location + i, length: 1)
                    let isBracket = ch == "[" || ch == "]" || ch == "(" || ch == ")"
                    attrs.append((r, [.foregroundColor: isBracket ? muted : faded]))
                }
              }
            }
        }
    }

    /// Shared inputs threaded through the walk.
    private struct Ctx {
        let ns: NSString
        let fontName: String
        let baseFont: NSFont
        let baseLineHeight: CGFloat
        let baseParagraphSpacing: CGFloat
        let codeFont: NSFont
        let codeBackground: NSColor
        let codeParagraphStyle: NSParagraphStyle
        let inlineMarkerFont: NSFont
        let caret: Int
        let config: MarkdownEditorConfiguration
        let wikiLinkID: (NSRange) -> String?
        let scopedRanges: [NSRange]?

        /// Active (syntax revealed) when the caret is inside the range or at its end (minus a newline).
        func isActive(_ range: NSRange) -> Bool {
            if NSLocationInRange(caret, range) { return true }
            guard range.length > 0, caret == NSMaxRange(range) else { return false }
            let last = ns.character(at: caret - 1)
            return last != 0x0A && last != 0x0D
        }
        var theme: MarkdownEditorTheme { config.theme }
        var text: String { ns as String }
        var fullRange: NSRange { NSRange(location: 0, length: ns.length) }
        /// Whether a range falls in the styled region (nil scope = whole doc).
        func inScope(_ r: NSRange) -> Bool {
            guard let scopedRanges else { return true }
            return scopedRanges.contains { NSIntersectionRange($0, r).length > 0 }
        }
        /// Ranges the regex/text passes scan (edited paragraphs, or whole doc).
        var scanRanges: [NSRange] { scopedRanges ?? [fullRange] }
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
            let lineHeight = ceil(headingFont.ascender - headingFont.descender + headingFont.leading) + 1
            let headingPara = NSMutableParagraphStyle()
            headingPara.minimumLineHeight = lineHeight
            headingPara.maximumLineHeight = lineHeight
            headingPara.paragraphSpacingBefore = headingFont.pointSize * ctx.config.headings.topSpacingEm(for: level)
            headingPara.paragraphSpacing = ctx.baseParagraphSpacing
            attrs.append((ctx.ns.paragraphRange(for: range), [.paragraphStyle: headingPara]))
            attrs.append((range, [.font: headingFont]))
            for marker in markers {
                attrs.append((marker, [.foregroundColor: ctx.theme.headingMarker]))
            }
            styleInlines(inlines, font: headingFont, ctx: ctx, into: &attrs)

        case .blockquote(let range, let inlines):
            styleBlockquote(range: range, ctx: ctx, into: &attrs)
            styleInlines(inlines, font: font, ctx: ctx, into: &attrs)

        case .list(_, let items):
            for item in items {
                styleListItem(item, ctx: ctx, into: &attrs)
                styleInlines(item.inlines, font: font, ctx: ctx, into: &attrs)
            }

        case .codeBlock(let range):
            styleCodeBlock(range: range, ctx: ctx, into: &attrs)
        case .thematicBreak(let range):
            styleThematicBreak(range: range, ctx: ctx, into: &attrs)
        case .blockLatex, .table, .blank:
            break   // NSImage rendering ported next
        }
    }

    /// Per-line blockquote: indent, mute content, hide/show `>` markers, tag first char with bar level.
    private static func styleBlockquote(range: NSRange, ctx: Ctx, into attrs: inout [StyledRange]) {
        let indentPerLevel = MarkdownTextLayoutFragment.blockquoteIndentPerLevel
        var lineStart = range.location
        let end = NSMaxRange(range)
        while lineStart < end {
            let line = ctx.ns.lineRange(for: NSRange(location: lineStart, length: 0))
            let lineEnd = NSMaxRange(line)
            var i = line.location
            var indent = 0
            while i < lineEnd, indent < 3, ctx.ns.character(at: i) == 0x20 || ctx.ns.character(at: i) == 0x09 {
                i += 1; indent += 1
            }
            let markerStart = i
            var level = 0
            var j = i
            while j < lineEnd, ctx.ns.character(at: j) == 0x3E /* > */ {
                level += 1; j += 1
                if j < lineEnd, ctx.ns.character(at: j) == 0x20 || ctx.ns.character(at: j) == 0x09 { j += 1 }
            }
            defer { lineStart = lineEnd }
            guard level > 0 else { continue }

            var contentEnd = lineEnd
            if contentEnd > j {
                let last = ctx.ns.character(at: contentEnd - 1)
                if last == 0x0A || last == 0x0D { contentEnd -= 1 }
            }
            let markerRange = NSRange(location: markerStart, length: j - markerStart)
            let contentRange = NSRange(location: j, length: max(0, contentEnd - j))
            let tokenRange = NSRange(location: line.location, length: contentEnd - line.location)

            let textIndent = CGFloat(level) * indentPerLevel + indentPerLevel * 0.5
            let para = NSMutableParagraphStyle()
            para.firstLineHeadIndent = textIndent
            para.headIndent = textIndent
            let lineHeight = ctx.baseLineHeight + ctx.config.blockquote.extraLineHeight
            para.minimumLineHeight = lineHeight
            para.maximumLineHeight = lineHeight
            // Inner quote lines stay tight (0); the LAST line gets the normal
            para.paragraphSpacing = (lineEnd >= end) ? ctx.baseParagraphSpacing : 0
            para.paragraphSpacingBefore = 0
            attrs.append((ctx.ns.paragraphRange(for: tokenRange), [.paragraphStyle: para]))

            if contentRange.length > 0 {
                attrs.append((contentRange, [.foregroundColor: ctx.theme.mutedText]))
            }
            if ctx.isActive(tokenRange) {
                attrs.append((markerRange, [.foregroundColor: ctx.theme.mutedText]))
            } else {
                attrs.append((markerRange, [.foregroundColor: NSColor.clear, .font: ctx.inlineMarkerFont]))
            }
            // Whole line, not just the first char, so each soft-wrapped visual line
            attrs.append((tokenRange, [.blockquoteLevel: level]))
        }
    }

    private static func styleCodeBlock(range: NSRange, ctx: Ctx, into attrs: inout [StyledRange]) {
        let parts = codeBlockParts(range, ctx.ns)
        attrs.append((parts.codeRange, [
            .font: ctx.codeFont, .backgroundColor: ctx.codeBackground, .paragraphStyle: ctx.codeParagraphStyle,
        ]))
        // Suppress spell-check underlines on the whole fenced block — code is not prose.
        attrs.append((parts.codeRange, [.spellingState: 0]))
        let codeContent = ctx.ns.substring(with: parts.content)
        if !codeContent.isEmpty,
           let highlighted = ctx.config.services.syntaxHighlighter.highlight(code: codeContent, language: parts.language) {
            highlighted.enumerateAttributes(in: NSRange(location: 0, length: highlighted.length)) { a, r, _ in
                guard let fg = a[.foregroundColor] else { return }
                attrs.append((NSRange(location: parts.content.location + r.location, length: r.length), [.foregroundColor: fg]))
            }
        }
        // Use the whole block range (not codeRange): an incomplete fence collapses codeRange to the ```.
        let markerAttrs: [NSAttributedString.Key: Any] = ctx.isActive(range)
            ? [.foregroundColor: ctx.theme.mutedText, .font: ctx.codeFont]
            : [.foregroundColor: NSColor.clear, .font: ctx.codeFont]   // hiddenMarkerFont == codeFont
        attrs.append((parts.openFence, markerAttrs))
        attrs.append((parts.closeFence, markerAttrs))
    }

    /// Split a fenced-code range into open fence (+language), content, close fence, and language.
    private static func codeBlockParts(_ range: NSRange, _ ns: NSString)
        -> (codeRange: NSRange, openFence: NSRange, content: NSRange, closeFence: NSRange, language: String?) {
        let start = range.location
        let end = NSMaxRange(range)
        var openEnd = start
        while openEnd < end, ns.character(at: openEnd) != 0x0A { openEnd += 1 }
        if openEnd < end { openEnd += 1 }
        let openFence = NSRange(location: start, length: openEnd - start)

        let lastLine = ns.lineRange(for: NSRange(location: max(start, end - 1), length: 0))
        var bt = lastLine.location
        while bt < NSMaxRange(lastLine), ns.character(at: bt) == 0x60 { bt += 1 }
        let closeFence = NSRange(location: lastLine.location, length: bt - lastLine.location)
        let codeRange = NSRange(location: start, length: NSMaxRange(closeFence) - start)
        let content = NSRange(location: openEnd, length: max(0, lastLine.location - openEnd))

        var language: String?
        if openFence.length > 3 {
            let raw = ns.substring(with: NSRange(location: start + 3, length: openFence.length - 3))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            language = raw.isEmpty ? nil : raw
        }
        return (codeRange, openFence, content, closeFence, language)
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

            case .highlight(_, let markers, let children):
                attrs.append((content(of: markers), [
                    .backgroundColor: ctx.theme.highlightColor,
                ]))
                styleInlines(children, font: font, ctx: ctx, into: &attrs)

            case .code(let range, let contentRange):
                attrs.append((contentRange, [.font: ctx.codeFont, .backgroundColor: ctx.codeBackground]))
                // Suppress spell-check underlines on inline `code` spans (markers + content).
                attrs.append((range, [.spellingState: 0]))
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
            // Resolve by the stable UUID when present 
            let exists = ctx.config.services.wikiLinks.resolve(displayName: linkID ?? nodeName, range: name)?.exists ?? false
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

    /// Collapse inactive nodes' markers to a tiny kerned font so syntax vanishes; code/LaTeX skip themselves.
    private static func shrinkInactiveMarkers(in blocks: [BlockNode], ctx: Ctx, into attrs: inout [StyledRange]) {
        for block in blocks where ctx.inScope(block.range) {
            switch block {
            case .heading(_, let range, let markers, let inlines):
                if !ctx.isActive(range) { shrink(markers, ctx: ctx, into: &attrs) }
                shrinkInlineMarkers(inlines, ctx: ctx, into: &attrs)
            case .paragraph(_, let inlines), .blockquote(_, let inlines):
                shrinkInlineMarkers(inlines, ctx: ctx, into: &attrs)
            case .list(_, let items):
                // Phase A: shrink only inline markers; the list marker is hidden by the bullet/task pass.
                for item in items { shrinkInlineMarkers(item.inlines, ctx: ctx, into: &attrs) }
            case .codeBlock, .blockLatex, .table, .thematicBreak, .blank:
                break
            }
        }
    }

    /// Shrink inactive markers; an active ancestor reveals its whole subtree via `forceReveal`.
    private static func shrinkInlineMarkers(_ nodes: [InlineNode], ctx: Ctx, forceReveal: Bool = false, into attrs: inout [StyledRange]) {
        for node in nodes {
            switch node {
            case .emphasis(_, let range, let markers, let children):
                let active = forceReveal || ctx.isActive(range)
                if !active { shrink(markers, ctx: ctx, into: &attrs) }
                shrinkInlineMarkers(children, ctx: ctx, forceReveal: active, into: &attrs)
            case .strikethrough(let range, let markers, let children):
                let active = forceReveal || ctx.isActive(range)
                if !active { shrink(markers, ctx: ctx, into: &attrs) }
                shrinkInlineMarkers(children, ctx: ctx, forceReveal: active, into: &attrs)
            case .highlight(let range, let markers, let children):
                let active = forceReveal || ctx.isActive(range)
                if !active { shrink(markers, ctx: ctx, into: &attrs) }
                shrinkInlineMarkers(children, ctx: ctx, forceReveal: active, into: &attrs)
            case .link(let range, _, _, let markers, let children):
                let active = forceReveal || ctx.isActive(range)
                if !active {
                    shrink(markers, ctx: ctx, into: &attrs)
                    if markers.count >= 4 {   // also hide the "(url)" run
                        let hide = NSRange(location: markers[2].location,
                                           length: NSMaxRange(markers[3]) - markers[2].location)
                        attrs.append((hide, [.font: ctx.inlineMarkerFont, .foregroundColor: NSColor.clear]))
                    }
                }
                shrinkInlineMarkers(children, ctx: ctx, forceReveal: active, into: &attrs)
            case .wikiLink(let range, _, _, let markers):
                if !(forceReveal || ctx.isActive(range)) { shrink(markers, ctx: ctx, into: &attrs) }
            case .image(let range, _, _, let markers):
                if !(forceReveal || ctx.isActive(range)) { shrink(markers, ctx: ctx, into: &attrs) }
            case .escape(let range, _, let marker):
                if !(forceReveal || ctx.isActive(range)) { shrink([marker], ctx: ctx, into: &attrs) }
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
