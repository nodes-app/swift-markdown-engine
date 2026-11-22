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
        in text: NSString,
        suppressed: Bool = false
    ) -> Set<Int> {
        // Read-only mode (no caret) hides all tokens regardless of any trailing selection.
        if suppressed { return [] }
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

        // When a container token (e.g. a table) is active, every inline token inside it becomes active too.
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

    /// Slow: parses tokens each call. Pass the editor's registry so the parse
    /// matches the styled document's grammar (an extension span can pre-claim
    /// text a built-in would otherwise recognize).
    static func isInsideCodeBlock(range: NSRange, in text: String, registry: ExtensionRegistry = .empty) -> Bool {
        let codeTokens = MarkdownTokenizer.parseTokensViaAST(in: text, registry: registry).filter { $0.kind == .codeBlock || $0.kind == .inlineCode }
        return isInsideCodeBlock(range: range, codeTokens: codeTokens)
    }

    static func isInsideCodeBlock(location: Int, in text: String, registry: ExtensionRegistry = .empty) -> Bool {
        isInsideCodeBlock(range: NSRange(location: location, length: 0), in: text, registry: registry)
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

    /// Count of non-overlapping ``` occurrences, scanning left to right —
    /// exactly `components(separatedBy: "```").count - 1`, but as one UTF-16
    /// pass with no substring-array allocation.
    static func tripleBacktickCount(in text: NSString) -> Int {
        let length = text.length
        guard length >= 3 else { return 0 }
        var buffer = [unichar](repeating: 0, count: length)
        text.getCharacters(&buffer, range: NSRange(location: 0, length: length))
        var count = 0
        var i = 0
        while i + 2 < length {                           // i can reach length - 3
            if buffer[i] == 0x60, buffer[i + 1] == 0x60, buffer[i + 2] == 0x60 {
                count += 1
                i += 3
            } else {
                i += 1
            }
        }
        return count
    }

    /// The ``` count contributed by the backtick runs that intersect `range`.
    /// The window expands through adjacent backticks on both sides, so every
    /// run inside it is a MAXIMAL run of the whole text — and the greedy global
    /// count is exactly Σ floor(runLen/3) over maximal runs, which makes these
    /// window counts composable: full = fullBefore − windowBefore + windowAfter.
    static func backtickWindowCount(in text: NSString, around range: NSRange) -> Int {
        let length = text.length
        guard range.location >= 0, NSMaxRange(range) <= length else { return 0 }
        var lo = range.location
        while lo > 0, text.character(at: lo - 1) == 0x60 { lo -= 1 }
        var hi = NSMaxRange(range)
        while hi < length, text.character(at: hi) == 0x60 { hi += 1 }
        var count = 0
        var run = 0
        var i = lo
        while i < hi {
            if text.character(at: i) == 0x60 {
                run += 1
            } else {
                count += run / 3
                run = 0
            }
            i += 1
        }
        return count + run / 3
    }

    // MARK: - LaTeX Detection

    /// Slow: parses tokens each call. The registry matters here: a registered
    /// extension (e.g. `==$==$`) can claim characters that would otherwise
    /// pair into a phantom `$…$`, so parsing with `.empty` diverges from the
    /// styled document.
    static func isInsideLatex(location: Int, in text: String, registry: ExtensionRegistry = .empty) -> Bool {
        let tokens = MarkdownTokenizer.parseTokensViaAST(in: text, registry: registry)
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

}
