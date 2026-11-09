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

    @Test("The most recent documents keep their stacks; the least recent goes first")
    func keepsMostRecentStacks() {
        let c = makeCoordinator()
        let limit = NativeTextViewCoordinator.undoRetainedDocumentCount
        let managers = (0...limit).map { _ in populatedManager() }
        for (i, manager) in managers.enumerated() {
            c.undoManagers["doc\(i)"] = manager
            c.undoContentSnapshots["doc\(i)"] = "text \(i)"
        }
        for i in 0..<limit { c.retainUndo(for: "doc\(i)") }
        c.retainUndo(for: "doc0")          // back to the first: now the most recent
        c.retainUndo(for: "doc\(limit)")   // one too many: doc1 is the least recent

        #expect(c.undoManagers["doc0"] === managers[0])
        #expect(managers[0].canUndo)
        #expect(c.undoContentSnapshots["doc0"] == "text 0")
        #expect(c.undoManagers["doc1"] == nil)
        #expect(c.undoContentSnapshots["doc1"] == nil)
        #expect(!managers[1].canUndo, "an evicted stack is cleared, not just forgotten")
        #expect(c.undoRecency.count == limit)
    }

    @Test("No snapshot (first visit) never clears")
    func noSnapshotNeverClears() {
        let c = makeCoordinator()
        c.undoManagers["A"] = populatedManager()
        #expect(c.invalidateUndoIfContentDiverged(for: "A", incomingText: "x") == false)
    }
}
