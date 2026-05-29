//
//  InlineParserTests.swift
//  MarkdownEngineTests
//
//  Phase 2 — test-first specification of the inline parser. Ranges are
//  relative to the parsed string.
//

import Foundation
import Testing
@testable import MarkdownEngine

@Suite("Phase 2 — inline parser")
struct InlineParserTests {

    private func r(_ location: Int, _ length: Int) -> NSRange {
        NSRange(location: location, length: length)
    }

    @Test("empty string yields no nodes")
    func empty() {
        #expect(InlineParser.parse("") == [])
    }

    @Test("plain text is a single text node")
    func plainText() {
        #expect(InlineParser.parse("hello") == [.text(r(0, 5))])
    }

    @Test("a code span splits the surrounding text")
    func codeSpan() {
        #expect(InlineParser.parse("a `code` b") == [
            .text(r(0, 2)),
            .code(range: r(2, 6), content: r(3, 4)),
            .text(r(8, 2)),
        ])
    }

    @Test("an unclosed backtick run stays literal text")
    func unclosedBacktick() {
        #expect(InlineParser.parse("a `b") == [.text(r(0, 4))])
    }

    // MARK: - Emphasis (asterisks)

    @Test("single asterisks → italic")
    func italic() {
        #expect(InlineParser.parse("*x*") == [
            .emphasis(.italic, range: r(0, 3), markers: [r(0, 1), r(2, 1)], children: [.text(r(1, 1))]),
        ])
    }

    @Test("double asterisks → bold")
    func bold() {
        #expect(InlineParser.parse("**x**") == [
            .emphasis(.bold, range: r(0, 5), markers: [r(0, 2), r(3, 2)], children: [.text(r(2, 1))]),
        ])
    }

    @Test("triple asterisks → bold+italic")
    func boldItalic() {
        #expect(InlineParser.parse("***x***") == [
            .emphasis(.boldItalic, range: r(0, 7), markers: [r(0, 3), r(4, 3)], children: [.text(r(3, 1))]),
        ])
    }

    @Test("nested emphasis builds a tree")
    func nestedEmphasis() {
        #expect(InlineParser.parse("**a *b* c**") == [
            .emphasis(.bold, range: r(0, 11), markers: [r(0, 2), r(9, 2)], children: [
                .text(r(2, 2)),
                .emphasis(.italic, range: r(4, 3), markers: [r(4, 1), r(6, 1)], children: [.text(r(5, 1))]),
                .text(r(7, 2)),
            ]),
        ])
    }

    @Test("intraword asterisks still emphasize")
    func intrawordAsterisk() {
        #expect(InlineParser.parse("a*b*c") == [
            .text(r(0, 1)),
            .emphasis(.italic, range: r(1, 3), markers: [r(1, 1), r(3, 1)], children: [.text(r(2, 1))]),
            .text(r(4, 1)),
        ])
    }

    // MARK: - Emphasis (underscores)

    @Test("single underscores → italic")
    func underscoreItalic() {
        #expect(InlineParser.parse("_x_") == [
            .emphasis(.italic, range: r(0, 3), markers: [r(0, 1), r(2, 1)], children: [.text(r(1, 1))]),
        ])
    }

    @Test("intraword underscores stay literal (GFM)")
    func intrawordUnderscore() {
        #expect(InlineParser.parse("a_b_c") == [.text(r(0, 5))])
    }

    // MARK: - Emphasis × code-span precedence

    @Test("emphasis wraps a code span")
    func emphasisWrapsCode() {
        #expect(InlineParser.parse("*a `c` b*") == [
            .emphasis(.italic, range: r(0, 9), markers: [r(0, 1), r(8, 1)], children: [
                .text(r(1, 2)),
                .code(range: r(3, 3), content: r(4, 1)),
                .text(r(6, 2)),
            ]),
        ])
    }

    @Test("delimiters inside a code span are ignored")
    func delimitersInsideCodeIgnored() {
        #expect(InlineParser.parse("`*x*`") == [.code(range: r(0, 5), content: r(1, 3))])
    }

    // MARK: - Wiki-links & image embeds

    @Test("plain wiki-link")
    func wikiLink() {
        #expect(InlineParser.parse("[[Name]]") == [
            .wikiLink(range: r(0, 8), name: r(2, 4), id: nil, markers: [r(0, 2), r(6, 2)]),
        ])
    }

    @Test("wiki-link with id")
    func wikiLinkWithId() {
        #expect(InlineParser.parse("[[Name|abc]]") == [
            .wikiLink(range: r(0, 12), name: r(2, 4), id: r(7, 3), markers: [r(0, 2), r(10, 2)]),
        ])
    }

    @Test("image embed")
    func imageEmbed() {
        #expect(InlineParser.parse("![[Pic]]") == [
            .imageEmbed(range: r(0, 8), target: r(3, 3), markers: [r(0, 3), r(6, 2)]),
        ])
    }

    // MARK: - Links & images

    @Test("markdown link, text recursively parsed")
    func markdownLink() {
        #expect(InlineParser.parse("[text](url)") == [
            .link(range: r(0, 11), textRange: r(1, 4), url: r(7, 3),
                  markers: [r(0, 1), r(5, 1), r(6, 1), r(10, 1)], children: [.text(r(1, 4))]),
        ])
    }

    @Test("link URL keeps balanced parentheses (bug 4)")
    func linkWithBalancedParens() {
        #expect(InlineParser.parse("[a](b(c))") == [
            .link(range: r(0, 9), textRange: r(1, 1), url: r(4, 4),
                  markers: [r(0, 1), r(2, 1), r(3, 1), r(8, 1)], children: [.text(r(1, 1))]),
        ])
    }

    @Test("image")
    func image() {
        #expect(InlineParser.parse("![alt](u)") == [
            .image(range: r(0, 9), alt: r(2, 3), url: r(7, 1), markers: [r(0, 2), r(5, 1), r(6, 1), r(8, 1)]),
        ])
    }

    @Test("emphasis inside link text")
    func linkContainsEmphasis() {
        #expect(InlineParser.parse("[*x*](u)") == [
            .link(range: r(0, 8), textRange: r(1, 3), url: r(6, 1),
                  markers: [r(0, 1), r(4, 1), r(5, 1), r(7, 1)],
                  children: [.emphasis(.italic, range: r(1, 3), markers: [r(1, 1), r(3, 1)], children: [.text(r(2, 1))])]),
        ])
    }

    @Test("emphasis wraps a link")
    func emphasisWrapsLink() {
        #expect(InlineParser.parse("*[a](b)*") == [
            .emphasis(.italic, range: r(0, 8), markers: [r(0, 1), r(7, 1)], children: [
                .link(range: r(1, 6), textRange: r(2, 1), url: r(5, 1),
                      markers: [r(1, 1), r(3, 1), r(4, 1), r(6, 1)], children: [.text(r(2, 1))]),
            ]),
        ])
    }

    // MARK: - Inline LaTeX

    @Test("inline math")
    func inlineLatex() {
        #expect(InlineParser.parse("$a+b$") == [
            .inlineLatex(range: r(0, 5), content: r(1, 3), markers: [r(0, 1), r(4, 1)]),
        ])
    }

    @Test("currency-looking $…$ is not math")
    func currencyNotLatex() {
        #expect(InlineParser.parse("$50$") == [.text(r(0, 4))])
    }

    @Test("a $…$ span that would cross a code span is not math (bug 3)")
    func dollarAcrossCodeNotLatex() {
        #expect(InlineParser.parse("$x `c` y$") == [
            .text(r(0, 3)),
            .code(range: r(3, 3), content: r(4, 1)),
            .text(r(6, 3)),
        ])
    }

    // MARK: - Strikethrough

    @Test("strikethrough, content recursively parsed")
    func strikethrough() {
        #expect(InlineParser.parse("~~x~~") == [
            .strikethrough(range: r(0, 5), markers: [r(0, 2), r(3, 2)], children: [.text(r(2, 1))]),
        ])
    }

    @Test("triple tildes do not strike")
    func tripleTildeNotStrike() {
        #expect(InlineParser.parse("~~~x~~~") == [.text(r(0, 7))])
    }

    @Test("strikethrough wraps emphasis")
    func strikeWrapsEmphasis() {
        #expect(InlineParser.parse("~~*x*~~") == [
            .strikethrough(range: r(0, 7), markers: [r(0, 2), r(5, 2)], children: [
                .emphasis(.italic, range: r(2, 3), markers: [r(2, 1), r(4, 1)], children: [.text(r(3, 1))]),
            ]),
        ])
    }

    // MARK: - Backslash escapes

    @Test("escaped punctuation becomes an escape node")
    func backslashEscape() {
        #expect(InlineParser.parse(#"\*x"#) == [
            .escape(range: r(0, 2), character: r(1, 1), marker: r(0, 1)),
            .text(r(2, 1)),
        ])
    }

    @Test("escaped asterisks do not emphasize")
    func escapedStarsNotEmphasis() {
        #expect(InlineParser.parse(#"\*a\*"#) == [
            .escape(range: r(0, 2), character: r(1, 1), marker: r(0, 1)),
            .text(r(2, 1)),
            .escape(range: r(3, 2), character: r(4, 1), marker: r(3, 1)),
        ])
    }

    @Test("backslash inside a code span is literal (no escape)")
    func escapeInsideCodeIgnored() {
        #expect(InlineParser.parse(#"`\*`"#) == [.code(range: r(0, 4), content: r(1, 2))])
    }
}
