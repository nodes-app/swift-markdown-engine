//
//  MarkdownStyler+TaskCheckboxes.swift
//  MarkdownEngine
//
//  Created by Luca Chen on 16.03.26.
//
//  GitHub-style `- [ ] / - [x]` task checkbox styling and strike-through.
//

import AppKit
import Foundation

extension MarkdownStyler {

    // MARK: Task Syntax Membership

    /// Returns the full `<marker><spacer>[ ]` range on `location`'s line if
    /// `location` sits inside (or right at the trailing edge of) a task-list
    /// syntax region, else `nil`. The styler intentionally suppresses the
    /// checkbox glyph while the caret is inside this region so the user can
    /// edit raw chars; the coordinator uses this to detect crossings and
    /// trigger a restyle when the caret enters/leaves.
    static func taskSyntaxRange(at location: Int, in text: String) -> NSRange? {
        let nsText = text as NSString
        let safeLoc = max(0, min(location, nsText.length))
        let lineRange = nsText.lineRange(for: NSRange(location: safeLoc, length: 0))
        let line = nsText.substring(with: lineRange)
        let match = taskListRegex.firstMatch(
            in: line,
            options: [],
            range: NSRange(location: 0, length: line.utf16.count)
        )
        guard let match else { return nil }
        let markerLineRange = match.range(at: 2)
        let checkboxLineRange = match.range(at: 4)
        guard markerLineRange.location != NSNotFound,
              checkboxLineRange.location != NSNotFound else { return nil }
        let syntaxStart = lineRange.location + markerLineRange.location
        let syntaxEnd = lineRange.location + checkboxLineRange.location + checkboxLineRange.length
        let syntaxRange = NSRange(location: syntaxStart, length: syntaxEnd - syntaxStart)
        if NSLocationInRange(location, syntaxRange) || location == syntaxEnd {
            return syntaxRange
        }
        return nil
    }

    // MARK: Task List Checkboxes

    static func styleTaskCheckboxes(_ ctx: StylingContext) -> [StyledRange] {
        var attrs: [StyledRange] = []
        let taskMatches = MarkdownStyler.taskListRegex.matches(in: ctx.text, options: [], range: ctx.fullRange)
        for match in taskMatches {
            let markerRange = match.range(at: 2)
            let spacerRange = match.range(at: 3)
            let checkboxRange = match.range(at: 4)
            if checkboxRange.location == NSNotFound { continue }
            if MarkdownDetection.isInsideCodeBlock(range: checkboxRange, codeTokens: ctx.codeTokens) { continue }
            let checkboxText = ctx.nsText.substring(with: checkboxRange)
            let isChecked = checkboxText.range(of: "[x]", options: [.caseInsensitive]) != nil
            if markerRange.location != NSNotFound {
                let syntaxStart = markerRange.location
                let syntaxEnd = checkboxRange.location + checkboxRange.length
                let syntaxRange = NSRange(location: syntaxStart, length: max(0, syntaxEnd - syntaxStart))
                var isActiveSyntax = NSLocationInRange(ctx.caretLocation, syntaxRange)
                if !isActiveSyntax && ctx.caretLocation == syntaxEnd {
                    let lastIndex = syntaxEnd - 1
                    if lastIndex >= syntaxStart && lastIndex < ctx.nsText.length {
                        let lastChar = ctx.nsText.substring(with: NSRange(location: lastIndex, length: 1))
                        if lastChar != "\n" { isActiveSyntax = true }
                    }
                }
                if isChecked {
                    let lineRange = ctx.nsText.lineRange(for: checkboxRange)
                    var lineEnd = lineRange.location + lineRange.length
                    if lineEnd > lineRange.location {
                        let lastCharRange = NSRange(location: lineEnd - 1, length: 1)
                        if ctx.nsText.substring(with: lastCharRange) == "\n" {
                            lineEnd -= 1
                        }
                    }
                    var contentStart = checkboxRange.location + checkboxRange.length
                    while contentStart < lineEnd {
                        let charRange = NSRange(location: contentStart, length: 1)
                        let char = ctx.nsText.substring(with: charRange)
                        if char == " " || char == "\t" {
                            contentStart += 1
                            continue
                        }
                        break
                    }
                    if contentStart < lineEnd {
                        attrs.append((NSRange(location: contentStart, length: lineEnd - contentStart), [
                            .strikethroughStyle: NSUnderlineStyle.single.rawValue,
                            .strikethroughColor: ctx.configuration.theme.strikethroughColor
                        ]))
                    }
                }
                if isActiveSyntax { continue }
                let afterCheckboxIndex = checkboxRange.location + checkboxRange.length
                if afterCheckboxIndex < ctx.nsText.length {
                    let spaceRange = NSRange(location: afterCheckboxIndex, length: 1)
                    let spaceChar = ctx.nsText.substring(with: spaceRange)
                    if spaceChar == " " && !isChecked {
                        let extraSpacing = HeadingHelpers.checkboxExtraSpacing(
                            font: ctx.baseFont,
                            configuration: ctx.configuration.checkbox
                        )
                        attrs.append((spaceRange, [.kern: extraSpacing]))
                    }
                }
            }
            if markerRange.location != NSNotFound {
                attrs.append((markerRange, [.foregroundColor: NSColor.clear]))
            }
            if spacerRange.location != NSNotFound {
                attrs.append((spacerRange, [.foregroundColor: NSColor.clear]))
            }
            attrs.append((checkboxRange, [
                .taskCheckbox: isChecked,
                .foregroundColor: NSColor.clear
            ]))
        }
        return attrs
    }
}
