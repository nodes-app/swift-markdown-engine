//
//  WritingToolsIgnoredRangesTests.swift
//  MarkdownEngineTests
//
//  Created by Luca Chen on 18.10.26.
//

import AppKit
import SwiftUI
import Testing
@testable import MarkdownEngine

@MainActor
@Suite("Writing Tools ignored ranges")
struct WritingToolsIgnoredRangesTests {
    private static let text = """
    Fix this sentence, run `brew install foo` and see $e=mc^2$.

    ```
    let x = 1
    ```

    Read [[Some Note]], the [docs](https://example.com) and ![chart](chart.png).
    """

    private func ignored(in range: NSRange? = nil) -> [String] {
        let coordinator = NativeTextViewCoordinator(
            text: .constant(Self.text), fontName: "SF Pro", fontSize: 16,
            isWikiLinkActive: .constant(false), onLinkClick: nil, onInlineSelectionChange: nil
        )
        let textView = NativeTextView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        textView.string = Self.text
        let ns = Self.text as NSString
        guard #available(macOS 15.0, *) else { return [] }
        return coordinator.textView(textView, writingToolsIgnoredRangesInEnclosingRange: range ?? NSRange(location: 0, length: ns.length))
            .map { ns.substring(with: $0.rangeValue) }
    }

    @Test func codeFormulasAndLinksAreKeptAndProseIsNot() {
        let kept = ignored()
        #expect(kept == ["`brew install foo`", "$e=mc^2$", "```\nlet x = 1\n```", "[[Some Note]]",
                         "[docs](https://example.com)", "![chart](chart.png)"])
    }

    @Test func rangesAreClippedToTheEnclosingRange() {
        let ns = Self.text as NSString
        let start = ns.range(of: "install").location
        #expect(ignored(in: NSRange(location: start, length: 20)) == ["install foo`"])
    }
}
