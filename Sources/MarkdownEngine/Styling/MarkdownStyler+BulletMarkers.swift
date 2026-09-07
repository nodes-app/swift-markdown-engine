#if os(macOS)
//
//  MarkdownStyler+BulletMarkers.swift
//  MarkdownEngine
//
//  Caret-crossing helper for `-`/`*`/`+` bullet syntax. Bullet *rendering*
//  (the `•` overlay) now lives in the AST styler (`MarkdownASTStyler`); this
//  only reports caret membership so the coordinator can restyle on crossings.
//

import AppKit
import Foundation

extension MarkdownStyler {

    /// Indented bullet marker at line start (trailing space excludes `---`/`*bold*`), not a checkbox.
    static let bulletListRegex: NSRegularExpression = try! NSRegularExpression(
        pattern: #"^([ \t]*)([-*+])([ \t]+)(?!\[[ xX]\])"#,
        options: [.anchorsMatchLines]
    )

    // MARK: Bullet Syntax Membership

    /// `<marker><spaces>` range on `location`'s line, or `nil` if the caret isn't strictly inside.
    static func bulletSyntaxRange(at location: Int, in text: String) -> NSRange? {
        let nsText = text as NSString
        let safeLoc = max(0, min(location, nsText.length))
        let lineRange = nsText.lineRange(for: NSRange(location: safeLoc, length: 0))
        let line = nsText.substring(with: lineRange)
        guard let match = bulletListRegex.firstMatch(
            in: line,
            options: [],
            range: NSRange(location: 0, length: line.utf16.count)
        ) else { return nil }
        let markerLineRange = match.range(at: 2)
        let spacerLineRange = match.range(at: 3)
        guard markerLineRange.location != NSNotFound,
              spacerLineRange.location != NSNotFound else { return nil }
        let syntaxStart = lineRange.location + markerLineRange.location
        let syntaxEnd = lineRange.location + spacerLineRange.location + spacerLineRange.length
        let syntaxRange = NSRange(location: syntaxStart, length: syntaxEnd - syntaxStart)
        if NSLocationInRange(location, syntaxRange) {
            return syntaxRange
        }
        return nil
    }
}
#endif
