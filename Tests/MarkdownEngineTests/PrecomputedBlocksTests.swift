#if os(macOS)
//
//  PrecomputedBlocksTests.swift
//  MarkdownEngine
//
//  Created by Luca Chen on 12.07.26.
//
//  The per-keystroke restyle hands its already-computed block list down to
//  DocumentAST.parse so the styler consumes it verbatim instead of
//  re-extracting + memcmp'ing the full document buffer every keystroke.
//

import AppKit
import Foundation
import Testing
@testable import MarkdownEngine

@Suite("Precomputed blocks bypass the block parser")
struct PrecomputedBlocksTests {

    @Test func precomputedBlocksAreConsumedVerbatim() {
        let text = "alpha\n\nbeta"
        // Deliberately WRONG for this text: one paragraph covering only "alpha".
        // A re-parse would see two paragraphs + a blank instead.
        let bogus = [Block(kind: .paragraph, range: NSRange(location: 0, length: 6))]

        let ast = DocumentAST.parse(text, precomputedBlocks: bogus)

        #expect(ast.count == 1)
        #expect(ast.first?.range == NSRange(location: 0, length: 6))
    }

    @Test func parsedDocumentCarriesTheKeystrokesBlocks() {
        let state = DocumentParseState()
        _ = state.tokens(for: "alpha\n\nbeta", edit: nil)

        let blocks = state.currentBlocks

        #expect(blocks.count == 3)
        #expect(blocks.map(\.range).last == NSRange(location: 7, length: 4))
    }

    /// The document rebuild (open / node switch) now hands its blocks down too —
    /// unscoped, so EVERY block is styled from them. Same attributes, same order,
    /// same values as a from-scratch parse, or an open would render differently
    /// from the keystroke that follows it.
    @MainActor
    @Test func documentScopedStylingMatchesAFreshParse() {
        _ = NSApplication.shared
        let text = """
        # Heading **bold** and *italic*

        A paragraph with `inline code`, a [link](https://example.com), a [[Wiki Link]]
        and an https://autolink.example.com in it.

        > quoted **text**

        - item one
        - [ ] task
        - [x] done

        ```swift
        let x = 1
        ```

        | a | b |
        |---|---|
        | 1 | 2 |

        $$
        x^2
        $$

        ---

        trailing ~~strike~~ paragraph
        """
        let state = DocumentParseState()
        _ = state.tokens(for: text, edit: nil)
        let blocks = state.currentBlocks
        let fontName = NSFont.systemFont(ofSize: 14).fontName

        let fresh = MarkdownASTStyler.styleAttributes(text: text, fontName: fontName, fontSize: 14)
        let reused = MarkdownASTStyler.styleAttributes(text: text, fontName: fontName, fontSize: 14,
                                                       precomputedBlocks: blocks)

        #expect(!fresh.isEmpty)   // else the comparison below passes vacuously
        #expect(fresh.count == reused.count)
        for (a, b) in zip(fresh, reused) {
            #expect(a.range == b.range)
            #expect((a.attributes as NSDictionary).isEqual(to: b.attributes))
        }
    }
}
#endif
