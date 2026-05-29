//
//  MarkdownAST.swift
//  MarkdownEngine
//
//  Phase 2.5 foundation: the semantic document AST. Combines the block-structure
//  pass (BlockParser) with the inline pass (InlineParser) into one tree of
//  `BlockNode`s, each inline-bearing block carrying its parsed inline children
//  in absolute document coordinates. The AST-native styler (next increments)
//  walks this tree instead of consuming flat tokens.
//

import Foundation

/// A top-level block in the document AST.
indirect enum BlockNode: Equatable {
    case paragraph(range: NSRange, inlines: [InlineNode])
    case heading(level: Int, range: NSRange, markers: [NSRange], inlines: [InlineNode])
    case blockquote(range: NSRange, inlines: [InlineNode])
    case codeBlock(range: NSRange)
    case blockLatex(range: NSRange)
    case table(range: NSRange)
    case thematicBreak(range: NSRange)
    case blank(range: NSRange)
}

enum DocumentAST {

    private static let hash: unichar = 0x23
    private static let space: unichar = 0x20
    private static let tab: unichar = 0x09

    /// Build the document AST: block structure with inline children parsed.
    static func parse(_ text: String) -> [BlockNode] {
        let ns = text as NSString
        return BlockParser.parse(text).map { node(for: $0, ns: ns) }
    }

    private static func node(for block: Block, ns: NSString) -> BlockNode {
        switch block.kind {
        case .paragraph:
            return .paragraph(range: block.range, inlines: InlineParser.parse(ns, range: block.range))
        case .heading:
            return heading(block.range, ns)
        case .blockquote:
            return .blockquote(range: block.range, inlines: InlineParser.parse(ns, range: block.range))
        case .fencedCode:
            return .codeBlock(range: block.range)
        case .blockLatex:
            return .blockLatex(range: block.range)
        case .table:
            return .table(range: block.range)
        case .thematicBreak:
            return .thematicBreak(range: block.range)
        case .blank:
            return .blank(range: block.range)
        }
    }

    /// ATX heading: optional indent, `#`×level, space(s), then inline content.
    private static func heading(_ range: NSRange, _ ns: NSString) -> BlockNode {
        let end = NSMaxRange(range)
        var i = range.location
        while i < end, ns.character(at: i) == space || ns.character(at: i) == tab { i += 1 }
        let hashStart = i
        var level = 0
        while i < end, ns.character(at: i) == hash { level += 1; i += 1 }
        let markers = [NSRange(location: hashStart, length: level)]

        var contentStart = i
        while contentStart < end, ns.character(at: contentStart) == space { contentStart += 1 }
        var contentEnd = end
        while contentEnd > contentStart, isLineBreak(ns.character(at: contentEnd - 1)) { contentEnd -= 1 }
        let contentRange = NSRange(location: contentStart, length: contentEnd - contentStart)

        return .heading(level: level, range: range, markers: markers,
                        inlines: InlineParser.parse(ns, range: contentRange))
    }

    private static func isLineBreak(_ c: unichar) -> Bool { c == 0x0A || c == 0x0D }
}
