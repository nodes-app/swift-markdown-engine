//
//  InlineASTAdapter.swift
//  MarkdownEngine
//
//  Phase 2.5 bridge: flattens an inline AST (`[InlineNode]`) into the legacy
//  `[MarkdownToken]` shape the existing styler consumes. Walking the tree and
//  emitting one token per markup node (recursing into children) reproduces the
//  legacy tokenizer's flat, overlapping token set — so the new AST parser can
//  feed the unchanged styler. `.text` nodes carry no token.
//

import Foundation

enum InlineASTAdapter {

    static func tokens(from nodes: [InlineNode]) -> [MarkdownToken] {
        var result: [MarkdownToken] = []
        for node in nodes { append(node, to: &result) }
        return result
    }

    private static func append(_ node: InlineNode, to result: inout [MarkdownToken]) {
        switch node {
        case .text:
            break

        case .code(let range, let content):
            let open = NSRange(location: range.location, length: content.location - range.location)
            let close = NSRange(location: NSMaxRange(content), length: NSMaxRange(range) - NSMaxRange(content))
            result.append(MarkdownToken(kind: .inlineCode, range: range, contentRange: content, markerRanges: [open, close]))

        case .emphasis(let kind, let range, let markers, let children):
            let tokenKind: MarkdownTokenKind = kind == .italic ? .italic : (kind == .bold ? .bold : .boldItalic)
            result.append(MarkdownToken(kind: tokenKind, range: range,
                                        contentRange: between(markers), markerRanges: markers))
            children.forEach { append($0, to: &result) }

        case .link(let range, let textRange, _, let markers, let children):
            result.append(MarkdownToken(kind: .link, range: range, contentRange: textRange, markerRanges: markers))
            children.forEach { append($0, to: &result) }

        case .image(let range, let alt, _, let markers):
            result.append(MarkdownToken(kind: .imageLink, range: range, contentRange: alt, markerRanges: markers))

        case .wikiLink(let range, let name, _, let markers):
            result.append(MarkdownToken(kind: .wikiLink, range: range, contentRange: name, markerRanges: markers))

        case .imageEmbed(let range, let target, let markers):
            result.append(MarkdownToken(kind: .imageEmbed, range: range, contentRange: target, markerRanges: markers))

        case .strikethrough(let range, let markers, let children):
            result.append(MarkdownToken(kind: .strikethrough, range: range,
                                        contentRange: between(markers), markerRanges: markers))
            children.forEach { append($0, to: &result) }

        case .inlineLatex(let range, let content, let markers):
            result.append(MarkdownToken(kind: .inlineLatex, range: range, contentRange: content, markerRanges: markers))

        case .escape(let range, let character, let marker):
            result.append(MarkdownToken(kind: .backslashEscape, range: range, contentRange: character, markerRanges: [marker]))
        }
    }

    /// Content range between a `[open, close]` marker pair.
    private static func between(_ markers: [NSRange]) -> NSRange {
        let start = NSMaxRange(markers[0])
        return NSRange(location: start, length: markers[1].location - start)
    }
}
