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

    // MARK: Fenced code

    @Test func fencedCodeBlockNoLanguage() {
        let text = "```\nlet x = 1\n```"
        let result = BlockScanner.scan(text)
        #expect(result.blocks.count == 1)
        if case .fencedCode(let lang) = result.blocks.first?.kind {
            #expect(lang == nil)
        } else {
            Issue.record("Expected fencedCode kind")
        }
    }

    @Test func fencedCodeBlockWithLanguage() {
        let text = "```swift\nlet x = 1\n```"
        let result = BlockScanner.scan(text)
        if case .fencedCode(let lang) = result.blocks.first?.kind {
            #expect(lang == "swift")
        } else {
            Issue.record("Expected fencedCode kind")
        }
    }

    @Test func fencedCodeContentRangeCoversOnlyBody() {
        let text = "```\nbody\n```"
        let result = BlockScanner.scan(text)
        let block = result.blocks.first!
        let body = (text as NSString).substring(with: block.contentRange)
        #expect(body == "body\n")
    }

    @Test func fencedCodeBlockMarkerRangesCoverBothFences() {
        let text = "```\nbody\n```"
        let result = BlockScanner.scan(text)
        #expect(result.blocks.first?.markerRanges.count == 2)
    }

    @Test func emphasisLikeContentInsideFencedCodeIsIgnoredByBlockKind() {
        // Block scanner is responsible for marking content as "not inline" —
        // the pipeline filter is exercised in the integration tests.
        let text = "```\n**not bold**\n```"
        let result = BlockScanner.scan(text)
        let block = result.blocks.first!
        #expect(!block.kind.allowsInlineContent)
    }

    @Test func unclosedFencedCodeBlockFallsBackToParagraph() {
        // No closing fence => current parseTokens treats it as plain text.
        // Block scanner falls back to a single paragraph spanning the opening
        // fence through the rest of the input.
        let text = "```swift\nlet x = 1"
        let result = BlockScanner.scan(text)
        #expect(result.blocks.allSatisfy { $0.kind == .paragraph })
    }

    // MARK: Setext heading

    @Test func setextH1WithEqualsUnderline() {
        let text = "Title\n====="
        let result = BlockScanner.scan(text)
        #expect(result.blocks.count == 1)
        if case .heading(let level) = result.blocks.first?.kind {
            #expect(level == 1)
        } else {
            Issue.record("Expected heading kind")
        }
    }

    @Test func setextH2WithDashUnderline() {
        let text = "Title\n-----"
        let result = BlockScanner.scan(text)
        if case .heading(let level) = result.blocks.first?.kind {
            #expect(level == 2)
        } else {
            Issue.record("Expected heading kind")
        }
    }

    @Test func setextSpansMultipleParagraphLines() {
        let text = "Line one\nLine two\n==="
        let result = BlockScanner.scan(text)
        #expect(result.blocks.count == 1)
        if case .heading = result.blocks.first?.kind { /* ok */ } else { Issue.record("Expected heading") }
    }

    @Test func dashesAloneWithoutParagraphAreNotConsumedAsHeading() {
        // Without a preceding paragraph, `---` does not become a heading via Setext.
        // (Thematic-break recognition arrives in Task 6.)
        let text = "\n---"
        let result = BlockScanner.scan(text)
        #expect(!result.blocks.contains(where: {
            if case .heading = $0.kind { return true } else { return false }
        }))
    }
}
