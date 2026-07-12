//
//  PrecomputedBlocksTests.swift
//  MarkdownEngine
//
//  Created by Luca Chen on 12.07.26.
//
//  The per-keystroke restyle hands its already-computed block list down to
//  DocumentAST.parse — the styler must consume it verbatim instead of
//  re-deriving blocks (which re-extracted + memcmp'd the full document
//  buffer on every keystroke, even on cache hits).
//

import Foundation
import Testing
@testable import MarkdownEngine

@Suite("Precomputed blocks bypass the block parser")
struct PrecomputedBlocksTests {

    @Test func precomputedBlocksAreConsumedVerbatim() {
        let text = "alpha\n\nbeta"
        // Deliberately WRONG for this text: one paragraph covering only "alpha".
        // If the styler re-parsed, it would see two paragraphs + a blank.
        let bogus = [Block(kind: .paragraph, range: NSRange(location: 0, length: 6))]

        let ast = DocumentAST.parse(text, precomputedBlocks: bogus)

        #expect(ast.count == 1)
        #expect(ast.first?.range == NSRange(location: 0, length: 6))
    }

    @Test func withoutPrecomputedBlocksTheParserRuns() {
        let text = "alpha\n\nbeta"

        let ast = DocumentAST.parse(text)

        // Real structure: paragraph, blank, paragraph.
        #expect(ast.count == 3)
    }

    @Test func parsedDocumentCarriesTheKeystrokesBlocks() {
        let state = DocumentParseState()
        let text = "alpha\n\nbeta"
        _ = state.tokens(for: text, edit: nil)

        let blocks = state.currentBlocks

        #expect(blocks.count == 3)
        #expect(blocks.map(\.range).last == NSRange(location: 7, length: 4))
    }
}
