//
//  TextListMarkdown.swift
//  MarkdownEngine
//
//  Created by Luca Chen on 09.11.26.
//
//  AppKit lists written out as Markdown. Writing Tools hand a Key Points or List
//  result over as rich text: the list lives in `NSParagraphStyle.textLists`, which
//  TextKit draws, and the characters hold no marker. The styler then replaces the
//  paragraph style, so the list was gone from the note.
//

import AppKit

enum TextListMarkdown {
    struct Conversion: Equatable {
        /// The whole paragraphs to replace, and what they hold now.
        let range: NSRange
        let original: String
        let markdown: String
    }

    /// The paragraphs `range` touches, each list item given its Markdown marker
    /// (`- `, or `n. ` for an ordered list, a tab per level of nesting). Nil when
    /// no paragraph needs one.
    static func conversion(of text: NSAttributedString, in range: NSRange) -> Conversion? {
        let string = text.string as NSString
        guard range.location != NSNotFound, NSMaxRange(range) <= string.length, string.length > 0 else { return nil }
        let paragraphs = string.paragraphRange(for: range)
        var markdown = ""
        var converted = false
        string.enumerateSubstrings(in: paragraphs, options: [.byParagraphs, .substringNotRequired]) { _, line, enclosing, _ in
            let body = string.substring(with: line)
            let terminator = string.substring(with: NSRange(location: NSMaxRange(line),
                                                            length: NSMaxRange(enclosing) - NSMaxRange(line)))
            let lists = line.length > 0
                ? (text.attribute(.paragraphStyle, at: line.location, effectiveRange: nil) as? NSParagraphStyle)?.textLists ?? []
                : []
            guard let list = lists.last, !hasMarker(body) else {
                markdown += body + terminator
                return
            }
            converted = true
            let marker = list.isOrdered ? "\(text.itemNumber(in: list, at: line.location)). " : "- "
            let indent = String(repeating: "\t", count: lists.count - 1)
            // The plain-text form of a list item ends in two spaces, a Markdown hard
            // break, which means nothing at the end of an item.
            markdown += indent + marker + trimmingTrailingSpaces(body) + terminator
        }
        guard converted else { return nil }
        return Conversion(range: paragraphs, original: string.substring(with: paragraphs), markdown: markdown)
    }

    private static func hasMarker(_ line: String) -> Bool {
        let ns = line as NSString
        return MarkdownLists.listRegex.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)) != nil
    }

    private static func trimmingTrailingSpaces(_ line: String) -> String {
        var line = line
        while let last = line.last, last == " " || last == "\t" { line.removeLast() }
        return line
    }
}
