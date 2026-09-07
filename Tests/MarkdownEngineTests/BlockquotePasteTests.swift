#if os(macOS)
//
//  BlockquotePasteTests.swift
//  MarkdownEngineTests
//
//  Created by Nicolas von Mallinckrodt on 02.06.26.
//
//  Pasting multi-line text onto a blockquote line should keep every line in
//  the quote — mirroring the Enter-key continuation, not just the first line.
//

import Foundation
import Testing
@testable import MarkdownEngine

@Suite("Blockquote multi-line paste")
struct BlockquotePasteTests {

    private func paste(_ text: String, at location: Int, into document: String) -> String {
        MarkdownLists.blockquoteContinuedPaste(text, at: location, in: document)
    }

    @Test("every pasted line gets the quote prefix")
    func prefixesEveryLine() {
        // caret at end of "> " (location 2)
        #expect(paste("line1\nline2\nline3", at: 2, into: "> ")
                == "line1\n> line2\n> line3")
    }

    @Test("caret after existing quote content still prefixes following lines")
    func prefixesAfterContent() {
        // "> foo" with caret at end (location 5)
        #expect(paste("a\nb", at: 5, into: "> foo") == "a\n> b")
    }

    @Test("nested quote markers are preserved")
    func nestedMarkers() {
        #expect(paste("a\nb", at: 3, into: ">> ") == "a\n>> b")
    }

    @Test("leading indentation of the quote line is preserved")
    func indentedQuote() {
        #expect(paste("a\nb", at: 4, into: "  > ") == "a\n  > b")
    }

    @Test("blank lines inside the paste stay in the quote")
    func blankLinesStayQuoted() {
        #expect(paste("a\n\nb", at: 2, into: "> ") == "a\n> \n> b")
    }

    @Test("single-line paste is unchanged")
    func singleLineUnchanged() {
        #expect(paste("hello", at: 2, into: "> ") == "hello")
    }

    @Test("paste on a non-quote line is unchanged")
    func nonQuoteUnchanged() {
        #expect(paste("a\nb", at: 5, into: "plain") == "a\nb")
    }

    @Test("out-of-range location is handled safely")
    func outOfRangeLocation() {
        #expect(paste("a\nb", at: 999, into: "> ") == "a\nb")
    }
}
#endif
