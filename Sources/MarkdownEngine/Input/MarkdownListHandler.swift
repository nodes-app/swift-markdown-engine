//
//  MarkdownListHandler.swift
//  MarkdownEngine
//
//  Created by Luca Chen on 18.02.26.
//

// Makes list editing feel natural by continuing items, handling indentation,
// and applying spacing/alignment that keeps lists easy to read.
import AppKit

struct MarkdownLists {
    static func performEdit(_ textView: NSTextView, replace range: NSRange, with string: String) {
        let ns = textView.string as NSString
        let loc = min(range.location, ns.length)
        let maxLen = ns.length - loc
        let len = min(range.length, max(0, maxLen))
        let safeRange = NSRange(location: loc, length: len)

        if let coord = textView.delegate as? NativeTextViewWrapper.Coordinator { coord.isProgrammaticEdit = true }
        defer {
            if let coord = textView.delegate as? NativeTextViewWrapper.Coordinator { coord.isProgrammaticEdit = false }
        }

        guard textView.shouldChangeText(in: safeRange, replacementString: string) else { return }
        textView.textStorage?.replaceCharacters(in: safeRange, with: string)
        textView.didChangeText()
    }

    static let listRegex = try! NSRegularExpression(
        pattern: #"^\s*((?:(\d+)\.|[-•])(?:\s+\[[ xX]\])?\s+)"#
    )
    /// CommonMark blockquote line: ≤3 spaces of leading indent, then a run
    /// of `>` markers, then an optional single space before content. The
    /// captures are: (1) leading whitespace, (2) the `>`/`>>`… marker run.
    static let blockquoteRegex = try! NSRegularExpression(
        pattern: #"^( {0,3})(>+)[ \t]?"#
    )
    static let dashNoSpaceRegex = try! NSRegularExpression(pattern: #"^\s*-(?!\s)"#)
    static let numberRegex = try! NSRegularExpression(pattern: #"^\s*(\d+)\.$"#)
    static let leadingWhitespaceRegex = try! NSRegularExpression(pattern: #"^\s*"#)

    /// Matches an optionally-indented `- `, `* ` or `+ ` at the start of a
    /// line — the three CommonMark bullet markers, with leading spaces
    /// and/or tabs (nested items). Used by `normalizeBulletMarkers` to
    /// convert pasted/loaded bullets into the engine's canonical
    /// `<depth tabs>• ` form.
    static let pasteableDashBulletRegex = try! NSRegularExpression(
        pattern: #"^([ \t]*)[-+*] "#,
        options: [.anchorsMatchLines]
    )

    static func indentLevel(from leadingWhitespace: String) -> Int {
        let tabCount = leadingWhitespace.filter { $0 == "\t" }.count
        let spaceCount = leadingWhitespace.filter { $0 == " " }.count
        return tabCount + (spaceCount / 2)
    }

    /// Remove the leading prefix on the current line (list marker, quote
    /// marker, …) and place the caret at the line start. Used by Enter
    /// handling when the marker has no content, so the user exits the block
    /// without having to backspace through the prefix.
    private static func removeLinePrefixAndExit(
        textView: NSTextView,
        currentLineRange: NSRange,
        prefixLength: Int
    ) -> Bool {
        let lineEnd = currentLineRange.location + currentLineRange.length
        let hasNewline = currentLineRange.length > 0
            && (textView.string as NSString)
                .substring(with: NSRange(location: lineEnd - 1, length: 1)) == "\n"
        let maxBodyLen = hasNewline ? currentLineRange.length - 1 : currentLineRange.length
        let removalLength = min(prefixLength, maxBodyLen)
        let removalRange = NSRange(location: currentLineRange.location, length: removalLength)
        performEdit(textView, replace: removalRange, with: "")
        textView.setSelectedRange(NSRange(location: currentLineRange.location, length: 0))
        return false
    }

    // MARK: - Storage Normalization

    /// Rewrite standard-Markdown bullets (`- foo`, `* foo`, `+ foo`) to the
    /// engine's canonical bullet form (`\t• foo`) so pasted or
    /// programmatically loaded markdown renders with the same hanging indent
    /// and bullet glyph as bullets the user types directly. The typed-input
    /// path already rewrites `-` → `\t• ` on space-after-dash; this closes
    /// the gap for every other ingestion path. Code blocks are left
    /// untouched.
    static func normalizeBulletMarkers(_ text: String) -> String {
        guard !text.isEmpty else { return text }
        let nsText = text as NSString
        let fullRange = NSRange(location: 0, length: nsText.length)
        let matches = pasteableDashBulletRegex.matches(in: text, options: [], range: fullRange)
        guard !matches.isEmpty else { return text }
        // Parse code-block tokens once so per-match code-block lookups stay O(tokens),
        // not O(parse) — pasting a huge document with many dash lines would
        // otherwise tokenize once per match.
        let codeTokens = text.contains("`")
            ? MarkdownTokenizer.parseTokens(in: text).filter { $0.kind == .codeBlock || $0.kind == .inlineCode }
            : []
        let mutable = NSMutableString(string: text)
        // Walk in reverse so untouched offsets stay valid as we mutate.
        for match in matches.reversed() {
            let lineStart = match.range.location
            if !codeTokens.isEmpty,
               MarkdownDetection.isInsideCodeBlock(location: lineStart, codeTokens: codeTokens) {
                continue
            }
            // Map the source indent (spaces and/or tabs) to a nesting
            // depth and rewrite the whole `<ws><marker> ` prefix to the
            // canonical `<depth+1 tabs>• `. depth+1 keeps the existing
            // "top level = one tab" convention paragraphAttributes expects.
            let ws = nsText.substring(with: match.range(at: 1))
            let depth = indentLevel(from: ws)
            let canonical = String(repeating: "\t", count: depth + 1) + "• "
            mutable.replaceCharacters(in: match.range, with: canonical)
        }
        return mutable as String
    }

    // MARK: - Paragraph Attributes for List Styling

    static func paragraphAttributes(
        for text: String,
        baseFont: NSFont,
        nsText: NSString,
        fullRange: NSRange,
        listsEnabled: Bool,
        defaultLineHeight: CGFloat,
        defaultParagraphSpacing: CGFloat,
        configuration: MarkdownEditorConfiguration = .default
    ) -> [(range: NSRange, attributes: [NSAttributedString.Key: Any])] {
        var attributesList: [(range: NSRange, attributes: [NSAttributedString.Key: Any])] = []
        guard listsEnabled else { return attributesList }

        let indentPerLevel = configuration.lists.indentPerLevel
        let extraLineHeight = configuration.lists.extraLineHeight
        let spaceWidth = (" " as NSString).size(withAttributes: [.font: baseFont]).width

        func applyListMatches(_ matches: [NSTextCheckingResult]) {
            for match in matches {
                let ps = NSMutableParagraphStyle()
                ps.minimumLineHeight = defaultLineHeight + extraLineHeight
                ps.maximumLineHeight = defaultLineHeight + extraLineHeight
                ps.lineSpacing = 0
                ps.paragraphSpacing = defaultParagraphSpacing
                ps.paragraphSpacingBefore = 0
                let wsRange = match.range(at: 1)
                let markerRange = match.range(at: 2)
                let ws = nsText.substring(with: wsRange)
                let tabCount = ws.filter { $0 == "\t" }.count
                let spaceCount = ws.filter { $0 == " " }.count
                let depthIndent = CGFloat(tabCount) * indentPerLevel + CGFloat(spaceCount) * spaceWidth

                let markerString = nsText.substring(with: markerRange) as NSString
                let markerWidth = markerString.size(withAttributes: [.font: baseFont]).width
                let hasCheckbox = markerString.range(of: "[").location != NSNotFound
                let isChecked = markerString.range(of: "[x]", options: [.caseInsensitive]).location != NSNotFound
                let extraSpacing = (hasCheckbox && !isChecked)
                    ? HeadingHelpers.checkboxExtraSpacing(font: baseFont, configuration: configuration.checkbox)
                    : 0

                ps.tabStops = []
                ps.defaultTabInterval = indentPerLevel
                ps.firstLineHeadIndent = 0
                ps.headIndent = depthIndent + markerWidth + extraSpacing

                attributesList.append((match.range(at: 0), [.paragraphStyle: ps]))
            }
        }

        // Ordered lists
        let orderedListPattern = #"^([ \t]*)(\d+\.(?:[ \t]+\[[ xX]\])?[ \t]+)(.*)$"#
        if let orderedListRegex = try? NSRegularExpression(pattern: orderedListPattern, options: [.anchorsMatchLines]) {
            applyListMatches(orderedListRegex.matches(in: text, options: [], range: fullRange))
        }

        // Bullet lists
        let bulletListPattern = #"^([ \t]*)([-•](?:[ \t]+\[[ xX]\])?[ \t]+)(.*)$"#
        if let bulletListRegex = try? NSRegularExpression(pattern: bulletListPattern, options: [.anchorsMatchLines]) {
            let bulletMatches = bulletListRegex.matches(in: text, options: [], range: fullRange)
            applyListMatches(bulletMatches)
        }
        return attributesList
    }

    // MARK: - Input Handling

    static func handleInsertion(textView: NSTextView, affectedCharRange: NSRange, replacementString: String?) -> Bool {
        guard let replacementString = replacementString else { return true }

        // Fast path: skip the expensive isInsideCodeBlock scan for ordinary typing.
        if replacementString.count == 1,
           let ch = replacementString.first,
           ch != ">" && ch != "[" && ch != "(" && ch != "{" &&
           ch != "\t" && ch != " " && ch != "\n" {
            return true
        }

        let activeConfig = (textView as? NativeTextView)?.configuration ?? .default
        let listsEnabled = activeConfig.lists.helpersEnabled
        let autoClosePairsEnabled = activeConfig.lists.autoClosePairsEnabled

        func insertAutoPair(open openChar: String, close closeChar: String) -> Bool {
            let insertionLocation = affectedCharRange.location
            MarkdownLists.performEdit(textView, replace: affectedCharRange, with: "\(openChar)\(closeChar)")
            textView.setSelectedRange(NSRange(location: insertionLocation + openChar.count, length: 0))
            return false
        }

        let isInCodeBlock = textView.string.contains("`")
            ? MarkdownDetection.isInsideCodeBlock(location: affectedCharRange.location, in: textView.string)
            : false

        // BACKSPACE on an empty bullet prefix line ("\t+• " with no other
        // content): undo the auto-conversion that turned a typed `-` + space
        // into `\t• `. We collapse the whole prefix back to `-` so the user
        // can keep deleting cleanly instead of stalling on the bullet glyph.
        if listsEnabled,
           replacementString.isEmpty,
           affectedCharRange.length == 1,
           !isInCodeBlock {
            let nsText = textView.string as NSString
            let safeLoc = min(affectedCharRange.location, nsText.length)
            let lineRange = nsText.lineRange(for: NSRange(location: safeLoc, length: 0))
            // Strip trailing newline so the regex anchors against true end-of-line.
            var contentLength = lineRange.length
            if contentLength > 0,
               nsText.character(at: lineRange.location + contentLength - 1) == 0x000A {
                contentLength -= 1
            }
            if contentLength > 0 {
                let lineContentRange = NSRange(location: lineRange.location, length: contentLength)
                let lineContent = nsText.substring(with: lineContentRange)
                if lineContent.range(of: #"^\t+• $"#, options: .regularExpression) != nil,
                   affectedCharRange.location >= lineRange.location,
                   affectedCharRange.location < lineRange.location + contentLength {
                    MarkdownLists.performEdit(textView, replace: lineContentRange, with: "-")
                    textView.setSelectedRange(NSRange(location: lineRange.location + 1, length: 0))
                    return false
                }
            }
        }

        if replacementString == ">" && affectedCharRange.length == 0 && !isInCodeBlock {
            let insertionLocation = affectedCharRange.location
            guard insertionLocation > 0 else { return true }
            let nsText = textView.string as NSString
            let previousCharRange = NSRange(location: insertionLocation - 1, length: 1)
            let previousChar = nsText.substring(with: previousCharRange)
            if previousChar == "-" {
                MarkdownLists.performEdit(textView, replace: previousCharRange, with: "→")
                textView.setSelectedRange(NSRange(location: insertionLocation, length: 0))
                return false
            }
        }

        // Autocomplete Obsidian-style node brackets and single square brackets
        if replacementString == "[" {
            let nsText = textView.string as NSString
            let insertionLocation = affectedCharRange.location
            if insertionLocation > 0 {
                let prevChar = nsText.substring(with: NSRange(location: insertionLocation - 1, length: 1))
                if prevChar == "[" {
                    let hasAutoCloseBracket = insertionLocation < nsText.length
                        && nsText.substring(with: NSRange(location: insertionLocation, length: 1)) == "]"
                    if hasAutoCloseBracket {
                        // Collapse auto-paired "[]" into "[[]]" without changing surrounding text.
                        MarkdownLists.performEdit(
                            textView,
                            replace: NSRange(location: insertionLocation - 1, length: 2),
                            with: "[[]]"
                        )
                    } else {
                        // If the char to the right is not "]" (e.g. newline), do not delete it.
                        MarkdownLists.performEdit(textView, replace: affectedCharRange, with: "[]]")
                    }
                    textView.setSelectedRange(NSRange(location: insertionLocation + 1, length: 0))
                    return false
                }
            }
            guard autoClosePairsEnabled else { return true }
            return insertAutoPair(open: "[", close: "]")
        }

        // Autocomplete parentheses / braces
        if replacementString == "(" || replacementString == "{" {
            guard autoClosePairsEnabled else { return true }
            let closeChar = (replacementString == "(") ? ")" : "}"
            return insertAutoPair(open: replacementString, close: closeChar)
        }

        // TAB: indent list items (skip in code blocks)
        if replacementString == "\t" && !isInCodeBlock {
            guard listsEnabled else { return true }
            let nsText = textView.string as NSString
            let insertionLocation = affectedCharRange.location
            let safeLocTAB = min(affectedCharRange.location, nsText.length)
            let currentLineRange = nsText.lineRange(for: NSRange(location: safeLocTAB, length: 0))
            let currentLine = nsText.substring(with: currentLineRange)
            if MarkdownLists.listRegex.firstMatch(in: currentLine, range: NSRange(location: 0, length: currentLine.utf16.count)) != nil {
                if let wsMatch = MarkdownLists.leadingWhitespaceRegex.firstMatch(in: currentLine, range: NSRange(location: 0, length: currentLine.utf16.count)) {
                    let ws = (currentLine as NSString).substring(with: wsMatch.range)
                    let level = MarkdownLists.indentLevel(from: ws)
                    if level >= MarkdownEditorConfiguration.default.lists.maximumNestingLevel {
                        return false
                    }
                }
                MarkdownLists.performEdit(textView, replace: NSRange(location: currentLineRange.location, length: 0), with: "\t")
                textView.setSelectedRange(NSRange(location: insertionLocation + 1, length: 0))
                return false
            }
            if MarkdownLists.dashNoSpaceRegex.firstMatch(in: currentLine, range: NSRange(location: 0, length: currentLine.utf16.count)) != nil {
                if let wsMatch = MarkdownLists.leadingWhitespaceRegex.firstMatch(in: currentLine, range: NSRange(location: 0, length: currentLine.utf16.count)) {
                    let ws = (currentLine as NSString).substring(with: wsMatch.range)
                    let level = MarkdownLists.indentLevel(from: ws)
                    if level >= MarkdownEditorConfiguration.default.lists.maximumNestingLevel { return false }
                }
                MarkdownLists.performEdit(textView, replace: NSRange(location: currentLineRange.location, length: 0), with: "\t")
                textView.setSelectedRange(NSRange(location: insertionLocation + 1, length: 0))
                return false
            }
            return true
        }

        // SPACE: convert "-" or "1." to proper markers (skip in code blocks)
        if replacementString == " " && !isInCodeBlock {
            guard listsEnabled else { return true }
            let insertionLocation = affectedCharRange.location
            if insertionLocation > 0 {
                let nsText = textView.string as NSString
                let prevCharRange = NSRange(location: insertionLocation - 1, length: 1)
                let prevChar = nsText.substring(with: prevCharRange)
                let currentLineRange = nsText.lineRange(for: NSRange(location: insertionLocation - 1, length: 0))
                let currentLine = nsText.substring(with: currentLineRange)
                if let match = MarkdownLists.numberRegex.firstMatch(in: currentLine, range: NSRange(location: 0, length: currentLine.utf16.count)) {
                    let numberRange = match.range(at: 1)
                    let numberString = (currentLine as NSString).substring(with: numberRange)
                    let markerRange = NSRange(location: currentLineRange.location + match.range.location, length: match.range.length)
                    MarkdownLists.performEdit(textView, replace: markerRange, with: "\t\(numberString). ")
                    return false
                }
                if prevChar == "-" {
                    let beforePrevIndex = insertionLocation - 2
                    let isAtLineStart: Bool = (beforePrevIndex < 0) || nsText.substring(with: NSRange(location: beforePrevIndex, length: 1)) == "\n"
                    if isAtLineStart {
                        MarkdownLists.performEdit(textView, replace: prevCharRange, with: "\t• ")
                        return false
                    }
                }
            }
        }

        // ENTER: list continuation/outdent
        if replacementString == "\n" {
            let nsText = textView.string as NSString
            let safeLocENTER = min(affectedCharRange.location, nsText.length)
            let currentLineRange = nsText.lineRange(for: NSRange(location: safeLocENTER, length: 0))
            let currentLine = nsText.substring(with: currentLineRange).trimmingCharacters(in: .whitespacesAndNewlines)

            // Note: horizontal-rule rendering is handled entirely in the styler
            // via the `.thematicBreak` attribute and a full-width band in
            // `MarkdownTextLayoutFragment.drawThematicBreaks`. The source text
            // stays as the literal `---` (or however many dashes the user
            // typed) so the file round-trips through any other Markdown tool
            // — no `Obsidian / Typora / Bear / iA Writer` expand source on
            // Enter, and doing so here used to leave 80–120 dashes in the
            // buffer that broke copy-paste, diffs, and inter-editor opening.

            if currentLine.range(of: "^```\\w*$", options: .regularExpression) != nil {
                let textBeforeLine = nsText.substring(to: currentLineRange.location)
                let openingCount = textBeforeLine.components(separatedBy: "```").count - 1
                let afterLineStart = currentLineRange.location + currentLineRange.length
                let hasClosingAfter: Bool = {
                    guard afterLineStart < nsText.length else { return false }
                    return nsText.substring(from: afterLineStart).contains("```")
                }()
                let lineEnd = currentLineRange.location + max(0, currentLineRange.length - 1)
                let cursorAtLineEnd = affectedCharRange.location >= lineEnd

                if openingCount.isMultiple(of: 2) && cursorAtLineEnd && !hasClosingAfter {
                    let insertionLocation = affectedCharRange.location
                    let completion = "\n\n```"
                    MarkdownLists.performEdit(textView, replace: affectedCharRange, with: completion)
                    textView.setSelectedRange(NSRange(location: insertionLocation + 1, length: 0))
                    return false
                }
            }

            // Skip list continuation in code blocks
            guard listsEnabled && !isInCodeBlock else { return true }

            // Blockquote continuation: mirror the bullet-list behaviour.
            // Pressing Enter on `> foo` adds a new `> ` line at the same
            // nesting depth (`>>>` stays `>>>`); pressing Enter on an empty
            // marker line strips the prefix so the user can exit the quote
            // without backspacing through it.
            let quoteLine = nsText.substring(with: currentLineRange)
            if let quoteMatch = MarkdownLists.blockquoteRegex.firstMatch(
                in: quoteLine,
                range: NSRange(location: 0, length: quoteLine.utf16.count)
            ) {
                let ws = (quoteLine as NSString).substring(with: quoteMatch.range(at: 1))
                let markers = (quoteLine as NSString).substring(with: quoteMatch.range(at: 2))
                let prefixLength = quoteMatch.range.length
                let contentStart = quoteMatch.range.location + prefixLength
                let contentLength = quoteLine.utf16.count - contentStart
                let contentText = (quoteLine as NSString)
                    .substring(with: NSRange(location: contentStart, length: contentLength))
                    .trimmingCharacters(in: .whitespacesAndNewlines)

                if contentText.isEmpty {
                    return removeLinePrefixAndExit(
                        textView: textView,
                        currentLineRange: currentLineRange,
                        prefixLength: prefixLength
                    )
                }
                MarkdownLists.performEdit(textView, replace: affectedCharRange, with: "\n" + ws + markers + " ")
                return false
            }

            let listLine = nsText.substring(with: currentLineRange)
            if let match = MarkdownLists.listRegex.firstMatch(in: listLine, range: NSRange(location: 0, length: listLine.utf16.count)) {
                let contentStart = match.range.location + match.range.length
                let contentLength = listLine.utf16.count - contentStart
                let contentRangeLocal = NSRange(location: contentStart, length: contentLength)
                let contentText = (listLine as NSString).substring(with: contentRangeLocal).trimmingCharacters(in: .whitespacesAndNewlines)
                if contentText.isEmpty {
                    return removeLinePrefixAndExit(
                        textView: textView,
                        currentLineRange: currentLineRange,
                        prefixLength: match.range.location + match.range.length
                    )
                }
                let leadingWhitespace: String
                if let wsMatch = MarkdownLists.leadingWhitespaceRegex.firstMatch(in: listLine, range: NSRange(location: 0, length: listLine.utf16.count)) {
                    leadingWhitespace = (listLine as NSString).substring(with: wsMatch.range)
                } else {
                    leadingWhitespace = ""
                }
                let markerRaw = (listLine as NSString).substring(with: match.range(at: 1))
                let marker = markerRaw.trimmingCharacters(in: .whitespaces)
                let hasCheckbox = marker.range(of: #"\[[ xX]\]"#, options: .regularExpression) != nil
                let newListItem: String
                if match.range(at: 2).location != NSNotFound,
                   let number = Int((listLine as NSString).substring(with: match.range(at: 2))) {
                    if hasCheckbox {
                        newListItem = "\n" + leadingWhitespace + "\(number + 1). [ ] "
                    } else {
                        newListItem = "\n" + leadingWhitespace + "\(number + 1). "
                    }
                } else {
                    let prefixIndent = leadingWhitespace.isEmpty ? "  " : leadingWhitespace
                    if hasCheckbox {
                        let bulletChar = marker.contains("•") ? "•" : "-"
                        newListItem = "\n" + prefixIndent + "\(bulletChar) [ ] "
                    } else {
                        newListItem = "\n" + prefixIndent + marker + " "
                    }
                }
                MarkdownLists.performEdit(textView, replace: affectedCharRange, with: newListItem)
                return false
            }
        }

        return true
    }
}
