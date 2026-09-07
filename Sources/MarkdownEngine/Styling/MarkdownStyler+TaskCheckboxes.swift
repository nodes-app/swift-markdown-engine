#if os(macOS)
//
//  MarkdownStyler+TaskCheckboxes.swift
//  MarkdownEngine
//
//  Caret-crossing helper for GitHub-style `- [ ] / - [x]` task syntax. The
//  checkbox *styling* now lives in the AST styler (`MarkdownASTStyler`); this
//  only reports whether the caret sits inside the task syntax so the
//  coordinator can trigger a restyle when the caret enters/leaves.
//

import AppKit
import Foundation

extension MarkdownStyler {

    /// Task-list line: indent, marker (`-`/`*`/`+`/`•`/`N.` matching the AST), spacer, `[ ]`/`[x]` box.
    static let taskListRegex: NSRegularExpression = try! NSRegularExpression(
        pattern: #"^([ \t]*)([-•*+]|\d+\.)([ \t]+)(\[[ xX]\])(?=[ \t])"#,
        options: [.anchorsMatchLines]
    )

    // MARK: Task Syntax Membership

    /// Full `<marker><spacer>[ ]` range if `location` is inside (or at the trailing edge of) it, else nil.
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
}
#endif
