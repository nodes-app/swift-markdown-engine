//
//  BlockVisitor.swift
//  MarkdownEngine
//
//  Forward-facing API for renderers / stylers / consumers that need to walk
//  block structure. Phase-1 spans are always flat (children empty), but the
//  default `walk` implementation already recurses so Phase 2's nested blocks
//  (blockquotes, list items, table cells) work without changes to callers.
//
//  Conform to `BlockVisitor` and implement `visit(_:depth:)`; call `walk(_:)`
//  with the top-level block list.
//

import Foundation

protocol BlockVisitor {
    mutating func visit(_ span: BlockSpan, depth: Int)
}

extension BlockVisitor {
    /// Traverse `blocks` depth-first, calling `visit` for each span.
    mutating func walk(_ blocks: [BlockSpan], depth: Int = 0) {
        for span in blocks {
            visit(span, depth: depth)
            if !span.children.isEmpty {
                walk(span.children, depth: depth + 1)
            }
        }
    }
}
