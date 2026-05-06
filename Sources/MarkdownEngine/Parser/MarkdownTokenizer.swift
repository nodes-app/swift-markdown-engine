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

        // Emphasis via stack parser.
        tokens.append(contentsOf: parseEmphasisTokens(in: text))

        // Image embeds ![[Name]] (must be parsed before wikiLinks)
        var imageEmbedRanges: [NSRange] = []
        for match in imageEmbedRegex.matches(in: text, options: [], range: fullRange) {
            let full = match.range(at: 0)
            let content = match.range(at: 1)
            let openMarker = NSRange(location: full.location, length: 3) // ![[
            let closeMarker = NSRange(location: full.location + full.length - 2, length: 2) // ]]
            tokens.append(MarkdownToken(kind: .imageEmbed,
                                        range: full,
                                        contentRange: content,
                                        markerRanges: [openMarker, closeMarker]))
            imageEmbedRanges.append(full)
        }

        // Node links [[Name]]
        for match in wikiLinkRegex.matches(in: text, options: [], range: fullRange) {
            let full = match.range(at: 0)
            // Skip ranges already claimed by imageEmbed tokens
            let overlapsImage = imageEmbedRanges.contains { NSIntersectionRange($0, full).length > 0 }
            if overlapsImage { continue }
            let content = match.range(at: 1)
            let open = NSRange(location: full.location, length: 2)
            let close = NSRange(location: full.location + full.length - 2, length: 2)
            tokens.append(MarkdownToken(kind: .wikiLink,
                                        range: full,
                                        contentRange: content,
                                        markerRanges: [open, close]))
        }

        // Markdown links [Text](URL)
        for match in markdownLinkRegex.matches(in: text, options: [], range: fullRange) {
            let full = match.range
            let textRange = match.range(at: 1)
            let urlRange = match.range(at: 2)
            let openBracket = NSRange(location: full.location, length: 1)
            let closeBracket = NSRange(location: textRange.location + textRange.length, length: 1)
            let openParen = NSRange(location: urlRange.location - 1, length: 1)
            let closeParen = NSRange(location: urlRange.location + urlRange.length, length: 1)
            tokens.append(MarkdownToken(kind: .link,
                                        range: full,
                                        contentRange: textRange,
                                        markerRanges: [openBracket, closeBracket, openParen, closeParen]))
        }

        // Headings #... up to ######
        for match in headingRegex.matches(in: text, options: [], range: fullRange) {
            let fullMatchRange = match.range(at: 0)
            let hashes = match.range(at: 1)
            let content = match.range(at: 2)
            let leadingWsLength = hashes.location - fullMatchRange.location
            let tokenRange = NSRange(location: hashes.location, length: fullMatchRange.length - leadingWsLength)
            var markerRanges = [hashes]
            let hashEnd = hashes.location + hashes.length
            if hashEnd < nsText.length {
                let spaceRange = NSRange(location: hashEnd, length: 1)
                if nsText.substring(with: spaceRange) == " " {
                    markerRanges.append(spaceRange)
                }
            }
            tokens.append(MarkdownToken(kind: .heading,
                                        range: tokenRange,
                                        contentRange: content,
                                        markerRanges: markerRanges))
        }

        // Fenced code blocks ```lang\n...\n```
        for match in codeBlockRegex.matches(in: text, options: [], range: fullRange) {
            let full = match.range(at: 0)
            let contentRange = match.range(at: 2)
            let closingFence = match.range(at: 3)
            let tokenEnd = closingFence.location + closingFence.length
            let tokenRange = NSRange(location: full.location, length: tokenEnd - full.location)
            let openingLength = max(3, min(contentRange.location - tokenRange.location, tokenRange.length))
            let openingMarker = NSRange(location: tokenRange.location, length: openingLength)
            _ = contentRange.location + contentRange.length
            let closingMarker = closingFence
            
            tokens.append(MarkdownToken(kind: .codeBlock,
                                        range: tokenRange,
                                        contentRange: contentRange,
                                        markerRanges: [openingMarker, closingMarker]))
        }
        
        // Block LaTeX $$...$$ (multiline)
        for match in blockLatexRegex.matches(in: text, options: [], range: fullRange) {
            let full = match.range(at: 0)
            let inCode = tokens.contains { $0.kind == .codeBlock && NSIntersectionRange($0.range, full).length > 0 }
            if inCode { continue }
            
            let content = match.range(at: 1)
            let openMarker = NSRange(location: full.location, length: 2)
            let closeMarker = NSRange(location: full.location + full.length - 2, length: 2)
            tokens.append(MarkdownToken(kind: .blockLatex,
                                        range: full,
                                        contentRange: content,
                                        markerRanges: [openMarker, closeMarker]))
        }

        // Inline code `code`
        for match in inlineCodeRegex.matches(in: text, options: [], range: fullRange) {
            let full = match.range(at: 0)
            let content = match.range(at: 1)
            let openBacktick = NSRange(location: full.location, length: 1)
            let closeBacktick = NSRange(location: full.location + full.length - 1, length: 1)
            tokens.append(MarkdownToken(kind: .inlineCode,
                                        range: full,
                                        contentRange: content,
                                        markerRanges: [openBacktick, closeBacktick]))
        }

        // Inline LaTeX $formula$
        for match in inlineLatexRegex.matches(in: text, options: [], range: fullRange) {
            let full = match.range(at: 0)
            let content = match.range(at: 1)
            let isInsideBlock = tokens.contains {
                ($0.kind == .codeBlock || $0.kind == .blockLatex) &&
                NSIntersectionRange($0.range, full).length > 0
            }
            if isInsideBlock { continue }
            let contentString = nsText.substring(with: content)
            if !isInlineMathContent(contentString) { continue }
            let openDollar = NSRange(location: full.location, length: 1)
            let closeDollar = NSRange(location: full.location + full.length - 1, length: 1)
            tokens.append(MarkdownToken(kind: .inlineLatex,
                                        range: full,
                                        contentRange: content,
                                        markerRanges: [openDollar, closeDollar]))
        }

        return tokens
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
