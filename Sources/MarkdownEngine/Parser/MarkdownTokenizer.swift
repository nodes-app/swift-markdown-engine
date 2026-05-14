//
//  MarkdownTokenizer.swift
//  MarkdownEngine
//
//  Created by Luca Chen on 18.02.26.
//

// Reads plain Markdown text and breaks it into recognizable parts like
// headings, links, lists, code blocks, and LaTeX.
import Foundation

// MARK: - Static Regexes
private extension MarkdownTokenizer {
    static let imageEmbedRegex = try! NSRegularExpression(
        pattern: "!\\[\\[([^\\]\\r\\n]*)\\]\\]"
    )
    static let wikiLinkRegex = try! NSRegularExpression(
        pattern: "\\[\\[([^\\|\\]\\r\\n]*)\\|?([^\\]\\r\\n]*)\\]\\]"
    )
    static let markdownLinkRegex = try! NSRegularExpression(
        pattern: "\\[([^\\]\\r\\n]+)\\]\\(([^\\)\\r\\n]+)\\)"
    )
    static let headingRegex = try! NSRegularExpression(
        pattern: "^\\s*(#{1,6}) +(.*)$",
        options: [.anchorsMatchLines]
    )
    static let taskListRegex = try! NSRegularExpression(
        pattern: #"^([ \t]*)([-•]|\d+\.)([ \t]+)(\[[ xX]\])(?=[ \t])"#,
        options: [.anchorsMatchLines]
    )
    static let codeBlockRegex = try! NSRegularExpression(
        pattern: #"^```[ \t]*([A-Za-z0-9_+#.-]*?)[ \t]*\r?\n((?:(?!^```[^\r\n]*$)[\s\S])*?)^(```)[^\r\n]*$"#,
        options: [.anchorsMatchLines]
    )
    static let inlineCodeRegex = try! NSRegularExpression(
        pattern: "`([^`\\n]+)`",
        options: []
    )
    static let blockLatexRegex = try! NSRegularExpression(
        pattern: #"(?s)(?<!\$)\$\$(.+?)\$\$"#,
        options: []
    )
    static let inlineLatexRegex = try! NSRegularExpression(
        pattern: "(?<!\\$)\\$(?!\\$)([^$\\n]+?)\\$(?!\\$)",
        options: []
    )
}

// MARK: - Tokenizer
enum MarkdownTokenizer {

    static func parseTokens(in text: String) -> [MarkdownToken] {
        var tokens: [MarkdownToken] = []
        let nsText = text as NSString
        let fullRange = NSRange(location: 0, length: nsText.length)
        guard nsText.length > 0 else { return [] }

        // ---------- Block phase ----------
        let blockResult = BlockScanner.scan(text)

        // Convert block spans into block-kind MarkdownTokens that the styler
        // already understands. (Headings, fenced code; thematic breaks and
        // link reference definitions don't have legacy MarkdownTokenKind
        // counterparts and are tracked only via BlockScanResult for now.)
        //
        // BlockScanner emits ranges over whole lines (including trailing
        // newlines) — the legacy regex-based parser excluded the trailing
        // newline from `.heading` / `.codeBlock` token ranges, so we trim it
        // here to keep the golden snapshot stable.
        for span in blockResult.blocks {
            switch span.kind {
            case .heading:
                tokens.append(MarkdownToken(
                    kind: .heading,
                    range: trimTrailingNewline(span.range, in: nsText),
                    contentRange: span.contentRange,
                    markerRanges: span.markerRanges
                ))
            case .fencedCode:
                tokens.append(MarkdownToken(
                    kind: .codeBlock,
                    range: trimTrailingNewline(span.range, in: nsText),
                    contentRange: span.contentRange,
                    markerRanges: span.markerRanges
                ))
            default:
                break
            }
        }

        // ---------- Inline phase ----------
        var inlineTokens: [MarkdownToken] = []

        // Emphasis (stack parser, already line-scoped).
        inlineTokens.append(contentsOf: parseEmphasisTokens(in: text))

        // Image embeds ![[...]] (parsed before wiki-links).
        var imageEmbedRanges: [NSRange] = []
        for match in imageEmbedRegex.matches(in: text, options: [], range: fullRange) {
            let full = match.range(at: 0)
            let content = match.range(at: 1)
            let openMarker = NSRange(location: full.location, length: 3)
            let closeMarker = NSRange(location: full.location + full.length - 2, length: 2)
            inlineTokens.append(MarkdownToken(kind: .imageEmbed,
                                              range: full,
                                              contentRange: content,
                                              markerRanges: [openMarker, closeMarker]))
            imageEmbedRanges.append(full)
        }

        // Wiki-links [[...]]
        for match in wikiLinkRegex.matches(in: text, options: [], range: fullRange) {
            let full = match.range(at: 0)
            if imageEmbedRanges.contains(where: { NSIntersectionRange($0, full).length > 0 }) {
                continue
            }
            let content = match.range(at: 1)
            let open = NSRange(location: full.location, length: 2)
            let close = NSRange(location: full.location + full.length - 2, length: 2)
            inlineTokens.append(MarkdownToken(kind: .wikiLink,
                                              range: full,
                                              contentRange: content,
                                              markerRanges: [open, close]))
        }

        // Markdown links [text](url)
        for match in markdownLinkRegex.matches(in: text, options: [], range: fullRange) {
            let full = match.range
            let textRange = match.range(at: 1)
            let urlRange = match.range(at: 2)
            let openBracket = NSRange(location: full.location, length: 1)
            let closeBracket = NSRange(location: textRange.location + textRange.length, length: 1)
            let openParen = NSRange(location: urlRange.location - 1, length: 1)
            let closeParen = NSRange(location: urlRange.location + urlRange.length, length: 1)
            inlineTokens.append(MarkdownToken(kind: .link,
                                              range: full,
                                              contentRange: textRange,
                                              markerRanges: [openBracket, closeBracket, openParen, closeParen]))
        }

        // Block LaTeX $$...$$ — runs only against ranges outside fenced code.
        for match in blockLatexRegex.matches(in: text, options: [], range: fullRange) {
            let full = match.range(at: 0)
            if isInsideFencedCode(range: full, blocks: blockResult.blocks) { continue }
            let content = match.range(at: 1)
            let openMarker = NSRange(location: full.location, length: 2)
            let closeMarker = NSRange(location: full.location + full.length - 2, length: 2)
            inlineTokens.append(MarkdownToken(kind: .blockLatex,
                                              range: full,
                                              contentRange: content,
                                              markerRanges: [openMarker, closeMarker]))
        }

        // Inline code `…`
        for match in inlineCodeRegex.matches(in: text, options: [], range: fullRange) {
            let full = match.range(at: 0)
            let content = match.range(at: 1)
            let openBacktick = NSRange(location: full.location, length: 1)
            let closeBacktick = NSRange(location: full.location + full.length - 1, length: 1)
            inlineTokens.append(MarkdownToken(kind: .inlineCode,
                                              range: full,
                                              contentRange: content,
                                              markerRanges: [openBacktick, closeBacktick]))
        }

        // Inline LaTeX $…$
        for match in inlineLatexRegex.matches(in: text, options: [], range: fullRange) {
            let full = match.range(at: 0)
            let content = match.range(at: 1)
            if isInsideFencedCode(range: full, blocks: blockResult.blocks) { continue }
            if isInsideBlockLatexInline(range: full, inlineTokens: inlineTokens) { continue }
            let contentString = nsText.substring(with: content)
            if !isInlineMathContent(contentString) { continue }
            let openDollar = NSRange(location: full.location, length: 1)
            let closeDollar = NSRange(location: full.location + full.length - 1, length: 1)
            inlineTokens.append(MarkdownToken(kind: .inlineLatex,
                                              range: full,
                                              contentRange: content,
                                              markerRanges: [openDollar, closeDollar]))
        }

        // ---------- Block-precedence filter ----------
        let allowedInline = inlineContainerRanges(from: blockResult.blocks)
        for t in inlineTokens {
            if rangeIsInside(t.range, anyOf: allowedInline) {
                tokens.append(t)
            }
        }

        return tokens
    }

    // MARK: - Helpers used by parseTokens

    /// Content ranges of all blocks that allow inline tokenization.
    private static func inlineContainerRanges(from blocks: [BlockSpan]) -> [NSRange] {
        blocks.compactMap { $0.kind.allowsInlineContent ? $0.contentRange : nil }
    }

    /// True when `range` is fully contained in any one of the allowed ranges.
    private static func rangeIsInside(_ range: NSRange, anyOf allowed: [NSRange]) -> Bool {
        if allowed.isEmpty { return false }
        let end = NSMaxRange(range)
        for a in allowed {
            if range.location >= a.location && end <= NSMaxRange(a) {
                return true
            }
        }
        return false
    }

    private static func isInsideFencedCode(range: NSRange, blocks: [BlockSpan]) -> Bool {
        for b in blocks {
            if case .fencedCode = b.kind, NSIntersectionRange(b.range, range).length > 0 {
                return true
            }
        }
        return false
    }

    private static func isInsideBlockLatexInline(range: NSRange, inlineTokens: [MarkdownToken]) -> Bool {
        for t in inlineTokens where t.kind == .blockLatex {
            if NSIntersectionRange(t.range, range).length > 0 { return true }
        }
        return false
    }

    /// Trim a single trailing CR, LF, or CRLF from `range` (relative to `nsText`).
    private static func trimTrailingNewline(_ range: NSRange, in nsText: NSString) -> NSRange {
        var length = range.length
        let end = range.location + length
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

    // MARK: - Code Block Helpers

    static func extractLanguage(from token: MarkdownToken, in text: String) -> String? {
        guard token.kind == .codeBlock,
              let openingMarker = token.markerRanges.first,
              openingMarker.length > 4 else { return nil }
        
        let nsText = text as NSString
        let langRange = NSRange(location: openingMarker.location + 3, length: openingMarker.length - 4)
        
        guard langRange.location + langRange.length <= nsText.length else { return nil }
        
        let langString = nsText.substring(with: langRange).trimmingCharacters(in: .whitespacesAndNewlines)
        return langString.isEmpty ? nil : langString
    }

    // MARK: - Inline LaTeX Heuristics

    private static func isInlineMathContent(_ content: String) -> Bool {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        
        let currencyPattern = #"^[+-]?(\d{1,3}(?:,\d{3})*|\d+)(?:\.\d+)?$"#
        if trimmed.range(of: currencyPattern, options: .regularExpression) != nil {
            return false
        }
        
        let mathyPattern = #"[\\\^\_\{\}=+\-*/<>]"#
        let mathyRegex = try? NSRegularExpression(pattern: mathyPattern, options: [])
        let mathyMatches = mathyRegex?.numberOfMatches(in: trimmed, options: [], range: NSRange(location: 0, length: trimmed.utf16.count)) ?? 0
        if mathyMatches == 0 {
            if trimmed.count <= 3 {
                let isSimpleSingleLetter = trimmed.range(of: #"^[A-Za-z]{1,3}$"#, options: .regularExpression) != nil
                if isSimpleSingleLetter { return true }
            }
            return false
        }
        
        let tokens = trimmed.split(whereSeparator: { $0.isWhitespace })
        if mathyMatches >= 3 {
            if tokens.count > 120 { return false }
        } else if mathyMatches == 2 {
            if tokens.count > 40 { return false }
        } else {
            if tokens.count > 6 { return false }
        }
        
        return true
    }
}
