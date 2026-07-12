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
}
