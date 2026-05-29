//
//  DocumentASTTests.swift
//  MarkdownEngineTests
//
//  Phase 2.5a — the semantic document AST: blocks carrying parsed inline
//  children in absolute coordinates.
//

import Foundation
import Testing
@testable import MarkdownEngine

@Suite("Phase 2.5a — document AST")
struct DocumentASTTests {

    private func r(_ location: Int, _ length: Int) -> NSRange {
        NSRange(location: location, length: length)
    }

    @Test("paragraph carries its inline children")
    func paragraph() {
        #expect(DocumentAST.parse("a *b*") == [
            .paragraph(range: r(0, 5), inlines: [
                .text(r(0, 2)),
                .emphasis(.italic, range: r(2, 3), markers: [r(2, 1), r(4, 1)], children: [.text(r(3, 1))]),
            ]),
        ])
    }

    @Test("heading carries level, markers and nested inline children")
    func headingWithNestedInlines() {
        #expect(DocumentAST.parse("# **n*o*des**") == [
            .heading(level: 1, range: r(0, 13), markers: [r(0, 1)], inlines: [
                .emphasis(.bold, range: r(2, 11), markers: [r(2, 2), r(11, 2)], children: [
                    .text(r(4, 1)),
                    .emphasis(.italic, range: r(5, 3), markers: [r(5, 1), r(7, 1)], children: [.text(r(6, 1))]),
                    .text(r(8, 3)),
                ]),
            ]),
        ])
    }

    @Test("blocks tile the document with the right kinds")
    func mixedDocument() {
        #expect(DocumentAST.parse("# H\n\n```\nx\n```\n") == [
            .heading(level: 1, range: r(0, 4), markers: [r(0, 1)], inlines: [.text(r(2, 1))]),
            .blank(range: r(4, 1)),
            .codeBlock(range: r(5, 10)),
        ])
    }
}
