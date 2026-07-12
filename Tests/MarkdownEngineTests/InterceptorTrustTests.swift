//
//  InterceptorTrustTests.swift
//  MarkdownEngine
//
//  Created by Luca Chen on 12.07.26.
//
//  A smart-input interceptor suppresses the typed key and performs one
//  programmatic edit; the keystroke must stay TRUSTED (single tracked edit)
//  so textDidChange keeps the O(edit) fast paths instead of the O(doc)
//  fallback. Storage correctness on these paths is covered by
//  InterceptorStorageSyncTests; here we pin the trust flag.
//

import AppKit
import SwiftUI
import Testing
@testable import MarkdownEngine

@MainActor
@Suite("Interceptor edits keep the fast paths trusted")
struct InterceptorTrustTests {

    private func makeEditor(text: String) -> (NativeTextView, NativeTextViewCoordinator) {
        _ = NSApplication.shared
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

    @Test func plainTypingIsTrusted() {
        let (tv, coord) = makeEditor(text: "hello")
        tv.setSelectedRange(NSRange(location: 5, length: 0))

        tv.insertText("x", replacementRange: NSRange(location: 5, length: 0))

        #expect(tv.string == "hellox")
        #expect(coord.debugLastEditWasTrusted == true)
    }

    @Test func arrowSubstitutionStaysTrusted() {
        let (tv, coord) = makeEditor(text: "abc - def")
        tv.setSelectedRange(NSRange(location: 5, length: 0))

        tv.insertText(">", replacementRange: NSRange(location: 5, length: 0))

        #expect(tv.string == "abc → def")
        #expect(coord.lastComputedStorage == "abc → def")
        #expect(coord.debugLastEditWasTrusted == true)
    }
}
