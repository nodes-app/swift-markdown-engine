//
//  BlockParser.swift
//  MarkdownEngine
//
//  Phase 1 of the regex→AST refactor: the block-structure pass. Splits the
//  document into a flat, gap-free (tiling) sequence of blocks following the
//  CommonMark two-phase model — block structure first, inline content later.
//  Inline parsing happens per inline-bearing block in a separate step.
//
//  Ranges are absolute UTF-16 NSRanges into the source (the editor is
//  NSTextView / TextKit-2 based, so UTF-16 offsets are the native currency).
//  Storing relative widths (green-tree style, for cheap incremental reparse)
//  is a deliberate Phase 3 concern and intentionally deferred here.
//
//  Line classification mirrors the recognition the current regex tokenizer /
//  styler perform, so block ranges line up with today's tokens:
//    • heading        — headingRegex        `^\s*#{1,6} +…`
//    • thematic break — styler HR pattern   `^\s*(-{3,}|\*{3,}|_{3,})\s*$`
//    • fenced code    — codeBlockRegex       opening/closing ``` line
//    • blockquote     — blockquoteRegex     `^[ \t]{0,3}(>…)`
//

import Foundation

/// The block-level classification of a run of lines.
enum BlockKind: Equatable {
    case paragraph       // inline-bearing
    case heading         // single ATX line (`# …`), inline-bearing content
    case blockquote      // consecutive `>` lines, inline-bearing per line
    case fencedCode      // ```…``` — opaque (no inline parsing inside)
    case blockLatex      // $$…$$ — opaque
    case table           // GFM table — opaque (rendered as a unit)
    case thematicBreak   // `---` / `***` / `___` — produces no token today
    case blank           // blank / whitespace-only line(s) — separator
}

/// One block. `range` is the absolute UTF-16 range of the block's lines
/// (including their trailing newlines); blocks tile the document with no gaps.
struct Block: Equatable {
    let kind: BlockKind
    let range: NSRange
}

enum BlockParser {

    /// Splits `text` into a gap-free, ordered sequence of blocks that tile the
    /// entire string: every UTF-16 unit belongs to exactly one block.
    static func parse(_ text: String) -> [Block] {
        let nsText = text as NSString
        let length = nsText.length
        guard length > 0 else { return [] }

        // 1. Slice into physical lines (each includes its trailing newline).
        var lines: [NSRange] = []
        var cursor = 0
        while cursor < length {
            let r = nsText.lineRange(for: NSRange(location: cursor, length: 0))
            lines.append(r)
            cursor = NSMaxRange(r)
        }

        func lineText(_ i: Int) -> String { nsText.substring(with: lines[i]) }

        // 2. Classify + group.
        var blocks: [Block] = []
        var i = 0
        while i < lines.count {
            let line = lineText(i)

            if isBlank(line) {
                var end = i
                while end + 1 < lines.count, isBlank(lineText(end + 1)) { end += 1 }
                blocks.append(Block(kind: .blank, range: union(lines[i...end])))
                i = end + 1

            } else if isFence(line) {
                // Opaque: consume through the closing fence (or to EOF if none).
                var end = lines.count - 1
                var scan = i + 1
                while scan < lines.count {
                    if isFence(lineText(scan)) { end = scan; break }
                    scan += 1
                }
                blocks.append(Block(kind: .fencedCode, range: union(lines[i...end])))
                i = end + 1

            } else if isThematicBreak(line) {
                blocks.append(Block(kind: .thematicBreak, range: lines[i]))
                i += 1

            } else if isHeading(line) {
                blocks.append(Block(kind: .heading, range: lines[i]))
                i += 1

            } else if isBlockquote(line) {
                var end = i
                while end + 1 < lines.count, isBlockquote(lineText(end + 1)) { end += 1 }
                blocks.append(Block(kind: .blockquote, range: union(lines[i...end])))
                i = end + 1

            } else {
                // Paragraph: merge consecutive plain (non-blank, non-special) lines.
                var end = i
                while end + 1 < lines.count {
                    let next = lineText(end + 1)
                    if isBlank(next) || isFence(next) || isThematicBreak(next)
                        || isHeading(next) || isBlockquote(next) { break }
                    end += 1
                }
                blocks.append(Block(kind: .paragraph, range: union(lines[i...end])))
                i = end + 1
            }
        }
        return blocks
    }

    // MARK: - Line classification

    private static func isBlank(_ line: String) -> Bool {
        line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// An opening or closing fence line: starts with three backticks
    /// (matches codeBlockRegex's `^``` …` for both open and close).
    private static func isFence(_ line: String) -> Bool {
        line.hasPrefix("```")
    }

    /// `^\s*(-{3,}|\*{3,}|_{3,})\s*$` — a solid run of 3+ of one of `- * _`.
    private static func isThematicBreak(_ line: String) -> Bool {
        let t = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard t.count >= 3, let first = t.first,
              first == "-" || first == "*" || first == "_" else { return false }
        return t.allSatisfy { $0 == first }
    }

    /// `^\s*#{1,6} +…` — 1–6 hashes after optional indent, then at least one space.
    private static func isHeading(_ line: String) -> Bool {
        var rest = Substring(line).drop { $0 == " " || $0 == "\t" }
        var hashes = 0
        while let c = rest.first, c == "#" { hashes += 1; rest = rest.dropFirst() }
        guard (1...6).contains(hashes) else { return false }
        return rest.first == " "
    }

    /// `^[ \t]{0,3}>…` — up to 3 leading spaces/tabs, then a `>`.
    private static func isBlockquote(_ line: String) -> Bool {
        var rest = Substring(line)
        var indent = 0
        while indent < 3, let c = rest.first, c == " " || c == "\t" {
            rest = rest.dropFirst(); indent += 1
        }
        return rest.first == ">"
    }

    private static func union(_ ranges: ArraySlice<NSRange>) -> NSRange {
        let lo = ranges.first!.location
        let hi = NSMaxRange(ranges.last!)
        return NSRange(location: lo, length: hi - lo)
    }
}
