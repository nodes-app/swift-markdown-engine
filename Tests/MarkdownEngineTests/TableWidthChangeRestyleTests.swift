#if os(macOS)
//
//  TableWidthChangeRestyleTests.swift
//  MarkdownEngine
//

import AppKit
import Foundation
import Testing
@testable import MarkdownEngine

@Suite("Table width-change restyling")
struct TableWidthChangeRestyleTests {

    @Test("Initially narrow tables stamp their paragraph for width-change restyling")
    func narrowTableStampsWidthChangeRange() throws {
        _ = NSApplication.shared
        let text = "| a | b |\n|---|---|\n| 1 | 2 |"
        let nsText = text as NSString
        let tokens = MarkdownTokenizer.parseTokensViaAST(in: text)
        let tableToken = try #require(tokens.first { $0.kind == .table })
        let font = NSFont.systemFont(ofSize: 15)
        let context = MarkdownStyler.StylingContext(
            nsText: nsText,
            tokens: tokens,
            codeTokens: [],
            activeTokenIndices: [],
            baseFont: font,
            layoutBridge: nil,
            baseDefaultLineHeight: 18,
            codeBackgroundColor: .windowBackgroundColor,
            latexMarkerFont: font,
            configuration: .default,
            wikiLinkIDProvider: { _ in nil }
        )

        let attributes = MarkdownStyler.styleTables(context)
        let stampedAnchor = try #require(attributes.first {
            $0.attributes[.scrollableBlockFullRange] != nil
        })

        #expect(stampedAnchor.range.length == 1)
        #expect(stampedAnchor.attributes[.scrollableBlockNaturalWidth] == nil)
        let stampedRange = try #require(
            stampedAnchor.attributes[.scrollableBlockFullRange] as? NSValue
        ).rangeValue
        #expect(stampedRange == nsText.paragraphRange(for: tableToken.range))
    }
}
#endif
