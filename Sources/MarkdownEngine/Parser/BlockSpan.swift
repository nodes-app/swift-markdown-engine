//
//  BlockSpan.swift
//  MarkdownEngine
//
//  Data model for the block phase of the two-phase Markdown parser
//  (CommonMark §3, Appendix A). A `BlockSpan` is a typed range over the
//  source that the block scanner emits; the inline parser runs over each
//  span's `contentRange` to fill in inline structure.
//
//  Phase-1 spans are flat (children always empty). Phase-2 will populate
//  `children` for container blocks (blockquote, list item, etc.).
//

import Foundation

/// Kind of block-level construct found in the source.
///
/// Cases marked "Phase 2" are forward-declared so adding them later
/// requires no API break in code that switches over `BlockKind`.
enum BlockKind: Equatable {
    // Phase 1
    case paragraph
    case heading(level: Int)             // 1...6, ATX or Setext
    case fencedCode(language: String?)
    case thematicBreak
    case list(ordered: Bool)
    case listItem(indentColumns: Int)
    case linkReferenceDefinition(label: String)

    // Phase 2 — forward-declared, not emitted by Phase-1 scanner
    case blockquote
    case table
    case tableRow
    case tableCell(alignment: TableCellAlignment)
    case footnoteDefinition(label: String)
    case definitionList
    case htmlBlock
}

enum TableCellAlignment: Equatable {
    case none
    case left
    case center
    case right
}

/// One block-level element in the source.
///
/// - `range`: full source range including any markers / fences.
/// - `contentRange`: substring that the inline phase processes
///   (e.g. text after `# ` for a heading, body between fences for code).
/// - `markerRanges`: ranges of opening/closing markers (e.g. `#` for ATX,
///   the two ``` lines for fenced code). Used by stylers to hide / dim markers.
/// - `children`: nested blocks for container kinds. Always empty in Phase 1.
struct BlockSpan: Equatable {
    let kind: BlockKind
    let range: NSRange
    let contentRange: NSRange
    let markerRanges: [NSRange]
    var children: [BlockSpan]

    init(
        kind: BlockKind,
        range: NSRange,
        contentRange: NSRange,
        markerRanges: [NSRange] = [],
        children: [BlockSpan] = []
    ) {
        self.kind = kind
        self.range = range
        self.contentRange = contentRange
        self.markerRanges = markerRanges
        self.children = children
    }
}

extension BlockKind {
    /// `true` when the inline phase should tokenize this block's `contentRange`.
    /// Fenced code, thematic breaks, link reference definitions, and HTML
    /// blocks suppress inline parsing entirely.
    var allowsInlineContent: Bool {
        switch self {
        case .paragraph, .heading, .blockquote, .listItem, .tableCell, .definitionList:
            return true
        case .fencedCode, .thematicBreak, .linkReferenceDefinition, .htmlBlock,
             .list, .table, .tableRow, .footnoteDefinition:
            return false
        }
    }
}

/// A `[label]: url "title"` definition collected during the block phase.
/// Phase 3 (inline AST) will consume the map to resolve reference-style
/// links like `[text][label]` and `![alt][label]`.
struct LinkReference: Equatable {
    let label: String                 // raw label as written
    let url: String
    let title: String?

    init(label: String, url: String, title: String? = nil) {
        self.label = label
        self.url = url
        self.title = title
    }

    /// Per CommonMark, link labels are matched case-insensitively after
    /// collapsing internal whitespace runs to single spaces and trimming.
    var normalizedLabel: String {
        let collapsed = label
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        return collapsed.lowercased()
    }
}

/// Output of the block phase.
struct BlockScanResult: Equatable {
    let blocks: [BlockSpan]
    let linkReferences: [String: LinkReference]  // keyed by `normalizedLabel`
}
