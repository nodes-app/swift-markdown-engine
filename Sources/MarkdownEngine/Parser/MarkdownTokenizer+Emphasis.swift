//
//  MarkdownTokenizer+Emphasis.swift
//  MarkdownEngine
//
//  Created by Luca Chen on 05.05.26.
//
//  Stack-based parser for `*`-delimited bold/italic/bold+italic that handles arbitrary nesting on a single line.
//

import Foundation

extension MarkdownTokenizer {
    static func parseEmphasisTokens(in text: String) -> [MarkdownToken] {
        let nsText = text as NSString
        let len = nsText.length
        guard len > 0 else { return [] }

        let runs = collectAsteriskRuns(in: nsText, length: len)
        guard !runs.isEmpty else { return [] }

        var workingRuns = runs
        var stack: [Int] = []
        var tokens: [MarkdownToken] = []

        for closerIdx in workingRuns.indices {
            if workingRuns[closerIdx].closeable {
                tryClose(closerIdx: closerIdx,
                         runs: &workingRuns,
                         stack: &stack,
                         tokens: &tokens)
            }
            if workingRuns[closerIdx].openable && workingRuns[closerIdx].remaining > 0 {
                stack.append(closerIdx)
            }
        }
        return tokens
    }

    private struct AsteriskRun {
        let originalStart: Int
        let originalLength: Int
        var leftEdge: Int
        var rightEdge: Int
        let openable: Bool
        let closeable: Bool
        let lineIdx: Int

        var remaining: Int { rightEdge - leftEdge }
    }

    private static func collectAsteriskRuns(in nsText: NSString, length len: Int) -> [AsteriskRun] {
        var result: [AsteriskRun] = []
        var lineIdx = 0
        var i = 0
        while i < len {
            let c = nsText.character(at: i)
            if c == 0x0A {
                lineIdx += 1
                i += 1
                continue
            }
            if c != 0x2A {
                i += 1
                continue
            }
            var j = i
            while j < len, nsText.character(at: j) == 0x2A {
                j += 1
            }
            let beforeCharIdx = i - 1
            let afterCharIdx = j
            let beforeWs = isWhitespaceOrBoundary(at: beforeCharIdx, in: nsText, length: len)
            let beforePunct = isAsciiPunctuation(at: beforeCharIdx, in: nsText, length: len)
            let afterWs = isWhitespaceOrBoundary(at: afterCharIdx, in: nsText, length: len)
            let afterPunct = isAsciiPunctuation(at: afterCharIdx, in: nsText, length: len)
            let leftFlanking = !afterWs && (!afterPunct || beforeWs || beforePunct)
            let rightFlanking = !beforeWs && (!beforePunct || afterWs || afterPunct)
            result.append(AsteriskRun(
                originalStart: i,
                originalLength: j - i,
                leftEdge: i,
                rightEdge: j,
                openable: leftFlanking,
                closeable: rightFlanking,
                lineIdx: lineIdx
            ))
            i = j
        }
        return result
    }

    private static func tryClose(
        closerIdx: Int,
        runs: inout [AsteriskRun],
        stack: inout [Int],
        tokens: inout [MarkdownToken]
    ) {
        var sp = stack.count - 1
        while sp >= 0 && runs[closerIdx].remaining > 0 {
            let openerIdx = stack[sp]
            if runs[openerIdx].lineIdx != runs[closerIdx].lineIdx {
                stack.remove(at: sp)
                sp -= 1
                continue
            }
            let avail = min(runs[openerIdx].remaining, runs[closerIdx].remaining)
            if avail == 0 {
                stack.remove(at: sp)
                sp -= 1
                continue
            }
            // CommonMark Rule of 3: when either side is intra-word (can both open and close), the sum of original run lengths must not be a multiple of 3 unless both lengths are.
            let openerCanBoth = runs[openerIdx].openable && runs[openerIdx].closeable
            let closerCanBoth = runs[closerIdx].openable && runs[closerIdx].closeable
            if openerCanBoth || closerCanBoth {
                let sum = runs[openerIdx].originalLength + runs[closerIdx].originalLength
                let bothMod3 = (runs[openerIdx].originalLength % 3 == 0) && (runs[closerIdx].originalLength % 3 == 0)
                if sum % 3 == 0 && !bothMod3 {
                    sp -= 1
                    continue
                }
            }
            let matchLen = avail >= 3 ? 3 : (avail >= 2 ? 2 : 1)
            let openerMarkerStart = runs[openerIdx].rightEdge - matchLen
            let closerMarkerStart = runs[closerIdx].leftEdge
            let fullStart = openerMarkerStart
            let fullEnd = closerMarkerStart + matchLen
            let contentStart = openerMarkerStart + matchLen
            let contentEnd = closerMarkerStart

            let kind: MarkdownTokenKind
            switch matchLen {
            case 3: kind = .boldItalic
            case 2: kind = .bold
            default: kind = .italic
            }

            tokens.append(MarkdownToken(
                kind: kind,
                range: NSRange(location: fullStart, length: fullEnd - fullStart),
                contentRange: NSRange(location: contentStart, length: contentEnd - contentStart),
                markerRanges: [
                    NSRange(location: openerMarkerStart, length: matchLen),
                    NSRange(location: closerMarkerStart, length: matchLen)
                ]
            ))

            runs[openerIdx].rightEdge -= matchLen
            runs[closerIdx].leftEdge += matchLen

            if runs[openerIdx].remaining == 0 {
                stack.remove(at: sp)
            }
            sp -= 1
        }
    }

    private static func isWhitespaceOrBoundary(at idx: Int, in nsText: NSString, length len: Int) -> Bool {
        guard idx >= 0 && idx < len else { return true }
        let c = nsText.character(at: idx)
        return c == 0x20 || c == 0x09 || c == 0x0A || c == 0x0D
    }

    private static func isAsciiPunctuation(at idx: Int, in nsText: NSString, length len: Int) -> Bool {
        guard idx >= 0 && idx < len else { return false }
        let c = nsText.character(at: idx)
        // CommonMark ASCII punctuation set.
        return (c >= 0x21 && c <= 0x2F)
            || (c >= 0x3A && c <= 0x40)
            || (c >= 0x5B && c <= 0x60)
            || (c >= 0x7B && c <= 0x7E)
    }
}
