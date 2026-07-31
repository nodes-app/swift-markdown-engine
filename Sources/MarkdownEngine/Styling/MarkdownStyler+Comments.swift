//
//  MarkdownStyler+Comments.swift
//  MarkdownEngine
//
//  Dims Obsidian-style comments `%%…%%` (inline or spanning lines) so they read
//  as hidden annotations. Comments inside code or LaTeX are left alone.
//

import AppKit
import Foundation

extension MarkdownStyler {

    static func styleComments(_ ctx: StylingContext) -> [StyledRange] {
        let text = ctx.nsText
        guard text.length >= 4 else { return [] }

        // Ranges where a `%%` must not start a comment: fenced/inline code and
        // LaTeX (whose source `%` is a comment char and is rendered as an image).
        let skipRanges: [NSRange] = ctx.tokens
            .filter { $0.kind == .codeBlock || $0.kind == .inlineCode
                || $0.kind == .inlineLatex || $0.kind == .blockLatex }
            .map(\.range)

        var attrs: [StyledRange] = []
        let dim = ctx.configuration.theme.disabledText
        var i = 0
        while i < text.length - 1 {
            guard text.character(at: i) == 0x25, text.character(at: i + 1) == 0x25 else {
                i += 1
                continue
            }
            // Find the closing `%%`.
            var j = i + 2
            var closeAt = -1
            while j < text.length - 1 {
                if text.character(at: j) == 0x25, text.character(at: j + 1) == 0x25 {
                    closeAt = j
                    break
                }
                j += 1
            }
            guard closeAt >= 0 else { break }

            let range = NSRange(location: i, length: closeAt + 2 - i)
            let overlapsSkip = skipRanges.contains { NSIntersectionRange($0, range).length > 0 }
            if !overlapsSkip {
                attrs.append((range, [.foregroundColor: dim, .spellingState: 0]))
            }
            i = closeAt + 2
        }
        return attrs
    }
}
