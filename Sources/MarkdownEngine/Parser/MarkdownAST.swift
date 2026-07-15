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

/// One list-item line: marker run, optional GFM checkbox, and indent column count.
struct ListItem: Equatable {
    let range: NSRange          // the item's full line (incl. trailing newline)
    let marker: NSRange
    let ordered: Bool
    let number: Int?            // ordered start value, e.g. `5.` → 5
    let checkbox: NSRange?
    let checked: Bool
    let indent: Int
    let contentRange: NSRange   // text after the marker (and checkbox)
    let inlines: [InlineNode]
}

/// An extension-supplied fenced block. `closeFence` is nil when the block is
/// unclosed (it then runs to the end of the document, like an open ``` fence).
struct ExtensionBlockNode: Equatable {
    let extensionID: String
    let range: NSRange
    let openFence: NSRange      // opening fence line incl. its newline
    let closeFence: NSRange?    // closing fence line, nil when unclosed
    let contentRange: NSRange   // lines between the fences
    let inlines: [InlineNode]
}

/// A top-level block in the document AST.
indirect enum BlockNode: Equatable {
    case paragraph(range: NSRange, inlines: [InlineNode])
    case heading(level: Int, range: NSRange, markers: [NSRange], inlines: [InlineNode])
    case blockquote(range: NSRange, inlines: [InlineNode])
    case list(range: NSRange, items: [ListItem])
    case codeBlock(range: NSRange)
    case blockLatex(range: NSRange)
    case table(range: NSRange)
    case thematicBreak(range: NSRange)
    case blank(range: NSRange)
    case ext(ExtensionBlockNode)

    var range: NSRange {
        switch self {
        case .paragraph(let r, _), .heading(_, let r, _, _), .blockquote(let r, _),
             .list(let r, _), .codeBlock(let r), .blockLatex(let r), .table(let r),
             .thematicBreak(let r), .blank(let r):
            return r
        case .ext(let node):
            return node.range
        }
    }
}

enum DocumentAST {

    private static let hash: unichar = 0x23
    private static let space: unichar = 0x20
    private static let tab: unichar = 0x09

    /// Build the document AST; `scopedRanges` parses inlines only for intersecting blocks.
    /// `precomputedBlocks` (the keystroke's own parse state, handed down by the
    /// restyle) skips BlockParser.parse — whose cache "hit" still re-extracts
    /// and memcmps the full document buffer — entirely.
    static func parse(_ text: String, scopedRanges: [NSRange]? = nil, precomputedBlocks: [Block]? = nil,
                      registry: ExtensionRegistry = .empty) -> [BlockNode] {
        let ns = text as NSString
        let blocks = precomputedBlocks ?? BlockParser.parse(text, registry: registry)
        // Scoped mode: skip building BlockNodes for blocks outside the edit.
        // Blocks tile the document in order, so one sweep over sorted candidate
        // ranges replaces scanning every candidate per block (which went
        // quadratic in formula-rich documents with dozens of candidates).
        let relevant: [Block]
        if let scopedRanges {
            let sorted = scopedRanges
                .filter { $0.location != NSNotFound && $0.length > 0 }
                .sorted { $0.location < $1.location }
            var out: [Block] = []
            var ci = 0
            for block in blocks {
                while ci < sorted.count, NSMaxRange(sorted[ci]) <= block.range.location { ci += 1 }
                guard ci < sorted.count else { break }
                if sorted[ci].location < NSMaxRange(block.range) { out.append(block) }
            }
            relevant = out
        } else {
            relevant = blocks
        }
        return relevant.map { node(for: $0, ns: ns, scopedRanges: scopedRanges, registry: registry) }
    }

    private static func inScope(_ range: NSRange, _ scopedRanges: [NSRange]?) -> Bool {
        guard let scopedRanges else { return true }
        return scopedRanges.contains { NSIntersectionRange($0, range).length > 0 }
    }

    private static func node(for block: Block, ns: NSString, scopedRanges: [NSRange]?, registry: ExtensionRegistry) -> BlockNode {
        let scoped = inScope(block.range, scopedRanges)
        switch block.kind {
        case .paragraph:
            return .paragraph(range: block.range, inlines: scoped ? InlineParser.parse(ns, range: block.range, registry: registry) : [])
        case .heading:
            return heading(block.range, ns, scoped: scoped, registry: registry)
        case .blockquote:
            return .blockquote(range: block.range, inlines: scoped ? InlineParser.parse(ns, range: block.range, registry: registry) : [])
        case .list:
            return list(block.range, ns, scoped: scoped, registry: registry)
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
        case .ext(let id):
            return extensionBlock(id: id, range: block.range, ns, scoped: scoped, registry: registry)
        }
    }

    /// Split an extension fenced block into open fence line, optional closing
    /// fence line, and the content between; inlines parse over the content.
    private static func extensionBlock(id: String, range: NSRange, _ ns: NSString,
                                       scoped: Bool, registry: ExtensionRegistry) -> BlockNode {
        let fence = registry.blockEntry(for: id)?.fence ?? ""
        let end = NSMaxRange(range)
        // Opening fence line including its terminator — via lineRange, the
        // same primitive the block parser tiles with, so the fence/content
        // split agrees on EVERY line terminator (\n, \r\n, U+2028, …).
        let openLine = ns.lineRange(for: NSRange(location: range.location, length: 0))
        let openEnd = min(NSMaxRange(openLine), end)
        let openFence = NSRange(location: range.location, length: openEnd - range.location)

        // Closing fence: the block's last line, when it starts with the fence
        // and is not the opening line itself.
        var closeFence: NSRange?
        if openEnd < end {
            let lastLine = ns.lineRange(for: NSRange(location: end - 1, length: 0))
            if lastLine.location >= openEnd,
               !fence.isEmpty,
               ns.substring(with: lastLine).hasPrefix(fence) {
                closeFence = lastLine
            }
        }

        let contentEnd = closeFence?.location ?? end
        let contentRange = NSRange(location: openEnd, length: max(0, contentEnd - openEnd))
        return .ext(ExtensionBlockNode(
            extensionID: id,
            range: range,
            openFence: openFence,
            closeFence: closeFence,
            contentRange: contentRange,
            inlines: scoped && contentRange.length > 0
                ? InlineParser.parse(ns, range: contentRange, registry: registry) : []
        ))
    }

    /// ATX heading: optional indent, `#`×level, space(s), then inline content.
    private static func heading(_ range: NSRange, _ ns: NSString, scoped: Bool = true, registry: ExtensionRegistry = .empty) -> BlockNode {
        let end = NSMaxRange(range)
        var i = range.location
        while i < end, ns.character(at: i) == space || ns.character(at: i) == tab { i += 1 }
        let hashStart = i
        var level = 0
        while i < end, ns.character(at: i) == hash { level += 1; i += 1 }

        var contentStart = i
        while contentStart < end, ns.character(at: contentStart) == space { contentStart += 1 }
        // Markers span `#`(s) plus trailing space(s) so the whole syntax collapses on shrink.
        let markers = [NSRange(location: hashStart, length: contentStart - hashStart)]
        var contentEnd = end
        while contentEnd > contentStart, isLineBreak(ns.character(at: contentEnd - 1)) { contentEnd -= 1 }
        let contentRange = NSRange(location: contentStart, length: contentEnd - contentStart)

        return .heading(level: level, range: range, markers: markers,
                        inlines: scoped ? InlineParser.parse(ns, range: contentRange, registry: registry) : [])
    }

    /// Split a list block into one `ListItem` per physical line.
    private static func list(_ range: NSRange, _ ns: NSString, scoped: Bool = true, registry: ExtensionRegistry = .empty) -> BlockNode {
        var items: [ListItem] = []
        var cursor = range.location
        let end = NSMaxRange(range)
        while cursor < end {
            let line = ns.lineRange(for: NSRange(location: cursor, length: 0))
            items.append(listItem(line, ns, scoped: scoped, registry: registry))
            cursor = NSMaxRange(line)
        }
        return .list(range: range, items: items)
    }

    /// Parse one list-item line: indent, marker, optional task checkbox, inline content.
    private static func listItem(_ lineRange: NSRange, _ ns: NSString, scoped: Bool = true, registry: ExtensionRegistry = .empty) -> ListItem {
        let end = NSMaxRange(lineRange)
        var i = lineRange.location
        var indent = 0
        while i < end, ns.character(at: i) == space || ns.character(at: i) == tab { i += 1; indent += 1 }
        let markerStart = i
        var ordered = false
        var number: Int?
        let c = i < end ? ns.character(at: i) : 0
        if c == 0x2D || c == 0x2A || c == 0x2B {        // - * +
            i += 1
        } else {                                        // N. / N)
            var value = 0
            var digits = 0
            while i < end, ns.character(at: i) >= 0x30, ns.character(at: i) <= 0x39, digits < 9 {
                value = value * 10 + Int(ns.character(at: i) - 0x30); i += 1; digits += 1
            }
            ordered = true
            number = value
            if i < end { i += 1 }                       // the `.` or `)`
        }
        let marker = NSRange(location: markerStart, length: i - markerStart)
        if i < end, ns.character(at: i) == space || ns.character(at: i) == tab { i += 1 }
        var checkbox: NSRange?
        var checked = false
        if i + 2 < end, ns.character(at: i) == 0x5B, ns.character(at: i + 2) == 0x5D {   // [ x ]
            let mid = ns.character(at: i + 1)
            if mid == space || mid == 0x78 || mid == 0x58 {     // space / x / X
                checkbox = NSRange(location: i, length: 3)
                checked = (mid == 0x78 || mid == 0x58)
                i += 3
                if i < end, ns.character(at: i) == space || ns.character(at: i) == tab { i += 1 }
            }
        }
        var contentEnd = end
        while contentEnd > i, isLineBreak(ns.character(at: contentEnd - 1)) { contentEnd -= 1 }
        let content = NSRange(location: i, length: max(0, contentEnd - i))
        return ListItem(range: lineRange, marker: marker, ordered: ordered, number: number,
                        checkbox: checkbox, checked: checked, indent: indent,
                        contentRange: content, inlines: scoped ? InlineParser.parse(ns, range: content, registry: registry) : [])
    }

    private static func isLineBreak(_ c: unichar) -> Bool { c == 0x0A || c == 0x0D }
}
