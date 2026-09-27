//
//  CodeBlockSelectionStaleCacheTests.swift
//  MarkdownEngineTests
//
//  `updateCodeBlockSelection` cuts each block's code out of the CURRENT text
//  with ranges from `cachedCodeBlockTokens` — a cache only the typing/caret
//  delegate paths refresh. A programmatic content swap (document switch, an
//  external binding change) goes through `rebuildTextStorageAndStyle`, which
//  used to leave the cache untouched; the deferred no-`parsed` refresh in
//  `updateNSView` then indexed the new (shorter) string with the old
//  document's ranges and died in `-[NSString substringWithRange:]`.
//

import AppKit
import SwiftUI
import Testing
@testable import MarkdownEngine

@MainActor
@Suite("Code block selection survives a programmatic content swap")
struct CodeBlockSelectionStaleCacheTests {

    private func makeEditor(_ text: String) -> (NativeTextViewCoordinator, NativeTextView) {
        _ = NSApplication.shared
        let coordinator = NativeTextViewCoordinator(
            text: .constant(text), fontName: "SF Pro", fontSize: 16,
            isWikiLinkActive: .constant(false), onLinkClick: nil, onInlineSelectionChange: nil
        )
        let tv = NativeTextView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        tv.isEditable = true
        tv.delegate = coordinator
        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        scrollView.documentView = tv
        coordinator.textView = tv
        // The wrapper wires a layout bridge in makeNSView; without it,
        // `viewRect(forCharacterRange:)` bails to nil and the substring under
        // test is never reached.
        if let tlm = tv.textLayoutManager {
            let bridge = LayoutBridge(tlm)
            coordinator.layoutBridge = bridge
            tv.layoutBridge = bridge
        }
        coordinator.rebuildTextStorageAndStyle(tv, from: text)
        coordinator.lastSyncedText = text
        coordinator.lastComputedStorage = text
        coordinator.previousDisplayLength = (text as NSString).length
        return (coordinator, tv)
    }

    @Test("rebuild refreshes the token cache, so the deferred refresh reads the new document")
    func rebuildRefreshesCache() {
        let docA = "intro\n```swift\nlet alpha = 1\n```\ntrailing prose that pads the old document out well beyond the next one"
        let docB = "```python\nbeta = 2\n```\n"
        let (coordinator, tv) = makeEditor(docA)
        coordinator.updateCodeBlockSelection(textView: tv, parsed: coordinator.parsedDocument(for: docA))

        // The programmatic swap `updateNSView` performs, followed by its
        // deferred no-`parsed` refresh (closure #7 in the crash report).
        coordinator.rebuildTextStorageAndStyle(tv, from: docB)
        var received: [CodeBlockSelection]?
        coordinator.onCodeBlockSelectionChange = { received = $0 }
        coordinator.updateCodeBlockSelection(textView: tv)

        let codes = (received ?? []).map(\.code)
        #expect(codes.contains(where: { $0.contains("beta") }))
        #expect(!codes.contains(where: { $0.contains("alpha") }))
    }

    @Test("a longer replacement document is not given the old document's blocks")
    func longerReplacementDocument() {
        // The length guard only catches ranges that no longer FIT. When the
        // incoming document is LONGER, the previous document's ranges are still
        // in bounds and nothing stops them — the block is reported against text
        // that holds no code at all, with a slice of that text as its code.
        let docA = "```swift\nlet alpha = 1\n```\n"
        let docB = "This is an ordinary prose document with no code block at all. "
            + String(repeating: "More filler so it runs comfortably longer than the last one. ", count: 4)
        let (coordinator, tv) = makeEditor(docA)
        coordinator.updateCodeBlockSelection(textView: tv, parsed: coordinator.parsedDocument(for: docA))

        coordinator.rebuildTextStorageAndStyle(tv, from: docB)
        var received: [CodeBlockSelection]?
        coordinator.onCodeBlockSelectionChange = { received = $0 }
        coordinator.updateCodeBlockSelection(textView: tv)

        #expect(received?.isEmpty == true)
    }

    @Test("raw source mode reports no code blocks")
    func rawSourceModeReportsNothing() {
        // Raw mode draws no overlays. The cache used to survive the switch into
        // it, so an embedder arriving from styled mode kept its copy buttons
        // while one opening straight into raw mode never had them.
        let doc = "intro\n```swift\nlet alpha = 1\n```\nmore"
        let (coordinator, tv) = makeEditor(doc)
        coordinator.updateCodeBlockSelection(textView: tv, parsed: coordinator.parsedDocument(for: doc))

        coordinator.configuration.rawSourceMode = true
        coordinator.rebuildTextStorageAndStyle(tv, from: doc)
        var received: [CodeBlockSelection]?
        coordinator.onCodeBlockSelectionChange = { received = $0 }
        coordinator.updateCodeBlockSelection(textView: tv)

        #expect(received?.isEmpty == true)
    }

    @Test("a stale range past the end of the text is skipped, not substringed")
    func staleRangeIsSkipped() {
        let (coordinator, tv) = makeEditor("short")
        // A cache entry whose contentRange outlives the text it was parsed
        // from: block starts inside the current string, content runs past it.
        coordinator.cachedCodeBlockTokens = [(
            index: 0,
            token: MarkdownToken(
                kind: .codeBlock,
                range: NSRange(location: 0, length: 5),
                contentRange: NSRange(location: 2, length: 200),
                markerRanges: []
            )
        )]
        var received: [CodeBlockSelection]?
        coordinator.onCodeBlockSelectionChange = { received = $0 }
        coordinator.updateCodeBlockSelection(textView: tv)
        #expect(received?.isEmpty == true)
    }
}
