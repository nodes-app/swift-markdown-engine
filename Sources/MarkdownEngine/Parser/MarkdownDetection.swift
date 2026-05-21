//
//  MarkdownDetection.swift
//  MarkdownEngine
//
//  Created by Luca Chen on 18.02.26.
//

// Helper checks for questions like "is the cursor inside code or LaTeX?"
// and "which Markdown part is currently active?".
import Foundation

enum MarkdownDetection {

    // MARK: - Active Token Indices

    static func computeActiveTokenIndices(
        selectionRange: NSRange,
        tokens: [MarkdownToken],
        in text: NSString
    ) -> Set<Int> {
        var indices: Set<Int> = []
        let caretLocation = selectionRange.location
        for (index, token) in tokens.enumerated() {
            let start = token.range.location
            let end = NSMaxRange(token.range)
            if selectionRange.length > 0 && (token.kind == .inlineLatex || token.kind == .blockLatex) && NSIntersectionRange(selectionRange, token.range).length > 0 {
                indices.insert(index)
                continue
            }
            if caretLocation >= start && caretLocation < end {
                indices.insert(index)
                continue
            }
            if caretLocation == end {
                let lastIndex = end - 1
                if lastIndex >= start && lastIndex < text.length {
                    let lastChar = text.substring(with: NSRange(location: lastIndex, length: 1))
                    if lastChar != "\n" {
                        indices.insert(index)
                    }
                }
            }
        }

        // When a "container" token like a table is active (caret inside),
        // every inline token fully contained within it should also be
        // active. Otherwise inline-latex/inline-code/emphasis/etc. inside
        // the table still try to render their decorated form (LaTeX
        // images, hidden backticks, …) on top of the visible source the
        // table editor mode is showing.
        let activeContainers: [MarkdownToken] = indices.compactMap { idx in
            let token = tokens[idx]
            return token.kind == .table ? token : nil
        }
        if !activeContainers.isEmpty {
            for (i, token) in tokens.enumerated() where !indices.contains(i) {
                let tStart = token.range.location
                let tEnd = NSMaxRange(token.range)
                if activeContainers.contains(where: {
                    tStart >= $0.range.location && tEnd <= NSMaxRange($0.range)
                }) {
                    indices.insert(i)
                }
            }
        }
        return indices
    }

    // MARK: - Code Block Detection

    /// Slow: parses tokens each call
    static func isInsideCodeBlock(range: NSRange, in text: String) -> Bool {
        let codeTokens = MarkdownTokenizer.parseTokens(in: text).filter { $0.kind == .codeBlock || $0.kind == .inlineCode }
        return isInsideCodeBlock(range: range, codeTokens: codeTokens)
    }

    static func isInsideCodeBlock(location: Int, in text: String) -> Bool {
        isInsideCodeBlock(range: NSRange(location: location, length: 0), in: text)
    }

    /// Fast: uses pre-parsed tokens
    static func isInsideCodeBlock(range: NSRange, codeTokens: [MarkdownToken]) -> Bool {
        guard !codeTokens.isEmpty else { return false }
        for token in codeTokens {
            let start = token.range.location
            let end = start + token.range.length
            if range.length == 0 {
                if range.location >= start && range.location <= end { return true }
            } else {
                if range.location < end && range.location + range.length > start { return true }
            }
        }
        return false
    }

    static func isInsideCodeBlock(location: Int, codeTokens: [MarkdownToken]) -> Bool {
        isInsideCodeBlock(range: NSRange(location: location, length: 0), codeTokens: codeTokens)
    }

    // MARK: - LaTeX Detection

    static func isInsideLatex(location: Int, in text: String) -> Bool {
        let tokens = MarkdownTokenizer.parseTokens(in: text)
        let latexTokens = tokens.filter { $0.kind == .inlineLatex || $0.kind == .blockLatex }
        return isInsideLatex(location: location, latexTokens: latexTokens)
    }

    static func isInsideLatex(location: Int, latexTokens: [MarkdownToken]) -> Bool {
        guard !latexTokens.isEmpty else { return false }
        for token in latexTokens {
            let start = token.range.location
            let end = start + token.range.length
            if location >= start && location <= end { return true }
        }
        return false
    }

    static func isInsideInlineLatex(range: NSRange, in text: String) -> Bool {
        let latexTokens = MarkdownTokenizer.parseTokens(in: text).filter { $0.kind == .inlineLatex }
        return isInsideInlineLatex(range: range, latexTokens: latexTokens)
    }

    static func isInsideInlineLatex(location: Int, in text: String) -> Bool {
        isInsideInlineLatex(range: NSRange(location: location, length: 0), in: text)
    }

    static func isInsideInlineLatex(range: NSRange, latexTokens: [MarkdownToken]) -> Bool {
        guard !latexTokens.isEmpty else { return false }
        for token in latexTokens {
            let start = token.range.location
            let end = start + token.range.length
            if range.length == 0 {
                if range.location >= start && range.location <= end { return true }
            } else {
                if range.location < end && range.location + range.length > start { return true }
            }
        }
        return false
    }

    static func isInsideInlineLatex(location: Int, latexTokens: [MarkdownToken]) -> Bool {
        isInsideInlineLatex(range: NSRange(location: location, length: 0), latexTokens: latexTokens)
    }
}
