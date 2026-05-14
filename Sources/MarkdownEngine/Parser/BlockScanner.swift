//
//  BlockScanner.swift
//  MarkdownEngine
//
//  Phase-1 block-level Markdown parser. Walks the source line-by-line,
//  classifies each line, and emits `[BlockSpan]` plus a link-reference
//  map. The inline parser (MarkdownTokenizer.parseTokens) runs over the
//  content substring of each inline-allowing block.
//
//  Paragraph emission is buffered so Setext heading lookahead can rewrite
//  the buffered paragraph into a heading when the next line is an
//  underline (===, ---).
//

import Foundation

enum BlockScanner {

    /// Single entry point: classify all blocks in `text`.
    static func scan(_ text: String) -> BlockScanResult {
        let nsText = text as NSString
        let length = nsText.length
        guard length > 0 else { return BlockScanResult(blocks: [], linkReferences: [:]) }

        var state = ScannerState(nsText: nsText)
        var lineStart = 0

        while lineStart < length {
            let lineEnd = nextLineEnd(in: nsText, from: lineStart, length: length)
            let lineRange = NSRange(location: lineStart, length: lineEnd - lineStart)
            let contentRange = trimTrailingNewline(lineRange, in: nsText)

            // 1) Blank line ends paragraph buffering.
            if isBlankLine(contentRange, in: nsText) {
                state.flushBufferedParagraph()
                lineStart = lineEnd
                continue
            }

            // 2) Fenced code block (multi-line — consumes until closing fence).
            if let opener = fencedCodeOpener(contentRange: contentRange, in: nsText) {
                state.flushBufferedParagraph()
                if let consumed = consumeFencedCode(
                    opener: opener,
                    openerLineRange: lineRange,
                    nsText: nsText,
                    length: length,
                    state: &state
                ) {
                    lineStart = consumed
                    continue
                }
                // Unclosed fence: fall through to paragraph treatment.
            }

            // 3) ATX heading (single line).
            if let heading = atxHeading(lineRange: lineRange, contentRange: contentRange, in: nsText) {
                state.flushBufferedParagraph()
                state.blocks.append(heading)
                lineStart = lineEnd
                continue
            }

            // 4) Default: buffer as paragraph line.
            state.appendParagraphLine(lineRange)
            lineStart = lineEnd
        }

        state.flushBufferedParagraph()
        return BlockScanResult(blocks: state.blocks, linkReferences: state.linkReferences)
    }

    // MARK: - Internal state

    private struct ScannerState {
        let nsText: NSString
        var blocks: [BlockSpan] = []
        var linkReferences: [String: LinkReference] = [:]
        /// Buffered paragraph lines awaiting commit (Setext-heading lookahead).
        var paragraphBuffer: [NSRange] = []

        mutating func appendParagraphLine(_ lineRange: NSRange) {
            paragraphBuffer.append(lineRange)
        }

        mutating func flushBufferedParagraph() {
            guard let first = paragraphBuffer.first, let last = paragraphBuffer.last else { return }
            let range = NSRange(location: first.location,
                                length: NSMaxRange(last) - first.location)
            blocks.append(BlockSpan(
                kind: .paragraph,
                range: range,
                contentRange: range,
                markerRanges: []
            ))
            paragraphBuffer.removeAll(keepingCapacity: true)
        }
    }

    // MARK: - Line iteration

    /// End of the line that starts at `start`, including the trailing newline.
    private static func nextLineEnd(in nsText: NSString, from start: Int, length: Int) -> Int {
        var i = start
        while i < length {
            let c = nsText.character(at: i)
            if c == 0x0A {           // LF
                return i + 1
            }
            if c == 0x0D {           // CR (maybe CRLF)
                if i + 1 < length, nsText.character(at: i + 1) == 0x0A {
                    return i + 2
                }
                return i + 1
            }
            i += 1
        }
        return length
    }

    // MARK: - Classification helpers

    private static func trimTrailingNewline(_ range: NSRange, in nsText: NSString) -> NSRange {
        var length = range.length
        let end = range.location + range.length
        if length >= 2,
           nsText.character(at: end - 2) == 0x0D,
           nsText.character(at: end - 1) == 0x0A {
            length -= 2
        } else if length >= 1 {
            let last = nsText.character(at: end - 1)
            if last == 0x0A || last == 0x0D { length -= 1 }
        }
        return NSRange(location: range.location, length: length)
    }

    private static func isBlankLine(_ range: NSRange, in nsText: NSString) -> Bool {
        for i in range.location..<NSMaxRange(range) {
            let c = nsText.character(at: i)
            if c != 0x20 && c != 0x09 { return false }
        }
        return true
    }

    // MARK: ATX heading

    private static func atxHeading(lineRange: NSRange, contentRange: NSRange, in nsText: NSString) -> BlockSpan? {
        // Up to 3 leading spaces allowed before #
        var i = contentRange.location
        let lineEnd = NSMaxRange(contentRange)
        var leadingSpaces = 0
        while i < lineEnd && leadingSpaces < 4 && nsText.character(at: i) == 0x20 {
            i += 1
            leadingSpaces += 1
        }
        if leadingSpaces >= 4 { return nil }

        // Count hashes (1...6)
        let hashStart = i
        var hashCount = 0
        while i < lineEnd && hashCount < 7 && nsText.character(at: i) == 0x23 {  // #
            i += 1
            hashCount += 1
        }
        guard hashCount >= 1, hashCount <= 6 else { return nil }

        // Must be followed by space/tab or end of line
        if i < lineEnd {
            let next = nsText.character(at: i)
            guard next == 0x20 || next == 0x09 else { return nil }
        }

        // Skip spaces between hashes and content
        let hashEnd = i
        _ = hashEnd
        while i < lineEnd {
            let c = nsText.character(at: i)
            if c == 0x20 || c == 0x09 { i += 1 } else { break }
        }
        let contentStart = i
        let contentEnd = lineEnd
        let cRange = NSRange(location: contentStart, length: max(0, contentEnd - contentStart))
        let hashRange = NSRange(location: hashStart, length: hashCount)

        return BlockSpan(
            kind: .heading(level: hashCount),
            range: lineRange,
            contentRange: cRange,
            markerRanges: [hashRange]
        )
    }

    // MARK: Fenced code

    private struct FencedCodeOpener {
        let fenceRange: NSRange
        let fenceChar: UInt16   // ` or ~
        let language: String?
    }

    /// Detects a fenced code block opener on `contentRange`. CommonMark allows
    /// up to 3 leading spaces and a fence of 3+ backticks or 3+ tildes.
    private static func fencedCodeOpener(contentRange: NSRange, in nsText: NSString) -> FencedCodeOpener? {
        let lineEnd = NSMaxRange(contentRange)
        var i = contentRange.location
        var leading = 0
        while i < lineEnd, nsText.character(at: i) == 0x20, leading < 4 {
            i += 1; leading += 1
        }
        if leading >= 4 { return nil }

        guard i < lineEnd else { return nil }
        let fenceChar = nsText.character(at: i)
        guard fenceChar == 0x60 /* ` */ || fenceChar == 0x7E /* ~ */ else { return nil }

        let fenceStart = i
        var count = 0
        while i < lineEnd, nsText.character(at: i) == fenceChar {
            i += 1; count += 1
        }
        guard count >= 3 else { return nil }

        // Backtick fences disallow ` anywhere on the opener line after the fence.
        if fenceChar == 0x60 {
            var j = i
            while j < lineEnd {
                if nsText.character(at: j) == 0x60 { return nil }
                j += 1
            }
        }

        // Language tag: rest of the line after fence, trimmed of whitespace.
        var langStart = i
        while langStart < lineEnd,
              (nsText.character(at: langStart) == 0x20 || nsText.character(at: langStart) == 0x09) {
            langStart += 1
        }
        var langEnd = lineEnd
        while langEnd > langStart,
              (nsText.character(at: langEnd - 1) == 0x20 || nsText.character(at: langEnd - 1) == 0x09) {
            langEnd -= 1
        }
        let language: String?
        if langStart < langEnd {
            language = nsText.substring(with: NSRange(location: langStart, length: langEnd - langStart))
        } else {
            language = nil
        }

        return FencedCodeOpener(
            fenceRange: NSRange(location: fenceStart, length: count),
            fenceChar: fenceChar,
            language: language
        )
    }

    /// Consume lines starting after `openerLineRange` until a matching closing
    /// fence (same char, at least as many) or EOF. Returns the index past the
    /// last consumed character, or `nil` if no closing fence was found.
    private static func consumeFencedCode(
        opener: FencedCodeOpener,
        openerLineRange: NSRange,
        nsText: NSString,
        length: Int,
        state: inout ScannerState
    ) -> Int? {
        let contentStart = NSMaxRange(openerLineRange)
        var cursor = contentStart
        var closingFenceRangeStorage: NSRange? = nil
        var blockEnd: Int = contentStart

        while cursor < length {
            let lineEnd = nextLineEnd(in: nsText, from: cursor, length: length)
            let contentRange = trimTrailingNewline(NSRange(location: cursor, length: lineEnd - cursor), in: nsText)

            if let closer = closingFenceRange(contentRange: contentRange,
                                              opener: opener,
                                              in: nsText) {
                closingFenceRangeStorage = closer
                blockEnd = lineEnd
                cursor = lineEnd
                break
            }

            cursor = lineEnd
            blockEnd = lineEnd
        }

        guard let closingFence = closingFenceRangeStorage else {
            return nil  // unclosed
        }

        let blockRange = NSRange(location: openerLineRange.location, length: blockEnd - openerLineRange.location)
        let codeContentRange = NSRange(location: contentStart, length: closingFence.location - contentStart)

        let block = BlockSpan(
            kind: .fencedCode(language: opener.language),
            range: blockRange,
            contentRange: codeContentRange,
            markerRanges: [opener.fenceRange, closingFence]
        )
        state.blocks.append(block)
        return cursor
    }

    /// If `contentRange` is a closing fence for `opener`, returns the range of
    /// the fence characters themselves (not including leading/trailing whitespace).
    /// Otherwise returns nil.
    private static func closingFenceRange(contentRange: NSRange, opener: FencedCodeOpener, in nsText: NSString) -> NSRange? {
        let lineEnd = NSMaxRange(contentRange)
        var i = contentRange.location
        var leading = 0
        while i < lineEnd, nsText.character(at: i) == 0x20, leading < 4 {
            i += 1; leading += 1
        }
        if leading >= 4 { return nil }
        let fenceStart = i
        var count = 0
        while i < lineEnd, nsText.character(at: i) == opener.fenceChar {
            i += 1; count += 1
        }
        guard count >= opener.fenceRange.length else { return nil }
        // Only whitespace allowed after the closing fence.
        while i < lineEnd {
            let c = nsText.character(at: i)
            if c != 0x20 && c != 0x09 { return nil }
            i += 1
        }
        return NSRange(location: fenceStart, length: count)
    }
}
