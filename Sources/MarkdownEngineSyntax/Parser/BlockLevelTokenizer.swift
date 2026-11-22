//
//  BlockLevelTokenizer.swift
//  MarkdownEngine
//
//  Builds the block-level MarkdownTokens (heading, blockquote, fenced code,
//  table, block LaTeX) directly from already-classified block substrings —
//  replacing the legacy `parseTokens` regexes. Inline tokens come from the AST
//  (`InlineParser` → `InlineASTAdapter`); this only covers block-level kinds.
//
//  Token shapes are reproduced 1:1 from the old regex tokenizer so every
//  downstream consumer (ContextMenu, code/LaTeX detection, the NSImage render
//  passes) sees identical tokens. A parity check pins that during the swap.
//

import Foundation

enum BlockLevelTokenizer {

    private static let backtick: unichar = 0x60
    private static let dollar: unichar = 0x24
    private static let hash: unichar = 0x23
    private static let pipe: unichar = 0x7C
    private static let gt: unichar = 0x3E
    private static let dash: unichar = 0x2D
    private static let colon: unichar = 0x3A
    private static let space: unichar = 0x20
    private static let tab: unichar = 0x09
    private static let lf: unichar = 0x0A
    private static let cr: unichar = 0x0D

    private static func isWS(_ c: unichar) -> Bool { c == space || c == tab }

    /// Content end (excludes trailing CR/LF) and next-line start for the line at `start`.
    private static func line(in s: NSString, from start: Int) -> (contentEnd: Int, nextStart: Int) {
        let len = s.length
        var i = start
        while i < len, s.character(at: i) != lf, s.character(at: i) != cr { i += 1 }
        let contentEnd = i
        if i < len, s.character(at: i) == cr { i += 1 }
        if i < len, s.character(at: i) == lf { i += 1 }
        return (contentEnd, i)
    }

    /// Block-level tokens for one block substring, dispatched by its kind.
    static func tokens(for kind: BlockKind, in sub: NSString, registry: ExtensionRegistry = .empty) -> [MarkdownToken] {
        switch kind {
        case .fencedCode:  return codeBlock(in: sub)
        case .heading:     return heading(in: sub)
        case .blockquote:  return blockquote(in: sub)
        case .table:       return table(in: sub)
        case .blockLatex:  return blockLatex(in: sub)
        case .ext(let id): return extensionBlock(in: sub, id: id,
                                                 fence: registry.blockEntry(for: id)?.fence ?? "")
        case .paragraph, .list, .thematicBreak, .blank:
            // Safety-net table scan; tables/block LaTeX are their own blocks now, inline `$$…$$` stays plain.
            return table(in: sub)
        }
    }

    // MARK: - Extension fenced block  (open fence line … closing fence line / EOF)

    private static func extensionBlock(in s: NSString, id: String, fence: String) -> [MarkdownToken] {
        let len = s.length
        guard len > 0 else { return [] }
        let afterOpenLine = line(in: s, from: 0).nextStart
        // Closing fence: the LAST line, when it starts with the fence (the
        // block parser guarantees no interior fence line).
        var closeStart = -1
        var closeEnd = -1
        if afterOpenLine < len, !fence.isEmpty {
            var lineStart = afterOpenLine
            while lineStart < len {
                let (contentEnd, next) = line(in: s, from: lineStart)
                if next >= len {
                    let text = s.substring(with: NSRange(location: lineStart, length: contentEnd - lineStart))
                    if text.hasPrefix(fence) { closeStart = lineStart; closeEnd = contentEnd }
                    break
                }
                if next <= lineStart { break }
                lineStart = next
            }
        }
        let contentEnd = closeStart >= 0 ? closeStart : len
        var markers = [NSRange(location: 0, length: afterOpenLine)]
        if closeStart >= 0 { markers.append(NSRange(location: closeStart, length: closeEnd - closeStart)) }
        return [MarkdownToken(
            kind: .extensionBlock(id),
            range: NSRange(location: 0, length: len),
            contentRange: NSRange(location: afterOpenLine, length: max(0, contentEnd - afterOpenLine)),
            markerRanges: markers)]
    }

    // MARK: - Heading  (legacy `^\s*(#{1,6}) +(.*)$`)

    private static func heading(in s: NSString) -> [MarkdownToken] {
        let len = s.length
        var i = 0
        while i < len, isWS(s.character(at: i)) { i += 1 }
        let hashStart = i
        while i < len, s.character(at: i) == hash { i += 1 }
        let hashEnd = i
        guard hashEnd > hashStart, hashEnd - hashStart <= 6,
              hashEnd < len, s.character(at: hashEnd) == space else { return [] }
        var contentStart = hashEnd
        while contentStart < len, s.character(at: contentStart) == space { contentStart += 1 }
        let lineEnd = line(in: s, from: 0).contentEnd
        let tokenRange = NSRange(location: hashStart, length: lineEnd - hashStart)
        let markers = [NSRange(location: hashStart, length: hashEnd - hashStart),
                       NSRange(location: hashEnd, length: 1)]
        let content = NSRange(location: contentStart, length: max(0, lineEnd - contentStart))
        return [MarkdownToken(kind: .heading, range: tokenRange, contentRange: content, markerRanges: markers)]
    }

    // MARK: - Blockquote  (legacy `^[ \t]{0,3}((?:>[ \t]?)+)(.*)$`, one token per line)

    private static func blockquote(in s: NSString) -> [MarkdownToken] {
        let len = s.length
        var tokens: [MarkdownToken] = []
        var lineStart = 0
        while lineStart < len {
            let (contentEnd, nextStart) = line(in: s, from: lineStart)
            var i = lineStart
            var indent = 0
            while i < contentEnd, indent < 3, isWS(s.character(at: i)) { i += 1; indent += 1 }
            let markerStart = i
            if i < contentEnd, s.character(at: i) == gt {
                while i < contentEnd, s.character(at: i) == gt {
                    i += 1
                    if i < contentEnd, isWS(s.character(at: i)) { i += 1 }
                }
                let markerEnd = i
                tokens.append(MarkdownToken(
                    kind: .blockquote,
                    range: NSRange(location: lineStart, length: contentEnd - lineStart),
                    contentRange: NSRange(location: markerEnd, length: contentEnd - markerEnd),
                    markerRanges: [NSRange(location: markerStart, length: markerEnd - markerStart)]))
            }
            if nextStart <= lineStart { break }
            lineStart = nextStart
        }
        return tokens
    }

    // MARK: - Fenced code  (legacy ```lang\n…\n```)

    private static func codeBlock(in s: NSString) -> [MarkdownToken] {
        let len = s.length
        guard len >= 3 else { return [] }
        let afterOpenLine = line(in: s, from: 0).nextStart
        var lineStart = afterOpenLine
        var closingStart = -1
        while lineStart < len {
            if lineStart + 3 <= len,
               s.character(at: lineStart) == backtick,
               s.character(at: lineStart + 1) == backtick,
               s.character(at: lineStart + 2) == backtick {
                closingStart = lineStart
                break
            }
            let next = line(in: s, from: lineStart).nextStart
            if next <= lineStart { break }
            lineStart = next
        }
        guard closingStart >= 0 else { return [] }   // no closing fence → legacy didn't match
        return [MarkdownToken(
            kind: .codeBlock,
            range: NSRange(location: 0, length: closingStart + 3),
            contentRange: NSRange(location: afterOpenLine, length: closingStart - afterOpenLine),
            markerRanges: [NSRange(location: 0, length: afterOpenLine),
                           NSRange(location: closingStart, length: 3)])]
    }

    // MARK: - Table  (legacy header `|…|` + separator `|-…-|` + data rows)

    private static func table(in s: NSString) -> [MarkdownToken] {
        let len = s.length
        var tokens: [MarkdownToken] = []
        var lineStart = 0
        while lineStart < len {
            let (contentEnd, nextStart) = line(in: s, from: lineStart)
            if isTableRow(s, lineStart, contentEnd), nextStart < len {
                let (sepEnd, afterSep) = line(in: s, from: nextStart)
                if isTableSeparator(s, nextStart, sepEnd) {
                    var rowEnd = sepEnd
                    var cursor = afterSep
                    while cursor < len {
                        let (cEnd, cNext) = line(in: s, from: cursor)
                        guard isTableRow(s, cursor, cEnd) else { break }
                        rowEnd = cEnd
                        if cNext <= cursor { cursor = cEnd; break }
                        cursor = cNext
                    }
                    tokens.append(MarkdownToken(
                        kind: .table,
                        range: NSRange(location: lineStart, length: rowEnd - lineStart),
                        contentRange: NSRange(location: lineStart, length: rowEnd - lineStart),
                        markerRanges: []))
                    lineStart = cursor
                    continue
                }
            }
            if nextStart <= lineStart { break }
            lineStart = nextStart
        }
        return tokens
    }

    /// `^[ \t]*\|.+\|[ \t]*$` — a pipe, ≥1 char, a pipe (trailing ws allowed).
    private static func isTableRow(_ s: NSString, _ start: Int, _ end: Int) -> Bool {
        var i = start
        while i < end, isWS(s.character(at: i)) { i += 1 }
        guard i < end, s.character(at: i) == pipe else { return false }
        var j = end
        while j > i, isWS(s.character(at: j - 1)) { j -= 1 }
        guard j - 1 > i, s.character(at: j - 1) == pipe else { return false }
        return (j - 1) - (i + 1) >= 1
    }

    /// `^[ \t]*\|[- \t:|]+\|[ \t]*$` — outer pipes, inner only `- : | space tab`.
    private static func isTableSeparator(_ s: NSString, _ start: Int, _ end: Int) -> Bool {
        var i = start
        while i < end, isWS(s.character(at: i)) { i += 1 }
        guard i < end, s.character(at: i) == pipe else { return false }
        var j = end
        while j > i, isWS(s.character(at: j - 1)) { j -= 1 }
        guard j - 1 > i, s.character(at: j - 1) == pipe else { return false }
        var k = i + 1
        var count = 0
        while k < j - 1 {
            let c = s.character(at: k)
            guard c == dash || c == space || c == tab || c == colon || c == pipe else { return false }
            count += 1; k += 1
        }
        return count >= 1
    }

    // MARK: - Block LaTeX  (legacy `(?s)(?<!\$)\$\$(.+?)\$\$`)

    private static func blockLatex(in s: NSString) -> [MarkdownToken] {
        let len = s.length
        var tokens: [MarkdownToken] = []
        var i = 0
        while i + 1 < len {
            if s.character(at: i) == dollar, s.character(at: i + 1) == dollar {
                if i > 0, s.character(at: i - 1) == dollar { i += 1; continue }   // (?<!\$)
                var j = i + 2
                var closeAt = -1
                while j + 1 < len {
                    if s.character(at: j) == dollar, s.character(at: j + 1) == dollar, j > i + 2 {
                        closeAt = j; break
                    }
                    j += 1
                }
                if closeAt >= 0 {
                    tokens.append(MarkdownToken(
                        kind: .blockLatex,
                        range: NSRange(location: i, length: (closeAt + 2) - i),
                        contentRange: NSRange(location: i + 2, length: closeAt - (i + 2)),
                        markerRanges: [NSRange(location: i, length: 2),
                                       NSRange(location: closeAt, length: 2)]))
                    i = closeAt + 2
                    continue
                }
            }
            i += 1
        }
        return tokens
    }
}
