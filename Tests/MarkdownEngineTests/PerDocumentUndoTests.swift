//
//  PerDocumentUndoTests.swift
//  MarkdownEngineTests
//
//  Per-`documentId` undo: a stable manager per document (Cmd+Z survives file
//  switches) and dropping a stale stack when the document's text was rewritten
//  while it was switched away. Headless.
//

import AppKit
import SwiftUI
import Testing
@testable import MarkdownEngine

@MainActor
struct PerDocumentUndoTests {

    private func makeCoordinator() -> NativeTextViewCoordinator {
        NativeTextViewCoordinator(
            text: .constant(""), fontName: "SF Pro", fontSize: 16,
            isWikiLinkActive: .constant(false), onLinkClick: nil, onInlineSelectionChange: nil
        )
    }

    /// UndoManager with one registered action, so `canUndo` is deterministically true.
    private func populatedManager() -> UndoManager {
        let target = NSObject()
        let m = UndoManager()
        m.groupsByEvent = false
        m.beginUndoGrouping()
        m.registerUndo(withTarget: target) { _ in }
        m.endUndoGrouping()
        return m
    }

    @Test("Stable manager per document; distinct across; original returned on switch-back")
    func vendsStablePerDocumentManager() {
        let c = makeCoordinator()
        let tv = NativeTextView(frame: .zero)
        c.documentId = "A"
        let a = c.undoManager(for: tv)
        #expect(c.undoManager(for: tv) === a)
        c.documentId = "B"
        #expect(c.undoManager(for: tv) !== a)
        c.documentId = "A"
        #expect(c.undoManager(for: tv) === a)
    }

    @Test("Undo stack dropped only when the reloaded text diverged from the snapshot")
    func invalidatesOnlyOnDivergedContent() {
        let c = makeCoordinator()
        let m = populatedManager()
        c.undoManagers["A"] = m
        c.undoContentSnapshots["A"] = "hello"
        #expect(c.invalidateUndoIfContentDiverged(for: "A", incomingText: "hello") == false)
        #expect(m.canUndo) // unchanged → kept
        #expect(c.invalidateUndoIfContentDiverged(for: "A", incomingText: "hello world") == true)
        #expect(!m.canUndo) // diverged → dropped
    }

    @Test("No snapshot (first visit) never clears")
    func noSnapshotNeverClears() {
        let c = makeCoordinator()
        c.undoManagers["A"] = populatedManager()
        #expect(c.invalidateUndoIfContentDiverged(for: "A", incomingText: "x") == false)
    }
}
