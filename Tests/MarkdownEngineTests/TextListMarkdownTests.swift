//
//  TextListMarkdownTests.swift
//  MarkdownEngineTests
//
//  Writing Tools hand Key Points over as an AppKit list: markers in
//  `NSParagraphStyle.textLists`, none in the characters (measured on 27:
//  `textLists={disc}`, lines ending in two spaces). They have to reach the
//  note as Markdown list items.
//

import AppKit
import Testing
@testable import MarkdownEngine

@Suite("AppKit lists as Markdown")
struct TextListMarkdownTests {

    private static func style(_ lists: [NSTextList]) -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.textLists = lists
        return style
    }

    /// `lines` joined by newlines; each line in the lists given for it.
    private static func text(_ lines: [(String, [NSTextList])]) -> NSAttributedString {
        let out = NSMutableAttributedString()
        for (index, line) in lines.enumerated() {
            let ending = index == lines.count - 1 ? "" : "\n"
            out.append(NSAttributedString(string: line.0 + ending,
                                          attributes: [.paragraphStyle: style(line.1)]))
        }
        return out
    }

    private static let disc = NSTextList(markerFormat: .disc, options: 0)

    @Test("Key Points: each item gets `- `, its trailing hard break goes")
    func unorderedItems() throws {
        let text = Self.text([
            ("Potential Stock Slump: Nvidia fell.  ", [Self.disc]),
            ("Investigation Launched: The board acts.  ", [Self.disc]),
        ])
        let conversion = try #require(TextListMarkdown.conversion(of: text, in: NSRange(location: 0, length: text.length)))
        #expect(conversion.range == NSRange(location: 0, length: text.length))
        #expect(conversion.markdown == "- Potential Stock Slump: Nvidia fell.\n- Investigation Launched: The board acts.")
    }

    @Test("ordered items keep their numbers")
    func orderedItems() throws {
        let decimal = NSTextList(markerFormat: .decimal, options: 0)
        let text = Self.text([("first", [decimal]), ("second", [decimal]), ("third", [decimal])])
        let conversion = try #require(TextListMarkdown.conversion(of: text, in: NSRange(location: 0, length: text.length)))
        #expect(conversion.markdown == "1. first\n2. second\n3. third")
    }

    @Test("a nested item is indented one tab per level")
    func nestedItems() throws {
        let inner = NSTextList(markerFormat: .circle, options: 0)
        let text = Self.text([("outer", [Self.disc]), ("inner", [Self.disc, inner]), ("back", [Self.disc])])
        let conversion = try #require(TextListMarkdown.conversion(of: text, in: NSRange(location: 0, length: text.length)))
        #expect(conversion.markdown == "- outer\n\t- inner\n- back")
    }

    @Test("paragraphs around the list stay as they are, the range covers whole paragraphs")
    func surroundingText() throws {
        let text = Self.text([("Intro line.  ", []), ("item", [Self.disc]), ("Outro.", [])])
        // An edited range starting and ending mid-paragraph widens to whole paragraphs.
        let conversion = try #require(TextListMarkdown.conversion(of: text, in: NSRange(location: 3, length: 18)))
        #expect(conversion.range == NSRange(location: 0, length: text.length))
        #expect(conversion.original == text.string)
        #expect(conversion.markdown == "Intro line.  \n- item\nOutro.")
    }

    @Test("no list, or items that already carry a marker: nothing to convert")
    func nothingToDo() {
        let plain = Self.text([("just prose", []), ("more prose", [])])
        #expect(TextListMarkdown.conversion(of: plain, in: NSRange(location: 0, length: plain.length)) == nil)

        let marked = Self.text([("- already", [Self.disc]), ("1. numbered", [Self.disc])])
        #expect(TextListMarkdown.conversion(of: marked, in: NSRange(location: 0, length: marked.length)) == nil)

        let empty = NSAttributedString(string: "")
        #expect(TextListMarkdown.conversion(of: empty, in: NSRange(location: 0, length: 0)) == nil)
    }

    @Test("an empty paragraph inside a list gets no marker")
    func emptyParagraph() throws {
        let text = Self.text([("one", [Self.disc]), ("", [Self.disc]), ("two", [Self.disc])])
        let conversion = try #require(TextListMarkdown.conversion(of: text, in: NSRange(location: 0, length: text.length)))
        #expect(conversion.markdown == "- one\n\n- two")
    }
}
