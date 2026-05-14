//
//  BlockScannerTests.swift
//  MarkdownEngineTests
//

import Testing
import Foundation
@testable import MarkdownEngine

@Suite("BlockScanner")
struct BlockScannerTests {

    // MARK: Paragraph

    @Test func singleParagraph() {
        let result = BlockScanner.scan("Hello, world.")
        #expect(result.blocks.count == 1)
        if let first = result.blocks.first {
            #expect(first.kind == .paragraph)
            #expect(first.range == NSRange(location: 0, length: 13))
        }
    }

    @Test func twoParagraphsSeparatedByBlankLine() {
        let text = "First.\n\nSecond."
        let result = BlockScanner.scan(text)
        #expect(result.blocks.count == 2)
        #expect(result.blocks.allSatisfy { $0.kind == .paragraph })
    }

    @Test func paragraphSpanningMultipleSoftLines() {
        let text = "Line one\nLine two\nLine three"
        let result = BlockScanner.scan(text)
        #expect(result.blocks.count == 1)
        #expect(result.blocks.first?.kind == .paragraph)
    }

    @Test func emptyInputProducesNoBlocks() {
        let result = BlockScanner.scan("")
        #expect(result.blocks.isEmpty)
    }

    @Test func whitespaceOnlyInputProducesNoBlocks() {
        let result = BlockScanner.scan("\n   \n\n")
        #expect(result.blocks.isEmpty)
    }

    // MARK: ATX headings

    @Test func atxHeadingLevel1() {
        let result = BlockScanner.scan("# Title")
        #expect(result.blocks.count == 1)
        if case .heading(let level) = result.blocks.first?.kind {
            #expect(level == 1)
        } else {
            Issue.record("Expected heading kind")
        }
    }

    @Test func atxHeadingLevel6() {
        let result = BlockScanner.scan("###### Title")
        if case .heading(let level) = result.blocks.first?.kind {
            #expect(level == 6)
        } else {
            Issue.record("Expected heading kind")
        }
    }

    @Test func atxHeadingSevenHashesIsParagraph() {
        // CommonMark: more than 6 # is not a heading.
        let result = BlockScanner.scan("####### NotHeading")
        #expect(result.blocks.first?.kind == .paragraph)
    }

    @Test func atxHeadingWithoutSpaceIsParagraph() {
        // CommonMark: `#title` (no space) is a paragraph.
        let result = BlockScanner.scan("#NotHeading")
        #expect(result.blocks.first?.kind == .paragraph)
    }

    @Test func atxHeadingContentRangeExcludesHashAndSpace() {
        let result = BlockScanner.scan("## Title")
        let heading = result.blocks.first
        #expect(heading?.contentRange == NSRange(location: 3, length: 5))
    }

    @Test func atxHeadingMarkerRangeCoversHashes() {
        let result = BlockScanner.scan("### Title")
        let heading = result.blocks.first
        #expect(heading?.markerRanges.first == NSRange(location: 0, length: 3))
    }

    @Test func atxHeadingFollowedByParagraph() {
        let text = "# Heading\n\nParagraph body"
        let result = BlockScanner.scan(text)
        #expect(result.blocks.count == 2)
        if case .heading = result.blocks[0].kind { /* ok */ } else { Issue.record("first should be heading") }
        #expect(result.blocks[1].kind == .paragraph)
    }
}
