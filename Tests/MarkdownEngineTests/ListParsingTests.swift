#if os(macOS)
//
//  ListParsingTests.swift
//  MarkdownEngineTests
//
//  Phase A — list modeling in the AST: BlockParser detection/grouping +
//  DocumentAST per-item parsing (marker, ordered/number, task checkbox, indent,
//  inline content). Line-based; nesting/tight-loose are Phase B.
//

import Foundation
import Testing
@testable import MarkdownEngine

@Suite("Phase A — list parsing")
struct ListParsingTests {

    private func items(_ text: String) -> [ListItem]? {
        for b in DocumentAST.parse(text) { if case .list(_, let items) = b { return items } }
        return nil
    }

    private func hasList(_ blocks: [Block]) -> Bool {
        blocks.contains { if case .list = $0.kind { return true }; return false }
    }

    @Test func consecutiveBulletLinesAreOneListBlock() {
        let lists = BlockParser.parse("- a\n- b\n- c\n").filter {
            if case .list = $0.kind { return true }; return false
        }
        #expect(lists.count == 1)
    }

    @Test func bulletItemParsed() {
        let it = items("- hello\n")
        #expect(it?.count == 1)
        #expect(it?.first?.ordered == false)
        #expect(it?.first?.checkbox == nil)
        #expect(it?.first?.marker.length == 1)
    }

    @Test func orderedItemCarriesNumber() {
        let it = items("3. third\n")
        #expect(it?.first?.ordered == true)
        #expect(it?.first?.number == 3)
        #expect(it?.first?.marker.length == 2)   // "3."
    }

    @Test func taskCheckboxParsed() {
        #expect(items("- [x] done\n")?.first?.checked == true)
        #expect(items("- [x] done\n")?.first?.checkbox != nil)
        #expect(items("- [ ] todo\n")?.first?.checked == false)
        #expect(items("- [ ] todo\n")?.first?.checkbox != nil)
    }

    @Test func indentIsCaptured() {
        #expect(items("    - nested\n")?.first?.indent == 4)
    }

    @Test func itemInlineContentIsParsed() {
        let inlines = items("- a **b** c\n")?.first?.inlines ?? []
        #expect(inlines.contains { if case .emphasis(.bold, _, _, _) = $0 { return true }; return false })
    }

    @Test func dashWithoutSpaceIsNotAList() {
        #expect(!hasList(BlockParser.parse("-foo\n")))
    }

    @Test func tripleDashStaysThematicBreak() {
        let blocks = BlockParser.parse("---\n")
        #expect(!hasList(blocks))
        #expect(blocks.contains { if case .thematicBreak = $0.kind { return true }; return false })
    }

    @Test func plainLineAfterListDoesNotMergeIn() {
        let blocks = BlockParser.parse("- item\ntext\n")
        #expect(hasList(blocks))
        #expect(blocks.contains { if case .paragraph = $0.kind { return true }; return false })
    }

    /// The caret-crossing trigger must recognize the same task markers the
    /// styler does — incl. `*`/`+` (the styler treats `* [ ]` as a task; if the
    /// trigger disagrees the raw syntax won't reveal on caret entry).
    @Test func taskTriggerRecognizesStarAndPlusMarkers() {
        #expect(MarkdownStyler.taskSyntaxRange(at: 0, in: "- [ ] task") != nil)
        #expect(MarkdownStyler.taskSyntaxRange(at: 0, in: "* [ ] task") != nil)
        #expect(MarkdownStyler.taskSyntaxRange(at: 0, in: "+ [ ] task") != nil)
    }

    /// A bare marker with no following space is NOT a list yet — typing `-`
    /// (or `*` to start emphasis) must stay literal until a space follows, so
    /// the bullet/indent only appears for `- `. (Matches the pre-AST behavior.)
    @Test func bareMarkerWithoutSpaceIsNotAList() {
        #expect(!BlockParser.isListItem("-"))
        #expect(!BlockParser.isListItem("*"))
        #expect(!BlockParser.isListItem("1."))
        #expect(!hasList(BlockParser.parse("-")))
        #expect(BlockParser.isListItem("- "))
        #expect(BlockParser.isListItem("- x"))
        #expect(BlockParser.isListItem("1. x"))
    }
}
#endif
