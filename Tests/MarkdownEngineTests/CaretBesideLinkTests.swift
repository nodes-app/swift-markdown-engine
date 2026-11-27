//
//  CaretBesideLinkTests.swift
//  MarkdownEngineTests
//
//  Created by Luca Chen on 27.11.26.
//

import AppKit
import SwiftUI
import Testing
@testable import MarkdownEngine

/// A plain click just beside a closed link's text lands in its hidden syntax
/// (`](url)`, `]]`, `[`), which is drawn near zero width but still in the
/// text. The caret goes where the edit zone puts it for a click on the link's
/// outer edge: just outside the markers.
@MainActor
@Suite struct CaretBesideLinkTests {
    private static let text = "Watch [School](https://youtu.be/abc) now and [[Figma]] too"
    private static let ns = text as NSString

    private static let linkStart = ns.range(of: "[School]").location
    private static let linkEnd = NSMaxRange(ns.range(of: "[School](https://youtu.be/abc)"))
    private static let linkTextEnd = NSMaxRange(ns.range(of: "School"))
    private static let wikiStart = ns.range(of: "[[Figma]]").location
    private static let wikiEnd = NSMaxRange(ns.range(of: "[[Figma]]"))
    private static let wikiTextEnd = NSMaxRange(ns.range(of: "Figma"))

    private func coordinator(rawSource: Bool = false) -> NativeTextViewCoordinator {
        let coordinator = NativeTextViewCoordinator(
            text: .constant(""),
            fontName: "SF Pro Text",
            fontSize: 14,
            isWikiLinkActive: .constant(false),
            onLinkClick: nil,
            onInlineSelectionChange: nil
        )
        var config = MarkdownEditorConfiguration.default
        config.rawSourceMode = rawSource
        coordinator.configuration = config
        return coordinator
    }

    private func outside(_ caret: Int, active: Set<Int> = [], rawSource: Bool = false) -> Int? {
        coordinator(rawSource: rawSource).caretOutsideHiddenLinkSyntax(caret, in: Self.text, activeBefore: active)
    }

    /// The reported case: the caret parked inside the hidden URL.
    @Test func aClickInAClosedLinksURLGoesAfterIt() {
        let inURL = Self.ns.range(of: "https").location + 4
        #expect(outside(inURL) == Self.linkEnd)
    }

    @Test func aClickRightAfterTheTextGoesAfterTheLink() {
        #expect(outside(Self.linkTextEnd) == Self.linkEnd)       // before ']'
        #expect(outside(Self.linkTextEnd + 1) == Self.linkEnd)   // between ']' and '('
        #expect(outside(Self.linkEnd - 1) == Self.linkEnd)       // before ')'
    }

    @Test func aClickJustBeforeTheTextGoesBeforeTheLink() {
        #expect(outside(Self.linkStart + 1) == Self.linkStart)   // between '[' and the text
    }

    @Test func wikiLinksTheSame() {
        #expect(outside(Self.wikiTextEnd) == Self.wikiEnd)       // before ']]'
        #expect(outside(Self.wikiEnd - 1) == Self.wikiEnd)       // between the two ']'
        #expect(outside(Self.wikiStart + 1) == Self.wikiStart)   // between the two '['
        #expect(outside(Self.wikiStart + 2) == Self.wikiStart)   // before the name
    }

    /// Inside the visible text, and already outside the markers, nothing moves.
    @Test func theTextAndTheOutsideAreLeftAlone() {
        #expect(outside(Self.linkTextEnd - 2) == nil)
        #expect(outside(Self.linkStart) == nil)
        #expect(outside(Self.linkEnd) == nil)
        #expect(outside(Self.wikiEnd) == nil)
        #expect(outside(2) == nil)
    }

    /// An open link shows its syntax, so a click in its URL means to edit it there.
    @Test func anOpenLinkKeepsTheCaretWhereItLands() throws {
        let tokens = coordinator().parsedDocument(for: Self.text).tokens
        let link = try #require(tokens.firstIndex { $0.kind == .link })
        let inURL = Self.ns.range(of: "https").location + 4
        #expect(outside(inURL, active: [link]) == nil)
    }

    /// Raw source mode hides no syntax: a click lands where it was aimed.
    @Test func rawSourceModeIsLeftAlone() {
        let inURL = Self.ns.range(of: "https").location + 4
        #expect(outside(inURL, rawSource: true) == nil)
    }
}
