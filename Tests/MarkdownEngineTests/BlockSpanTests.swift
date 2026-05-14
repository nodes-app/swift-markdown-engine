//
//  BlockSpanTests.swift
//  MarkdownEngineTests
//

import Testing
import Foundation
@testable import MarkdownEngine

@Suite("BlockSpan data model")
struct BlockSpanTests {

    @Test func leafBlockHasEmptyChildrenByDefault() {
        let span = BlockSpan(
            kind: .paragraph,
            range: NSRange(location: 0, length: 5),
            contentRange: NSRange(location: 0, length: 5),
            markerRanges: []
        )
        #expect(span.children.isEmpty)
    }

    @Test func headingKindCarriesLevel() {
        let kind: BlockKind = .heading(level: 2)
        if case .heading(let level) = kind {
            #expect(level == 2)
        } else {
            Issue.record("Expected heading kind")
        }
    }

    @Test func linkReferenceHoldsLabelUrlAndTitle() {
        let ref = LinkReference(label: "foo", url: "https://example.com", title: "Example")
        #expect(ref.label == "foo")
        #expect(ref.url == "https://example.com")
        #expect(ref.title == "Example")
    }

    @Test func linkReferenceLabelLowercasedKeyMatchesSpec() {
        // CommonMark folds label case for matching; we normalize at construction.
        let ref = LinkReference(label: "  Foo  Bar  ", url: "x")
        #expect(ref.normalizedLabel == "foo bar")
    }
}
