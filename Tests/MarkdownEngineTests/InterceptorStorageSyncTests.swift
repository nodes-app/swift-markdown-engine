#if os(macOS)
//
//  InterceptorStorageSyncTests.swift
//  MarkdownEngine
//
//  Created by Luca Chen on 11.07.26.
//
//  Regression: smart-input interceptors suppress the typed keystroke and
//  perform a different programmatic edit. The incremental wiki splice must
//  see THAT edit's descriptor — with the suppressed keystroke's stale one it
//  silently diverged the storage form (and the persisted file) from the
//  display text.
//

import AppKit
import SwiftUI
import Testing
@testable import MarkdownEngine

@MainActor
@Suite("Interceptor edits keep the storage form in sync")
struct InterceptorStorageSyncTests {

    /// Editor wired like production: coordinator as delegate, storage-sync
    /// state seeded as rebuildTextStorageAndStyle would.
    private func makeEditor(text: String) -> (NativeTextView, NativeTextViewCoordinator) {
        _ = NSApplication.shared   // selection-change path reads NSApp.currentEvent
        let textView = NativeTextView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        textView.isEditable = true
        textView.configuration = .default
        let coordinator = NativeTextViewCoordinator(
            text: .constant(text),
            fontName: "SF Pro Text",
            fontSize: 14,
            isWikiLinkActive: .constant(false),
            onLinkClick: nil,
            onInlineSelectionChange: nil
        )
        coordinator.textView = textView
        textView.delegate = coordinator
        textView.string = text
        coordinator.lastSyncedText = text
        coordinator.lastComputedStorage = text
        coordinator.previousDisplayLength = (text as NSString).length
        return (textView, coordinator)
    }

    // "->" arrow substitution: same length delta, different location — the
    // stale descriptor made the splice an identity op that kept "- " forever.
    @Test func arrowSubstitutionSyncsStorage() {
        let (tv, coord) = makeEditor(text: "abc - def")
        tv.setSelectedRange(NSRange(location: 5, length: 0))   // right after "-"

        tv.insertText(">", replacementRange: NSRange(location: 5, length: 0))

        #expect(tv.string == "abc → def")
        #expect(coord.lastComputedStorage == "abc → def")
    }

    // Tab list-indent: the edit lands at the line start, not at the caret the
    // suppressed keystroke described.
    @Test func tabIndentSyncsStorage() {
        let (tv, coord) = makeEditor(text: "- hello")
        tv.setSelectedRange(NSRange(location: 7, length: 0))   // end of the item

        tv.insertText("\t", replacementRange: NSRange(location: 7, length: 0))

        #expect(tv.string == "\t- hello")
        #expect(coord.lastComputedStorage == "\t- hello")
    }
}
#endif
