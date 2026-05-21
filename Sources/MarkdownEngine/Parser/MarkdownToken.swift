//
//  MarkdownToken.swift
//  MarkdownEngine
//
//  Created by Luca Chen on 18.02.26.
//

// Defines the basic Markdown building blocks the editor works with (bold,
// links, code, LaTeX, etc.), plus shared text attributes.
import Foundation

extension NSAttributedString.Key {
    public static let wikiLinkID    = NSAttributedString.Key("NodeLinkID")
    public static let taskCheckbox  = NSAttributedString.Key("TaskCheckbox")
    // LaTeX rendering overlay (consumed by MarkdownTextLayoutFragment on macOS)
    static let latexImage           = NSAttributedString.Key("LatexRenderedImage")
    static let latexBounds          = NSAttributedString.Key("LatexImageBounds")
    static let latexIsBlock         = NSAttributedString.Key("LatexIsBlock")
    static let latexBlockOffsetY    = NSAttributedString.Key("LatexBlockOffsetY")
    // Spell-check suppression — AppKit reads "NSSpellingState", no-op on iOS
    static let spellingState        = NSAttributedString.Key("NSSpellingState")
}

enum MarkdownTokenKind {
    case italic
    case boldItalic
    case bold
    case link
    case wikiLink
    case heading
    case codeBlock
    case inlineCode
    case blockLatex
    case inlineLatex
    case imageEmbed
}

struct MarkdownToken {
    let kind: MarkdownTokenKind
    let range: NSRange
    let contentRange: NSRange
    let markerRanges: [NSRange]
}

extension MarkdownToken {
    func standaloneParagraphRange(in text: NSString) -> NSRange? {
        let paragraphRange = text.paragraphRange(for: range)
        let paragraphText = text.substring(with: paragraphRange) as NSString
        let tokenRelativeRange = NSRange(
            location: range.location - paragraphRange.location,
            length: range.length
        )
        let mutableParagraph = paragraphText.mutableCopy() as! NSMutableString
        mutableParagraph.replaceCharacters(in: tokenRelativeRange, with: "")
        return mutableParagraph.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? paragraphRange : nil
    }

    func containsSelectionOrStandaloneParagraph(_ selectionLocation: Int, in text: NSString) -> Bool {
        let start = range.location
        let end = NSMaxRange(range) - 1
        if selectionLocation >= start && selectionLocation <= end {
            return true
        }

        guard let paragraphRange = standaloneParagraphRange(in: text) else {
            return false
        }
        let paragraphEnd = NSMaxRange(paragraphRange)
        let isAtLastParagraphEnd = selectionLocation == text.length && paragraphEnd == text.length
        return (selectionLocation >= paragraphRange.location && selectionLocation < paragraphEnd)
            || isAtLastParagraphEnd
    }
}
