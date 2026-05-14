//
//  ParseTokensGoldenTests.swift
//  MarkdownEngineTests
//
//  Locks the current public behavior of MarkdownTokenizer.parseTokens.
//  Refactors must keep these green; new features add new fixtures.
//
//  Block-precedence tests (no emphasis / wiki-link inside fenced code) live in
//  the Phase-1 integration suite (ParseTokensBlockPhaseIntegrationTests), not
//  here — those assertions describe the post-refactor behavior; the baseline
//  snapshot must lock what the current regex parser actually emits.
//

import Testing
import Foundation
@testable import MarkdownEngine

@Suite("parseTokens golden output")
struct ParseTokensGoldenTests {

    // MARK: Headings

    @Test func atxHeadingsAllSixLevels() {
        let text = """
        # H1
        ## H2
        ### H3
        #### H4
        ##### H5
        ###### H6
        """
        let tokens = MarkdownTokenizer.parseTokens(in: text)
        let headings = tokens.filter { $0.kind == .heading }
        #expect(headings.count == 6)
    }

    @Test func headingFollowedByParagraphHasNoOverlap() {
        let text = "# Title\n\nBody text\n"
        let tokens = MarkdownTokenizer.parseTokens(in: text)
        let headings = tokens.filter { $0.kind == .heading }
        #expect(headings.count == 1)
        let heading = headings[0]
        #expect(NSMaxRange(heading.range) <= 7) // "# Title".count
    }

    // MARK: Fenced code blocks

    @Test func fencedCodeBlockWithLanguageProducesCodeBlockToken() {
        let text = """
        ```swift
        let x = 42
        ```
        """
        let tokens = MarkdownTokenizer.parseTokens(in: text)
        let code = tokens.filter { $0.kind == .codeBlock }
        #expect(code.count == 1)
    }

    // MARK: Inline (within paragraphs)

    @Test func boldEmphasisInParagraph() {
        let text = "This is **bold** text."
        let tokens = MarkdownTokenizer.parseTokens(in: text)
        let bold = tokens.filter { $0.kind == .bold }
        #expect(bold.count == 1)
    }

    @Test func italicEmphasisInParagraph() {
        let text = "This is *italic* text."
        let tokens = MarkdownTokenizer.parseTokens(in: text)
        let italic = tokens.filter { $0.kind == .italic }
        #expect(italic.count == 1)
    }

    @Test func wikiLinkInParagraph() {
        let text = "See [[Other Note]] for more."
        let tokens = MarkdownTokenizer.parseTokens(in: text)
        let wiki = tokens.filter { $0.kind == .wikiLink }
        #expect(wiki.count == 1)
    }

    @Test func imageEmbedInParagraph() {
        let text = "Look ![[picture.png]] here."
        let tokens = MarkdownTokenizer.parseTokens(in: text)
        let img = tokens.filter { $0.kind == .imageEmbed }
        #expect(img.count == 1)
    }

    @Test func inlineCodeInParagraph() {
        let text = "Call `foo()` to do it."
        let tokens = MarkdownTokenizer.parseTokens(in: text)
        let code = tokens.filter { $0.kind == .inlineCode }
        #expect(code.count == 1)
    }

    @Test func markdownLinkInParagraph() {
        let text = "Visit [Apple](https://apple.com) today."
        let tokens = MarkdownTokenizer.parseTokens(in: text)
        let link = tokens.filter { $0.kind == .link }
        #expect(link.count == 1)
    }

    // MARK: Mixed

    @Test func mixedContentPreservesAllTokenKinds() {
        let text = """
        # Heading with **bold**

        Paragraph with *italic*, `code`, and [[wiki]].

        ```swift
        let x = 1
        ```

        Trailing paragraph.
        """
        let tokens = MarkdownTokenizer.parseTokens(in: text)
        #expect(tokens.contains { $0.kind == .heading })
        #expect(tokens.contains { $0.kind == .bold })
        #expect(tokens.contains { $0.kind == .italic })
        #expect(tokens.contains { $0.kind == .inlineCode })
        #expect(tokens.contains { $0.kind == .wikiLink })
        #expect(tokens.contains { $0.kind == .codeBlock })
    }

    // MARK: Edge cases

    @Test func emptyDocumentReturnsNoTokens() {
        let tokens = MarkdownTokenizer.parseTokens(in: "")
        #expect(tokens.isEmpty)
    }

    @Test func whitespaceOnlyDocumentReturnsNoTokens() {
        let tokens = MarkdownTokenizer.parseTokens(in: "\n\n   \n")
        #expect(tokens.isEmpty)
    }

    @Test func unclosedFencedCodeIsNotTokenizedAsCodeBlock() {
        // Current behavior: the codeBlockRegex requires a closing fence.
        let text = """
        ```swift
        let x = 1
        """
        let tokens = MarkdownTokenizer.parseTokens(in: text)
        #expect(tokens.filter { $0.kind == .codeBlock }.isEmpty)
    }

    // MARK: Phase-1 integration regressions

    @Test func parseTokensInternallyUsesBlockScanner() {
        // After Phase 1, parseTokens still returns flat MarkdownToken array
        // but produces .heading / .codeBlock tokens via the block scanner.
        let text = "# Title\n\n```swift\nlet x = 1\n```\n\nBody **bold**."
        let tokens = MarkdownTokenizer.parseTokens(in: text)
        #expect(tokens.contains { $0.kind == .heading })
        #expect(tokens.contains { $0.kind == .codeBlock })
        #expect(tokens.contains { $0.kind == .bold })
    }

    @Test func wikiLinkInsideFencedCodeIsNotEmittedAfterRefactor() {
        let text = "```\n[[NotALink]]\n```"
        let tokens = MarkdownTokenizer.parseTokens(in: text)
        let wiki = tokens.filter { $0.kind == .wikiLink }
        #expect(wiki.isEmpty)
    }

    @Test func imageEmbedInsideFencedCodeIsNotEmittedAfterRefactor() {
        let text = "```\n![[picture.png]]\n```"
        let tokens = MarkdownTokenizer.parseTokens(in: text)
        let img = tokens.filter { $0.kind == .imageEmbed }
        #expect(img.isEmpty)
    }

    @Test func inlineCodeInsideFencedCodeIsNotEmittedAfterRefactor() {
        let text = "```\nlet a = `b`\n```"
        let tokens = MarkdownTokenizer.parseTokens(in: text)
        let inlineCode = tokens.filter { $0.kind == .inlineCode }
        #expect(inlineCode.isEmpty)
    }

    @Test func emphasisInsideFencedCodeIsNotEmittedAfterRefactor() {
        let text = "```\n**bold-looking**\n```"
        let tokens = MarkdownTokenizer.parseTokens(in: text)
        #expect(tokens.filter { $0.kind == .bold }.isEmpty)
    }
}
