//
//  HangingCaretTests.swift
//  MarkdownEngineTests
//
//  Spaces at a soft wrap hang past the margin and TextKit clamps the caret
//  there, so typing a space at the right edge showed nothing. These pin where
//  such a caret is drawn instead, and that line moves start from that spot.
//

import AppKit
import Foundation
import Testing
@testable import MarkdownEngine

@MainActor
@Suite("Hanging caret")
struct HangingCaretTests {

    private let width: CGFloat = 200
    /// More spaces than a line holds: whatever the wrap, they reach past the margin.
    private let spaces = String(repeating: " ", count: 60)
    private let words = Array(repeating: "lorem", count: 30).joined(separator: " ")

    private func makeTextView(_ text: String) -> NativeTextView {
        let tv = NativeTextView(frame: NSRect(x: 0, y: 0, width: width, height: 600))
        tv.textContainer?.lineFragmentPadding = 0
        tv.textContainer?.size = NSSize(width: width, height: .greatestFiniteMagnitude)
        tv.textContainerInset = .zero
        tv.textStorage?.setAttributedString(NSAttributedString(
            string: text,
            attributes: [.font: NSFont.systemFont(ofSize: 16), .paragraphStyle: NSParagraphStyle.default]
        ))
        if let tlm = tv.textLayoutManager { tlm.ensureLayout(for: tlm.documentRange) }
        return tv
    }

    /// Document offset and top of every visual line, in layout order.
    private func lines(_ tv: NativeTextView) -> [(start: Int, minY: CGFloat)] {
        guard let tlm = tv.textLayoutManager, let tcs = tlm.textContentManager else { return [] }
        var result: [(Int, CGFloat)] = []
        tlm.enumerateTextLayoutFragments(from: tcs.documentRange.location, options: [.ensuresLayout]) { fragment in
            let paragraphStart = tcs.offset(from: tcs.documentRange.location, to: fragment.rangeInElement.location)
            for line in fragment.textLineFragments where line.characterRange.length > 0 {
                result.append((paragraphStart + line.characterRange.location,
                               fragment.layoutFragmentFrame.minY + line.typographicBounds.minY))
            }
            return true
        }
        return result
    }

    /// `words` with `spaces` inserted before the first line's trailing space,
    /// and the caret right after them (the run the bug report typed into).
    private func midParagraph() throws -> (tv: NativeTextView, caret: Int, nextLine: Int) {
        let wrap = try #require(lines(makeTextView(words)).dropFirst().first).start
        let text = (words as NSString).replacingCharacters(
            in: NSRange(location: wrap - 1, length: 0), with: spaces)
        let tv = makeTextView(text)
        let nextLine = wrap + spaces.utf16.count
        try #require(lines(tv).dropFirst().first?.start == nextLine, "the spaces hang on the first line")
        return (tv, wrap - 1 + spaces.utf16.count, nextLine)
    }

    @Test("a caret in spaces past the margin is drawn at the next line's start")
    func midParagraphHangsToNextLine() throws {
        let (tv, caret, nextLine) = try midParagraph()
        let hanging = try #require(tv.hangingCaret(at: caret, affinity: .upstream))
        #expect(hanging.placement == .nextLine)
        #expect(hanging.navigationAnchor == nextLine)
        #expect(abs(hanging.rect.minX) < 0.5)
        let secondRow = try #require(lines(tv).dropFirst().first).minY
        #expect(abs(hanging.rect.minY - secondRow) < 0.5)
    }

    @Test("at the wrap point only the upstream caret hangs")
    func wrapPointDependsOnAffinity() throws {
        let (tv, _, nextLine) = try midParagraph()
        #expect(tv.hangingCaret(at: nextLine, affinity: .upstream)?.placement == .nextLine)
        #expect(tv.hangingCaret(at: nextLine, affinity: .downstream) == nil)
    }

    @Test("a caret after a space with room left stays where TextKit puts it")
    func ordinarySpaceDoesNotHang() {
        let tv = makeTextView(words)
        #expect(tv.hangingCaret(at: 6, affinity: .upstream) == nil)  // after "lorem "
        #expect(tv.hangingCaret(at: 5, affinity: .upstream) == nil)  // after "lorem"
    }

    @Test("spaces ending the document open a new line below the last one")
    func documentEndOpensNewLine() throws {
        let text = words + spaces
        let tv = makeTextView(text)
        let hanging = try #require(tv.hangingCaret(at: text.utf16.count, affinity: .upstream))
        #expect(hanging.placement == .newLine)
        #expect(hanging.navigationAnchor == nil)
        #expect(abs(hanging.rect.minX) < 0.5)
        let lastRow = try #require(lines(tv).last).minY
        #expect(hanging.rect.minY > lastRow + 0.5)
    }

    @Test("the new line may sit over an empty paragraph, which anchors line moves")
    func emptyParagraphBelowIsFree() throws {
        let text = words + spaces + "\n\nnext"
        let tv = makeTextView(text)
        let caret = (words + spaces).utf16.count
        let hanging = try #require(tv.hangingCaret(at: caret, affinity: .upstream))
        #expect(hanging.placement == .newLine)
        #expect(hanging.navigationAnchor == caret + 1)
    }

    @Test("the new line is never drawn over the next paragraph's text")
    func textBelowFallsBackToTheMargin() {
        let text = words + spaces + "\nnext"
        let tv = makeTextView(text)
        #expect(tv.hangingCaret(at: (words + spaces).utf16.count, affinity: .upstream) == nil)
    }

    @Test("↓ and ⌘→ start from the line the caret is drawn on")
    func lineMovesStartFromTheDrawnRow() throws {
        let (tv, caret, nextLine) = try midParagraph()
        let rows = lines(tv)
        try #require(rows.count >= 4)

        tv.setSelectedRange(NSRange(location: caret, length: 0), affinity: .upstream, stillSelecting: false)
        #expect(tv.startLineMoveFromHangingCaret(#selector(NSResponder.moveToRightEndOfLine(_:))) == false)
        #expect(tv.selectedRange() == NSRange(location: nextLine, length: 0))
        #expect(tv.selectionAffinity == .downstream)
        tv.moveToRightEndOfLine(nil)
        #expect((rows[1].start..<rows[2].start).contains(tv.selectedRange().location - 1),
                "⌘→ ends the second line, not the hanging first one")

        tv.setSelectedRange(NSRange(location: caret, length: 0), affinity: .upstream, stillSelecting: false)
        #expect(tv.startLineMoveFromHangingCaret(#selector(NSResponder.moveDown(_:))) == false)
        tv.moveDown(nil)
        #expect(tv.selectedRange().location == rows[2].start, "↓ lands at the third line's start")
    }
}
