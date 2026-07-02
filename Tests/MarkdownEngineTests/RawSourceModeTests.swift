//
//  RawSourceModeTests.swift
//  MarkdownEngineTests
//
//  Created by Luca Chen on 02.07.26.
//
//  `rawSourceMode`: the document shows its Markdown source verbatim — no
//  wiki-link display transform (`[[Name|UUID]]` stays visible), no markdown
//  styling beyond the base attributes — and a runtime flip rebuilds between
//  the two presentations without touching the storage text. Headless.
//

import AppKit
import SwiftUI
import Testing
@testable import MarkdownEngine

@MainActor
struct RawSourceModeTests {

    private static let storage = "# Head\n**bold** [[Note|abc-123]]"

    private func makeCoordinator(raw: Bool) -> NativeTextViewCoordinator {
        let c = NativeTextViewCoordinator(
            text: .constant(""), fontName: "SF Pro", fontSize: 16,
            isWikiLinkActive: .constant(false), onLinkClick: nil, onInlineSelectionChange: nil
        )
        c.configuration.rawSourceMode = raw
        return c
    }

    /// Every (font, link) run in the text view's storage.
    private func attributeRuns(_ tv: NSTextView) -> [(font: NSFont?, link: Any?)] {
        guard let storage = tv.textStorage else { return [] }
        var runs: [(NSFont?, Any?)] = []
        storage.enumerateAttributes(in: NSRange(location: 0, length: storage.length)) { attrs, _, _ in
            runs.append((attrs[.font] as? NSFont, attrs[.link]))
        }
        return runs
    }

    @Test("Raw rebuild shows storage verbatim with base attributes only")
    func rawRebuildIsVerbatimAndUnstyled() {
        let c = makeCoordinator(raw: true)
        let tv = NativeTextView(frame: .zero)
        c.rebuildTextStorageAndStyle(tv, from: Self.storage)

        #expect(tv.string == Self.storage) // UUID visible, markers untouched
        let runs = attributeRuns(tv)
        #expect(!runs.isEmpty)
        #expect(runs.allSatisfy { $0.link == nil })
        #expect(runs.allSatisfy { $0.font?.pointSize == 16 }) // no heading scale
    }

    @Test("Rendered rebuild transforms display; flipping to raw restores verbatim source")
    func runtimeFlipRebuildsPresentation() {
        let c = makeCoordinator(raw: false)
        let tv = NativeTextView(frame: .zero)
        c.rebuildTextStorageAndStyle(tv, from: Self.storage)
        #expect(tv.string == "# Head\n**bold** [[Note]]") // display hides |UUID

        c.configuration.rawSourceMode = true
        c.rebuildTextStorageAndStyle(tv, from: Self.storage)
        #expect(tv.string == Self.storage)

        c.configuration.rawSourceMode = false
        c.rebuildTextStorageAndStyle(tv, from: Self.storage)
        #expect(tv.string == "# Head\n**bold** [[Note]]")
    }

    @Test("restyleTextView is a no-op while raw")
    func restyleDoesNotStyleWhileRaw() {
        let c = makeCoordinator(raw: true)
        let tv = NativeTextView(frame: .zero)
        c.rebuildTextStorageAndStyle(tv, from: Self.storage)

        let full = NSRange(location: 0, length: (tv.string as NSString).length)
        c.restyleTextView(tv, paragraphCandidates: [full])

        let runs = attributeRuns(tv)
        #expect(runs.allSatisfy { $0.link == nil })
        #expect(runs.allSatisfy { $0.font?.pointSize == 16 })
    }
}
