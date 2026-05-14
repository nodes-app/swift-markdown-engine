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
            classifyLine(lineRange: lineRange, state: &state)
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

    // MARK: - Classification

    private static func classifyLine(lineRange: NSRange, state: inout ScannerState) {
        let contentRange = trimTrailingNewline(lineRange, in: state.nsText)

        // Blank line ends paragraph buffering.
        if isBlankLine(contentRange, in: state.nsText) {
            state.flushBufferedParagraph()
            return
        }

        // ATX heading: ^#{1,6} + ' '
        if let heading = atxHeading(lineRange: lineRange, contentRange: contentRange, in: state.nsText) {
            state.flushBufferedParagraph()
            state.blocks.append(heading)
            return
        }

        // Default: buffer as paragraph line. Setext / other lookahead handled in later tasks.
        state.appendParagraphLine(lineRange)
    }

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
}
