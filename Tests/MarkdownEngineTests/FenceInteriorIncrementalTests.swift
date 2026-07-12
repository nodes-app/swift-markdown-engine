//
//  FenceInteriorIncrementalTests.swift
//  MarkdownEngine
//
//  Created by Luca Chen on 12.07.26.
//
//  Typing INSIDE a fenced code / $$ block used to bail the incremental block
//  parse (full O(doc) reparse every keystroke). The window splice now handles
//  interior edits; these pin the two main cases plus the indented-$$ opener
//  regression the review caught. Broad differential coverage lives in the
//  pre-existing ParseIncrementalEquivalenceTests fuzz (fence + $$ templates).
//

import Foundation
import Testing
@testable import MarkdownEngine

@Suite("Fence-interior incremental parse")
struct FenceInteriorIncrementalTests {

    private func chars(_ s: String) -> [unichar] {
        let ns = s as NSString
        var buf = [unichar](repeating: 0, count: ns.length)
        if ns.length > 0 { ns.getCharacters(&buf, range: NSRange(location: 0, length: ns.length)) }
        return buf
    }

    private func splice(_ old: String, at loc: Int, remove: Int, insert: String)
        -> (new: String, diff: BufferDiff) {
        let ns = NSMutableString(string: old)
        ns.replaceCharacters(in: NSRange(location: loc, length: remove), with: insert)
        let insertLen = (insert as NSString).length
        return (ns as String, BufferDiff(
            changeStart: loc,
            changeEndOld: loc + remove,
            changeEndNew: loc + insertLen,
            delta: insertLen - remove
        ))
    }

    /// nil = splice bailed to full parse (also correct); true/false = blocks match.
    private func spliceEqualsFullParse(_ old: String, at loc: Int, remove: Int, insert: String) -> Bool? {
        let (new, diff) = splice(old, at: loc, remove: remove, insert: insert)
        guard let result = BlockParser.incrementalParse(
            oldChars: chars(old), oldBlocks: BlockParser.computeBlocks(old),
            newChars: chars(new), newNS: new as NSString, diff: diff
        ) else { return nil }
        return result.blocks == BlockParser.computeBlocks(new)
    }

    @Test func interiorFenceEditSplicesIncrementally() {
        let old = "para one\n\n```swift\nlet x = 1\nlet y = 2\n```\n\ntail paragraph"
        let editLoc = (old as NSString).range(of: "x = 1").location
        #expect(spliceEqualsFullParse(old, at: editLoc, remove: 1, insert: "value") == true)
    }

    @Test func interiorBlockLatexEditSplicesIncrementally() {
        let old = "before\n\n$$\nE = mc^2\n$$\n\nafter text"
        let editLoc = (old as NSString).range(of: "mc^2").location
        #expect(spliceEqualsFullParse(old, at: editLoc, remove: 0, insert: "k") == true)
    }

    // Review regression: isBlockLatexOpen matches the TRIMMED line prefix, so
    // an edit in the leading whitespace of an indented `$$` opener flips its
    // pairing from past the old ±3-char delimiter guard. The splice must bail
    // or match ground truth.
    @Test func indentedLatexOpenerWhitespaceInsertStaysEquivalent() {
        let old = "intro\n\n   $$\n   a = 1\n   $$\nmiddle text\n\n$$\nb = 2\n$$\ntail"
        let openerLoc = (old as NSString).range(of: "   $$").location
        if let result = spliceEqualsFullParse(old, at: openerLoc, remove: 0, insert: "x") {
            #expect(result)
        }
    }
}
