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
    static let boldItalicRegex = try! NSRegularExpression(
        pattern: "(?<!\\*)\\*\\*\\*([^*\\r\\n]+?)(?<!\\*)\\*\\*\\*(?!\\*)"
    )
    static let boldRegex = try! NSRegularExpression(
        pattern: "(?<!\\*)\\*\\*([^*\\r\\n]+?)(?<!\\*)\\*\\*(?!\\*)"
    )
    static let italicRegex = try! NSRegularExpression(
        pattern: "(?<!\\*)\\*([^*\\r\\n]+?)(?<!\\*)\\*(?!\\*)"
    )
    // Underscore-style emphasis: GFM disables intraword emphasis for `_`,
    // so we require a non-word boundary on each side to avoid matching
    // identifiers like `snake_case`.
    static let boldItalicUnderscoreRegex = try! NSRegularExpression(
        pattern: #"(?<![A-Za-z0-9_])___([^_\r\n]+?)___(?![A-Za-z0-9_])"#
    )
    static let boldUnderscoreRegex = try! NSRegularExpression(
        pattern: #"(?<![A-Za-z0-9_])__([^_\r\n]+?)__(?![A-Za-z0-9_])"#
    )
    static let italicUnderscoreRegex = try! NSRegularExpression(
        pattern: #"(?<![A-Za-z0-9_])_([^_\r\n]+?)_(?![A-Za-z0-9_])"#
    )
    static let strikethroughRegex = try! NSRegularExpression(
        pattern: "(?<!~)~~([^~\\r\\n]+?)(?<!~)~~(?!~)"
    )
    static let imageEmbedRegex = try! NSRegularExpression(
        pattern: "!\\[\\[([^\\]\\r\\n]*)\\]\\]"
    )
    static let imageLinkRegex = try! NSRegularExpression(
        pattern: "!\\[([^\\]\\r\\n]*)\\]\\(([^\\)\\r\\n]+)\\)"
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
    // CommonMark code span: an opening run of N backticks (not part of a
    // longer run) closed by a run of exactly N backticks. The content may
    // itself contain shorter/longer backtick runs (e.g. `` `tick` ``).
    static let inlineCodeRegex = try! NSRegularExpression(
        pattern: #"(?<!`)(`+)(?!`)([^\n]+?)(?<!`)\1(?!`)"#,
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
    static let tableRegex = try! NSRegularExpression(
        pattern: #"^[ \t]*\|.+\|[ \t]*\r?\n[ \t]*\|[- \t:|]+\|[ \t]*(?:\r?\n[ \t]*\|.+\|[ \t]*)*"#,
        options: [.anchorsMatchLines]
    )
}

// MARK: - Tokenizer
enum MarkdownTokenizer {

    static func parseTokens(in text: String) -> [MarkdownToken] {
        var tokens: [MarkdownToken] = []
        let nsText = text as NSString
        let fullRange = NSRange(location: 0, length: nsText.length)

        // Bold+Italic ***text***
        for match in boldItalicRegex.matches(in: text, options: [], range: fullRange) {
            let full = match.range
            let content = match.range(at: 1)
            let startMarker = NSRange(location: full.location, length: 3)
            let endMarker = NSRange(location: full.location + full.length - 3, length: 3)
            tokens.append(MarkdownToken(kind: .boldItalic,
                                        range: full,
                                        contentRange: content,
                                        markerRanges: [startMarker, endMarker]))
        }

        // Bold **text**
        for match in boldRegex.matches(in: text, options: [], range: fullRange) {
            let full = match.range
            let content = match.range(at: 1)
            let startMarker = NSRange(location: full.location, length: 2)
            let endMarker = NSRange(location: full.location + full.length - 2, length: 2)
            tokens.append(MarkdownToken(kind: .bold,
                                        range: full,
                                        contentRange: content,
                                        markerRanges: [startMarker, endMarker]))
        }

        // Italic *text*
        for match in italicRegex.matches(in: text, options: [], range: fullRange) {
            let full = match.range
            let content = match.range(at: 1)
            let startMarker = NSRange(location: full.location, length: 1)
            let endMarker = NSRange(location: full.location + full.length - 1, length: 1)
            tokens.append(MarkdownToken(kind: .italic,
                                        range: full,
                                        contentRange: content,
                                        markerRanges: [startMarker, endMarker]))
        }

        // Bold+Italic ___text___
        for match in boldItalicUnderscoreRegex.matches(in: text, options: [], range: fullRange) {
            let full = match.range
            let content = match.range(at: 1)
            let startMarker = NSRange(location: full.location, length: 3)
            let endMarker = NSRange(location: full.location + full.length - 3, length: 3)
            tokens.append(MarkdownToken(kind: .boldItalic,
                                        range: full,
                                        contentRange: content,
                                        markerRanges: [startMarker, endMarker]))
        }

        // Bold __text__
        for match in boldUnderscoreRegex.matches(in: text, options: [], range: fullRange) {
            let full = match.range
            let content = match.range(at: 1)
            let startMarker = NSRange(location: full.location, length: 2)
            let endMarker = NSRange(location: full.location + full.length - 2, length: 2)
            tokens.append(MarkdownToken(kind: .bold,
                                        range: full,
                                        contentRange: content,
                                        markerRanges: [startMarker, endMarker]))
        }

        // Italic _text_
        for match in italicUnderscoreRegex.matches(in: text, options: [], range: fullRange) {
            let full = match.range
            let content = match.range(at: 1)
            let startMarker = NSRange(location: full.location, length: 1)
            let endMarker = NSRange(location: full.location + full.length - 1, length: 1)
            tokens.append(MarkdownToken(kind: .italic,
                                        range: full,
                                        contentRange: content,
                                        markerRanges: [startMarker, endMarker]))
        }

        // Strikethrough ~~text~~ (GFM)
        for match in strikethroughRegex.matches(in: text, options: [], range: fullRange) {
            let full = match.range
            let content = match.range(at: 1)
            let startMarker = NSRange(location: full.location, length: 2)
            let endMarker = NSRange(location: full.location + full.length - 2, length: 2)
            tokens.append(MarkdownToken(kind: .strikethrough,
                                        range: full,
                                        contentRange: content,
                                        markerRanges: [startMarker, endMarker]))
        }

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

        // Image links ![alt](URL) — standard Markdown image syntax. Must be
        // parsed before markdownLinkRegex; otherwise the trailing
        // `[alt](URL)` sub-string would be claimed as a plain link, leaving
        // the leading `!` orphaned and the embedder no chance to render an
        // image.
        var imageLinkRanges: [NSRange] = []
        for match in imageLinkRegex.matches(in: text, options: [], range: fullRange) {
            let full = match.range(at: 0)
            let altRange = match.range(at: 1)
            let urlRange = match.range(at: 2)
            let bangBracket = NSRange(location: full.location, length: 2) // ![
            let closeBracket = NSRange(location: altRange.location + altRange.length, length: 1) // ]
            let openParen = NSRange(location: urlRange.location - 1, length: 1) // (
            let closeParen = NSRange(location: urlRange.location + urlRange.length, length: 1) // )
            tokens.append(MarkdownToken(kind: .imageLink,
                                        range: full,
                                        contentRange: altRange,
                                        markerRanges: [bangBracket, closeBracket, openParen, closeParen]))
            imageLinkRanges.append(full)
        }

        // Markdown links [Text](URL)
        for match in markdownLinkRegex.matches(in: text, options: [], range: fullRange) {
            let full = match.range
            // Skip ranges that overlap with imageLink — the bang prefix is
            // recognized one token earlier and we don't want to double-style
            // the bracket region.
            if imageLinkRanges.contains(where: { NSIntersectionRange($0, full).length > 0 }) { continue }
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
        
        // GFM tables. Parsed after code blocks so we can skip table-shaped
        // lines inside fenced code; sits before block-latex/inline-latex
        // because we don't want `$$...$$` rules trying to claim ranges that
        // belong to a table cell.
        for match in tableRegex.matches(in: text, options: [], range: fullRange) {
            let full = match.range(at: 0)
            let inCode = tokens.contains { $0.kind == .codeBlock && NSIntersectionRange($0.range, full).length > 0 }
            if inCode { continue }
            tokens.append(MarkdownToken(kind: .table,
                                        range: full,
                                        contentRange: full,
                                        markerRanges: []))
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

        // Inline code `code` / `` `tick` `` (N-backtick runs)
        for match in inlineCodeRegex.matches(in: text, options: [], range: fullRange) {
            let full = match.range(at: 0)
            let delimLength = match.range(at: 1).length          // run of N backticks
            let rawContent = match.range(at: 2)

            // CommonMark: if the content both begins and ends with a space
            // but isn't all spaces, strip exactly one space from each side.
            let rawString = (text as NSString).substring(with: rawContent)
            let stripsSpaces = rawString.count >= 2
                && rawString.first == " "
                && rawString.last == " "
                && rawString.contains(where: { $0 != " " })
            let lead = stripsSpaces ? 1 : 0
            let trail = stripsSpaces ? 1 : 0

            let content = NSRange(
                location: rawContent.location + lead,
                length: rawContent.length - lead - trail
            )
            // The markers swallow the delimiter runs AND any stripped space,
            // so they collapse together when the syntax is hidden.
            let openMarker = NSRange(location: full.location, length: delimLength + lead)
            let closeMarker = NSRange(
                location: full.location + full.length - delimLength - trail,
                length: delimLength + trail
            )
            tokens.append(MarkdownToken(kind: .inlineCode,
                                        range: full,
                                        contentRange: content,
                                        markerRanges: [openMarker, closeMarker]))
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

        // MARK: Backslash escapes (CommonMark §2.4)
        //
        // A backslash before any ASCII punctuation character makes that
        // character literal — it loses its Markdown meaning. We scan left
        // to right so that `\\` consumes itself (the even/odd-backslash
        // rule): the char after an escaping backslash can never itself
        // start a new escape. Escapes do not apply inside fenced code or
        // block LaTeX, where a backslash is already literal.
        let asciiPunctuation: Set<unichar> = {
            let chars = "!\"#$%&'()*+,-./:;<=>?@[\\]^_`{|}~"
            return Set(chars.utf16)
        }()
        let escapeFreeRanges: [NSRange] = tokens
            .filter { $0.kind == .codeBlock || $0.kind == .blockLatex }
            .map { $0.range }
        func isEscapeFree(_ loc: Int) -> Bool {
            for r in escapeFreeRanges where loc >= r.location && loc < NSMaxRange(r) {
                return true
            }
            return false
        }

        var escapedCharOffsets: Set<Int> = []
        var escapeTokens: [MarkdownToken] = []
        var i = 0
        let textLength = nsText.length
        while i < textLength - 1 {
            if nsText.character(at: i) == 0x5C /* backslash */, !isEscapeFree(i) {
                let next = nsText.character(at: i + 1)
                if asciiPunctuation.contains(next) {
                    escapedCharOffsets.insert(i + 1)
                    escapeTokens.append(MarkdownToken(
                        kind: .backslashEscape,
                        range: NSRange(location: i, length: 2),
                        contentRange: NSRange(location: i + 1, length: 1),
                        markerRanges: [NSRange(location: i, length: 1)]
                    ))
                    i += 2   // the escaped char cannot start another escape
                    continue
                }
            }
            i += 1
        }

        if !escapedCharOffsets.isEmpty {
            // An inline span whose opening or closing delimiter sits on an
            // escaped (now-literal) character is not a real span — drop it
            // so `\*not italic\*` / `` \` not code \` `` stay literal.
            let escapableKinds: Set<MarkdownTokenKind> = [
                .italic, .bold, .boldItalic, .strikethrough,
                .inlineCode, .inlineLatex, .blockLatex,
                .link, .wikiLink, .imageLink, .imageEmbed
            ]
            tokens.removeAll { token in
                guard escapableKinds.contains(token.kind) else { return false }
                return token.markerRanges.contains { escapedCharOffsets.contains($0.location) }
            }
        }
        tokens.append(contentsOf: escapeTokens)

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
