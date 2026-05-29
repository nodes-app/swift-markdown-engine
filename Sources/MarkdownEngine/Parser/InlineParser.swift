//
//  InlineParser.swift
//  MarkdownEngine
//
//  Phase 2 of the regex→AST refactor: the inline-structure pass. Given the
//  text of a single inline-bearing block, it produces an inline AST node tree
//  with correct CommonMark precedence — replacing the per-construct regex soup
//  that the current tokenizer uses inside each block.
//
//  Built construct by construct, test-first. Ranges in the returned tree are
//  relative to the parsed string; callers offset to document coordinates.
//
//  Pipeline (each pass claims spans only in regions not already claimed, so
//  there are never partial overlaps and buildTree is a clean containment tree):
//    1. scanCodeSpans   — highest precedence, opaque interior.
//    2. scanEscapes      — `\x` becomes a claimed span, so the escaped char is
//                          automatically inert for every pass below.
//    3. scanLinkFamily   — ![[…]], [[…]], ![…](…), […](…), ~~…~~, $…$ in
//                          precedence order. URLs allow balanced parens. A
//                          candidate overlapping a claimed span is rejected
//                          (kept literal) — this is what stops a `$…$` from
//                          spanning across a code span.
//    4. resolveEmphasis  — `*`/`_` delimiter runs over text outside every
//                          claimed span; may wrap claimed spans.
//    5. buildTree        — containment tree. Emphasis nests already-collected
//                          spans; link/strikethrough content is re-parsed
//                          recursively; code/image/wiki/embed/latex/escape are
//                          opaque leaves.
//

import Foundation

enum EmphasisKind: Equatable { case italic, bold, boldItalic }

/// A node in the inline AST.
indirect enum InlineNode: Equatable {
    case text(NSRange)
    /// `` `code` `` — opaque. `range` covers the backticks; `content` strips the
    /// CommonMark single-space padding.
    case code(range: NSRange, content: NSRange)
    /// `*`/`_` emphasis. `markers` is `[openMarker, closeMarker]`.
    case emphasis(EmphasisKind, range: NSRange, markers: [NSRange], children: [InlineNode])
    /// `[text](url)`. `markers` is `[ "[", "]", "(", ")" ]`; text is recursively parsed.
    case link(range: NSRange, textRange: NSRange, url: NSRange, markers: [NSRange], children: [InlineNode])
    /// `![alt](url)`. `markers` is `[ "![", "]", "(", ")" ]`. Alt is opaque.
    case image(range: NSRange, alt: NSRange, url: NSRange, markers: [NSRange])
    /// `[[Name|id]]`. `markers` is `[ "[[", "]]" ]`; `id` is nil when no `|`.
    case wikiLink(range: NSRange, name: NSRange, id: NSRange?, markers: [NSRange])
    /// `![[target]]`. `markers` is `[ "![[", "]]" ]`.
    case imageEmbed(range: NSRange, target: NSRange, markers: [NSRange])
    /// `~~text~~`. `markers` is `[openMarker, closeMarker]`; content recursively parsed.
    case strikethrough(range: NSRange, markers: [NSRange], children: [InlineNode])
    /// `$math$` — opaque. `markers` is `[ "$", "$" ]`.
    case inlineLatex(range: NSRange, content: NSRange, markers: [NSRange])
    /// A backslash escape `\x`. `marker` is the backslash; `character` the now-literal punctuation.
    case escape(range: NSRange, character: NSRange, marker: NSRange)
}

enum InlineParser {

    private static let backtick: unichar = 0x60
    private static let asterisk: unichar = 0x2A
    private static let underscore: unichar = 0x5F
    private static let newline: unichar = 0x0A
    private static let bang: unichar = 0x21
    private static let lbracket: unichar = 0x5B
    private static let rbracket: unichar = 0x5D
    private static let lparen: unichar = 0x28
    private static let rparen: unichar = 0x29
    private static let pipe: unichar = 0x7C
    private static let backslash: unichar = 0x5C
    private static let tilde: unichar = 0x7E
    private static let dollar: unichar = 0x24

    // MARK: - Entry point

    static func parse(_ text: String) -> [InlineNode] {
        let ns = text as NSString
        let len = ns.length
        guard len > 0 else { return [] }

        var claimed = scanCodeSpans(ns, len: len)
        claimed += scanEscapes(ns, len: len, claimed: claimed.map(\.fullRange))
        claimed += scanLinkFamily(ns, len: len, claimed: claimed.map(\.fullRange))
        let emphasis = resolveEmphasis(ns, len: len, claimedRanges: claimed.map(\.fullRange))
        return buildTree(region: NSRange(location: 0, length: len), spans: claimed + emphasis, ns: ns)
    }

    /// Parse the inline content of `range` within `ns`, returning nodes in
    /// absolute document coordinates.
    static func parse(_ ns: NSString, range: NSRange) -> [InlineNode] {
        offsetNodes(parse(ns.substring(with: range)), by: range.location)
    }

    // MARK: - Span model

    private enum Span {
        case code(range: NSRange, content: NSRange)
        case emphasis(kind: EmphasisKind, range: NSRange, open: NSRange, close: NSRange)
        case link(range: NSRange, textRange: NSRange, url: NSRange, markers: [NSRange])
        case image(range: NSRange, alt: NSRange, url: NSRange, markers: [NSRange])
        case wikiLink(range: NSRange, name: NSRange, id: NSRange?, markers: [NSRange])
        case imageEmbed(range: NSRange, target: NSRange, markers: [NSRange])
        case strikethrough(range: NSRange, contentRange: NSRange, markers: [NSRange])
        case inlineLatex(range: NSRange, content: NSRange, markers: [NSRange])
        case escape(range: NSRange, character: NSRange, marker: NSRange)

        var fullRange: NSRange {
            switch self {
            case .code(let r, _), .emphasis(_, let r, _, _), .link(let r, _, _, _),
                 .image(let r, _, _, _), .wikiLink(let r, _, _, _), .imageEmbed(let r, _, _),
                 .strikethrough(let r, _, _), .inlineLatex(let r, _, _), .escape(let r, _, _):
                return r
            }
        }
        /// Region whose interior holds already-collected child spans. Only
        /// emphasis qualifies; link/strike content is re-parsed, the rest opaque.
        var containerContent: NSRange? {
            if case .emphasis(_, _, let open, let close) = self {
                return NSRange(location: NSMaxRange(open), length: close.location - NSMaxRange(open))
            }
            return nil
        }
    }

    // MARK: - 1. Code spans

    private static func scanCodeSpans(_ ns: NSString, len: Int) -> [Span] {
        var spans: [Span] = []
        var i = 0
        while i < len {
            guard ns.character(at: i) == backtick, !isEscaped(i, ns) else { i += 1; continue }
            let runStart = i
            var j = i
            while j < len, ns.character(at: j) == backtick { j += 1 }
            let runLen = j - runStart
            guard let close = closingBacktickRun(in: ns, from: j, length: len, runLen: runLen) else {
                i = j; continue
            }
            let codeRange = NSRange(location: runStart, length: (close + runLen) - runStart)
            let rawContent = NSRange(location: j, length: close - j)
            spans.append(.code(range: codeRange, content: strippedCodeContent(rawContent, in: ns)))
            i = close + runLen
        }
        return spans
    }

    private static func closingBacktickRun(in ns: NSString, from: Int, length len: Int, runLen: Int) -> Int? {
        var k = from
        while k < len {
            guard ns.character(at: k) == backtick, !isEscaped(k, ns) else { k += 1; continue }
            let start = k
            while k < len, ns.character(at: k) == backtick { k += 1 }
            if k - start == runLen { return start }
        }
        return nil
    }

    private static func strippedCodeContent(_ raw: NSRange, in ns: NSString) -> NSRange {
        let space: unichar = 0x20
        guard raw.length >= 2,
              ns.character(at: raw.location) == space,
              ns.character(at: NSMaxRange(raw) - 1) == space else { return raw }
        var allSpaces = true
        for k in raw.location..<NSMaxRange(raw) where ns.character(at: k) != space {
            allSpaces = false; break
        }
        guard !allSpaces else { return raw }
        return NSRange(location: raw.location + 1, length: raw.length - 2)
    }

    // MARK: - 2. Backslash escapes (claimed → escaped chars are inert everywhere)

    private static func scanEscapes(_ ns: NSString, len: Int, claimed: [NSRange]) -> [Span] {
        func inClaimed(_ idx: Int) -> Bool { claimed.contains { NSLocationInRange(idx, $0) } }
        var spans: [Span] = []
        var i = 0
        while i < len - 1 {
            if ns.character(at: i) == backslash, !inClaimed(i), isAsciiPunctuationChar(ns.character(at: i + 1)) {
                spans.append(.escape(
                    range: NSRange(location: i, length: 2),
                    character: NSRange(location: i + 1, length: 1),
                    marker: NSRange(location: i, length: 1)
                ))
                i += 2   // the escaped char can't itself start a new escape (even/odd `\\`)
            } else {
                i += 1
            }
        }
        return spans
    }

    // MARK: - 3. Link family / strikethrough / inline LaTeX

    private static func scanLinkFamily(_ ns: NSString, len: Int, claimed: [NSRange]) -> [Span] {
        func overlapsClaimed(_ range: NSRange) -> Bool {
            claimed.contains { NSIntersectionRange($0, range).length > 0 }
        }
        var spans: [Span] = []
        var i = 0
        while i < len {
            if claimed.contains(where: { NSLocationInRange(i, $0) }) { i += 1; continue }
            if let span = matchClaimedSpan(ns, len, at: i), !overlapsClaimed(span.fullRange) {
                spans.append(span)
                i = NSMaxRange(span.fullRange)
            } else {
                i += 1
            }
        }
        return spans
    }

    private static func matchClaimedSpan(_ ns: NSString, _ len: Int, at i: Int) -> Span? {
        let c = ns.character(at: i)
        let c1 = peek(ns, i + 1, len)
        let c2 = peek(ns, i + 2, len)
        if c == bang, c1 == lbracket, c2 == lbracket { return matchImageEmbed(ns, len, start: i) }
        if c == lbracket, c1 == lbracket { return matchWikiLink(ns, len, start: i) }
        if c == bang, c1 == lbracket { return matchImage(ns, len, start: i) }
        if c == lbracket { return matchLink(ns, len, start: i) }
        if c == tilde, c1 == tilde { return matchStrikethrough(ns, len, start: i) }
        if c == dollar, c1 != dollar { return matchInlineLatex(ns, len, start: i) }
        return nil
    }

    private static func peek(_ ns: NSString, _ idx: Int, _ len: Int) -> unichar? {
        (idx >= 0 && idx < len) ? ns.character(at: idx) : nil
    }

    /// `![[ target ]]`
    private static func matchImageEmbed(_ ns: NSString, _ len: Int, start i: Int) -> Span? {
        let contentStart = i + 3
        guard let close = closeDoubleBracket(ns, len, from: contentStart) else { return nil }
        return .imageEmbed(
            range: NSRange(location: i, length: (close + 2) - i),
            target: NSRange(location: contentStart, length: close - contentStart),
            markers: [NSRange(location: i, length: 3), NSRange(location: close, length: 2)]
        )
    }

    /// `[[ name (| id)? ]]`
    private static func matchWikiLink(_ ns: NSString, _ len: Int, start i: Int) -> Span? {
        let contentStart = i + 2
        var k = contentStart
        var pipeIdx = -1
        while k < len {
            let ch = ns.character(at: k)
            if ch == newline { return nil }
            if ch == pipe, pipeIdx == -1 { pipeIdx = k }
            if ch == rbracket {
                guard peek(ns, k + 1, len) == rbracket else { return nil }
                let range = NSRange(location: i, length: (k + 2) - i)
                let markers = [NSRange(location: i, length: 2), NSRange(location: k, length: 2)]
                if pipeIdx >= 0 {
                    return .wikiLink(range: range,
                                     name: NSRange(location: contentStart, length: pipeIdx - contentStart),
                                     id: NSRange(location: pipeIdx + 1, length: k - (pipeIdx + 1)),
                                     markers: markers)
                }
                return .wikiLink(range: range,
                                 name: NSRange(location: contentStart, length: k - contentStart),
                                 id: nil, markers: markers)
            }
            k += 1
        }
        return nil
    }

    /// `![ alt ]( url )`
    private static func matchImage(_ ns: NSString, _ len: Int, start i: Int) -> Span? {
        let altStart = i + 2
        guard let closeBracket = findChar(ns, len, from: altStart, char: rbracket),
              peek(ns, closeBracket + 1, len) == lparen,
              let closeParen = balancedParen(ns, len, from: closeBracket + 2) else { return nil }
        let urlStart = closeBracket + 2
        guard closeParen > urlStart else { return nil }
        return .image(
            range: NSRange(location: i, length: (closeParen + 1) - i),
            alt: NSRange(location: altStart, length: closeBracket - altStart),
            url: NSRange(location: urlStart, length: closeParen - urlStart),
            markers: [
                NSRange(location: i, length: 2),
                NSRange(location: closeBracket, length: 1),
                NSRange(location: closeBracket + 1, length: 1),
                NSRange(location: closeParen, length: 1),
            ]
        )
    }

    /// `[ text ]( url )`
    private static func matchLink(_ ns: NSString, _ len: Int, start i: Int) -> Span? {
        let textStart = i + 1
        guard let closeBracket = findChar(ns, len, from: textStart, char: rbracket),
              closeBracket > textStart,
              peek(ns, closeBracket + 1, len) == lparen,
              let closeParen = balancedParen(ns, len, from: closeBracket + 2) else { return nil }
        let urlStart = closeBracket + 2
        guard closeParen > urlStart else { return nil }
        return .link(
            range: NSRange(location: i, length: (closeParen + 1) - i),
            textRange: NSRange(location: textStart, length: closeBracket - textStart),
            url: NSRange(location: urlStart, length: closeParen - urlStart),
            markers: [
                NSRange(location: i, length: 1),
                NSRange(location: closeBracket, length: 1),
                NSRange(location: closeBracket + 1, length: 1),
                NSRange(location: closeParen, length: 1),
            ]
        )
    }

    /// `~~ text ~~` — text has no `~`; not part of a longer `~` run.
    private static func matchStrikethrough(_ ns: NSString, _ len: Int, start i: Int) -> Span? {
        if i > 0, ns.character(at: i - 1) == tilde { return nil }
        let contentStart = i + 2
        var k = contentStart
        while k < len {
            let ch = ns.character(at: k)
            if ch == newline { return nil }
            if ch == tilde {
                guard peek(ns, k + 1, len) == tilde else { return nil }
                guard k > contentStart, peek(ns, k + 2, len) != tilde else { return nil }
                return .strikethrough(
                    range: NSRange(location: i, length: (k + 2) - i),
                    contentRange: NSRange(location: contentStart, length: k - contentStart),
                    markers: [NSRange(location: i, length: 2), NSRange(location: k, length: 2)]
                )
            }
            k += 1
        }
        return nil
    }

    /// `$ math $` — single dollars, content has no `$`, passes the math heuristic.
    private static func matchInlineLatex(_ ns: NSString, _ len: Int, start i: Int) -> Span? {
        if i > 0, ns.character(at: i - 1) == dollar { return nil }
        let contentStart = i + 1
        var k = contentStart
        while k < len {
            let ch = ns.character(at: k)
            if ch == newline { return nil }
            if ch == dollar {
                guard k > contentStart, peek(ns, k + 1, len) != dollar else { return nil }
                let content = NSRange(location: contentStart, length: k - contentStart)
                guard isInlineMathContent(ns.substring(with: content)) else { return nil }
                return .inlineLatex(
                    range: NSRange(location: i, length: (k + 1) - i),
                    content: content,
                    markers: [NSRange(location: i, length: 1), NSRange(location: k, length: 1)]
                )
            }
            k += 1
        }
        return nil
    }

    private static func closeDoubleBracket(_ ns: NSString, _ len: Int, from: Int) -> Int? {
        var k = from
        while k < len {
            let ch = ns.character(at: k)
            if ch == newline { return nil }
            if ch == rbracket { return peek(ns, k + 1, len) == rbracket ? k : nil }
            k += 1
        }
        return nil
    }

    private static func findChar(_ ns: NSString, _ len: Int, from: Int, char: unichar) -> Int? {
        var k = from
        while k < len {
            let ch = ns.character(at: k)
            if ch == char { return k }
            if ch == newline { return nil }
            k += 1
        }
        return nil
    }

    private static func balancedParen(_ ns: NSString, _ len: Int, from: Int) -> Int? {
        var depth = 1
        var k = from
        while k < len {
            let ch = ns.character(at: k)
            if ch == newline { return nil }
            if ch == lparen { depth += 1 }
            else if ch == rparen { depth -= 1; if depth == 0 { return k } }
            k += 1
        }
        return nil
    }

    /// Ported from the regex tokenizer: rejects currency-looking and trivially
    /// short non-mathy `$…$` so plain prose isn't misread as math.
    private static func isInlineMathContent(_ content: String) -> Bool {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        let currencyPattern = #"^[+-]?(\d{1,3}(?:,\d{3})*|\d+)(?:\.\d+)?$"#
        if trimmed.range(of: currencyPattern, options: .regularExpression) != nil { return false }
        let mathyPattern = #"[\\\^\_\{\}=+\-*/<>]"#
        let mathyRegex = try? NSRegularExpression(pattern: mathyPattern)
        let mathyMatches = mathyRegex?.numberOfMatches(
            in: trimmed, range: NSRange(location: 0, length: trimmed.utf16.count)
        ) ?? 0
        if mathyMatches == 0 {
            if trimmed.count <= 3, trimmed.range(of: #"^[A-Za-z]{1,3}$"#, options: .regularExpression) != nil {
                return true
            }
            return false
        }
        let tokenCount = trimmed.split(whereSeparator: { $0.isWhitespace }).count
        if mathyMatches >= 3 { return tokenCount <= 120 }
        if mathyMatches == 2 { return tokenCount <= 40 }
        return tokenCount <= 6
    }

    // MARK: - 4. Emphasis (delimiter runs)

    private struct DelimRun {
        let char: unichar
        let originalLength: Int
        var leftEdge: Int
        var rightEdge: Int
        let canOpen: Bool
        let canClose: Bool
        let lineIdx: Int
        var remaining: Int { rightEdge - leftEdge }
    }

    private static func resolveEmphasis(_ ns: NSString, len: Int, claimedRanges: [NSRange]) -> [Span] {
        var runs = collectDelimiterRuns(ns, len: len, claimedRanges: claimedRanges)
        guard !runs.isEmpty else { return [] }
        var stack: [Int] = []
        var spans: [Span] = []
        for idx in runs.indices {
            if runs[idx].canClose {
                closeAgainstStack(closerIdx: idx, runs: &runs, stack: &stack, spans: &spans)
            }
            if runs[idx].canOpen && runs[idx].remaining > 0 {
                stack.append(idx)
            }
        }
        return spans
    }

    private static func collectDelimiterRuns(_ ns: NSString, len: Int, claimedRanges: [NSRange]) -> [DelimRun] {
        func inClaimed(_ idx: Int) -> Bool {
            for r in claimedRanges where NSLocationInRange(idx, r) { return true }
            return false
        }
        var runs: [DelimRun] = []
        var lineIdx = 0
        var i = 0
        while i < len {
            let c = ns.character(at: i)
            if c == newline { lineIdx += 1; i += 1; continue }
            guard c == asterisk || c == underscore, !inClaimed(i) else { i += 1; continue }
            var j = i
            while j < len, ns.character(at: j) == c { j += 1 }

            let before = i - 1, after = j
            let beforeWs = isWhitespaceOrBoundary(before, ns, len)
            let beforePunct = isAsciiPunctuation(before, ns, len)
            let afterWs = isWhitespaceOrBoundary(after, ns, len)
            let afterPunct = isAsciiPunctuation(after, ns, len)
            let leftFlanking = !afterWs && (!afterPunct || beforeWs || beforePunct)
            let rightFlanking = !beforeWs && (!beforePunct || afterWs || afterPunct)

            let canOpen: Bool, canClose: Bool
            if c == underscore {
                canOpen = leftFlanking && (!rightFlanking || beforePunct)
                canClose = rightFlanking && (!leftFlanking || afterPunct)
            } else {
                canOpen = leftFlanking
                canClose = rightFlanking
            }
            runs.append(DelimRun(
                char: c, originalLength: j - i, leftEdge: i, rightEdge: j,
                canOpen: canOpen, canClose: canClose, lineIdx: lineIdx
            ))
            i = j
        }
        return runs
    }

    private static func closeAgainstStack(
        closerIdx: Int, runs: inout [DelimRun], stack: inout [Int], spans: inout [Span]
    ) {
        var sp = stack.count - 1
        while sp >= 0, runs[closerIdx].remaining > 0 {
            let openerIdx = stack[sp]
            if runs[openerIdx].char != runs[closerIdx].char { sp -= 1; continue }
            if runs[openerIdx].lineIdx != runs[closerIdx].lineIdx {
                stack.remove(at: sp); sp -= 1; continue
            }
            let avail = min(runs[openerIdx].remaining, runs[closerIdx].remaining)
            if avail == 0 { stack.remove(at: sp); sp -= 1; continue }

            let openerBoth = runs[openerIdx].canOpen && runs[openerIdx].canClose
            let closerBoth = runs[closerIdx].canOpen && runs[closerIdx].canClose
            if openerBoth || closerBoth {
                let sum = runs[openerIdx].originalLength + runs[closerIdx].originalLength
                let bothMod3 = runs[openerIdx].originalLength % 3 == 0 && runs[closerIdx].originalLength % 3 == 0
                if sum % 3 == 0 && !bothMod3 { sp -= 1; continue }
            }

            let matchLen = avail >= 3 ? 3 : (avail >= 2 ? 2 : 1)
            let openerMarkerStart = runs[openerIdx].rightEdge - matchLen
            let closerMarkerStart = runs[closerIdx].leftEdge
            let kind: EmphasisKind = matchLen == 3 ? .boldItalic : (matchLen == 2 ? .bold : .italic)

            spans.append(.emphasis(
                kind: kind,
                range: NSRange(location: openerMarkerStart, length: (closerMarkerStart + matchLen) - openerMarkerStart),
                open: NSRange(location: openerMarkerStart, length: matchLen),
                close: NSRange(location: closerMarkerStart, length: matchLen)
            ))

            runs[openerIdx].rightEdge -= matchLen
            runs[closerIdx].leftEdge += matchLen
            if runs[openerIdx].remaining == 0 { stack.remove(at: sp) }
            sp -= 1
        }
    }

    // MARK: - 5. Containment tree

    private static func buildTree(region: NSRange, spans: [Span], ns: NSString) -> [InlineNode] {
        let inRegion = spans.filter { rangeContains(region, $0.fullRange) }

        func isChild(_ s: Span) -> Bool {
            for parent in inRegion {
                guard !equalRange(parent.fullRange, s.fullRange), let content = parent.containerContent else { continue }
                if rangeContains(content, s.fullRange) { return true }
            }
            return false
        }

        let top = inRegion.filter { !isChild($0) }.sorted { $0.fullRange.location < $1.fullRange.location }
        var result: [InlineNode] = []
        var cursor = region.location

        for span in top {
            let fr = span.fullRange
            if fr.location > cursor {
                result.append(.text(NSRange(location: cursor, length: fr.location - cursor)))
            }
            switch span {
            case .code(let range, let content):
                result.append(.code(range: range, content: content))
            case .emphasis(let kind, let range, let open, let close):
                let content = NSRange(location: NSMaxRange(open), length: close.location - NSMaxRange(open))
                let childSpans = inRegion.filter { rangeContains(content, $0.fullRange) && !equalRange($0.fullRange, fr) }
                result.append(.emphasis(kind, range: range, markers: [open, close],
                                        children: buildTree(region: content, spans: childSpans, ns: ns)))
            case .link(let range, let textRange, let url, let markers):
                result.append(.link(range: range, textRange: textRange, url: url, markers: markers,
                                     children: reparse(textRange, ns: ns)))
            case .image(let range, let alt, let url, let markers):
                result.append(.image(range: range, alt: alt, url: url, markers: markers))
            case .wikiLink(let range, let name, let id, let markers):
                result.append(.wikiLink(range: range, name: name, id: id, markers: markers))
            case .imageEmbed(let range, let target, let markers):
                result.append(.imageEmbed(range: range, target: target, markers: markers))
            case .strikethrough(let range, let contentRange, let markers):
                result.append(.strikethrough(range: range, markers: markers,
                                             children: reparse(contentRange, ns: ns)))
            case .inlineLatex(let range, let content, let markers):
                result.append(.inlineLatex(range: range, content: content, markers: markers))
            case .escape(let range, let character, let marker):
                result.append(.escape(range: range, character: character, marker: marker))
            }
            cursor = NSMaxRange(fr)
        }
        if cursor < NSMaxRange(region) {
            result.append(.text(NSRange(location: cursor, length: NSMaxRange(region) - cursor)))
        }
        return result
    }

    /// Recursively parse a sub-range's content, offset back to absolute coordinates.
    private static func reparse(_ range: NSRange, ns: NSString) -> [InlineNode] {
        offsetNodes(parse(ns.substring(with: range)), by: range.location)
    }

    // MARK: - Helpers

    private static func offsetNodes(_ nodes: [InlineNode], by delta: Int) -> [InlineNode] {
        nodes.map { offset($0, by: delta) }
    }

    private static func offset(_ node: InlineNode, by d: Int) -> InlineNode {
        func s(_ r: NSRange) -> NSRange { NSRange(location: r.location + d, length: r.length) }
        switch node {
        case .text(let r): return .text(s(r))
        case .code(let r, let c): return .code(range: s(r), content: s(c))
        case .emphasis(let k, let r, let m, let ch): return .emphasis(k, range: s(r), markers: m.map(s), children: offsetNodes(ch, by: d))
        case .link(let r, let tr, let u, let m, let ch): return .link(range: s(r), textRange: s(tr), url: s(u), markers: m.map(s), children: offsetNodes(ch, by: d))
        case .image(let r, let a, let u, let m): return .image(range: s(r), alt: s(a), url: s(u), markers: m.map(s))
        case .wikiLink(let r, let n, let id, let m): return .wikiLink(range: s(r), name: s(n), id: id.map(s), markers: m.map(s))
        case .imageEmbed(let r, let t, let m): return .imageEmbed(range: s(r), target: s(t), markers: m.map(s))
        case .strikethrough(let r, let m, let ch): return .strikethrough(range: s(r), markers: m.map(s), children: offsetNodes(ch, by: d))
        case .inlineLatex(let r, let c, let m): return .inlineLatex(range: s(r), content: s(c), markers: m.map(s))
        case .escape(let r, let c, let m): return .escape(range: s(r), character: s(c), marker: s(m))
        }
    }

    private static func rangeContains(_ outer: NSRange, _ inner: NSRange) -> Bool {
        inner.location >= outer.location && NSMaxRange(inner) <= NSMaxRange(outer)
    }

    private static func equalRange(_ a: NSRange, _ b: NSRange) -> Bool {
        a.location == b.location && a.length == b.length
    }

    private static func isWhitespaceOrBoundary(_ idx: Int, _ ns: NSString, _ len: Int) -> Bool {
        guard idx >= 0, idx < len else { return true }
        let c = ns.character(at: idx)
        return c == 0x20 || c == 0x09 || c == 0x0A || c == 0x0D
    }

    private static func isAsciiPunctuation(_ idx: Int, _ ns: NSString, _ len: Int) -> Bool {
        guard idx >= 0, idx < len else { return false }
        return isAsciiPunctuationChar(ns.character(at: idx))
    }

    private static func isAsciiPunctuationChar(_ c: unichar) -> Bool {
        (c >= 0x21 && c <= 0x2F) || (c >= 0x3A && c <= 0x40)
            || (c >= 0x5B && c <= 0x60) || (c >= 0x7B && c <= 0x7E)
    }

    /// A character is backslash-escaped when preceded by an odd run of `\`.
    private static func isEscaped(_ idx: Int, _ ns: NSString) -> Bool {
        var count = 0
        var k = idx - 1
        while k >= 0, ns.character(at: k) == backslash { count += 1; k -= 1 }
        return count % 2 == 1
    }
}
