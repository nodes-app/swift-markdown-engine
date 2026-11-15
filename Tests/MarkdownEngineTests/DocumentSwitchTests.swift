//
//  DocumentSwitchTests.swift
//  MarkdownEngineTests
//
//  A switch to a document whose text equals the open one's (two empty notes)
//  was skipped as "nothing changed": the coordinator kept the old documentId
//  for the editor's life, so every pass re-armed the header's switch snap
//  (⌘I lost its animation) and undo kept filing edits under the old document.
//

import AppKit
import SwiftUI
import Testing
@testable import MarkdownEngine

@MainActor
@Suite("Document switch", .serialized)
struct DocumentSwitchTests {

    private final class Document: ObservableObject {
        @Published var id: String
        @Published var text: String
        @Published var openDocuments: Set<String>?
        init(id: String, text: String) {
            self.id = id
            self.text = text
        }
    }

    private struct Host: View {
        @ObservedObject var document: Document
        var body: some View {
            NativeTextViewWrapper(
                text: $document.text,
                documentId: document.id,
                header: AnyView(Color.gray.frame(height: 60)),
                retainedScrollDocumentIds: document.openDocuments
            )
        }
    }

    /// AppKit can still be working on a window after the test returns; keep them alive.
    private static var windows: [NSWindow] = []

    private static func findTextView(_ root: NSView) -> NativeTextView? {
        if let sv = root as? NSScrollView, let tv = sv.nativeTextView { return tv }
        for sub in root.subviews {
            if let found = findTextView(sub) { return found }
        }
        return nil
    }

    /// Hands the main queue back between run-loop slices: the editor syncs through it.
    private static func spin(_ seconds: TimeInterval) async {
        let deadline = Date(timeIntervalSinceNow: seconds)
        while Date() < deadline {
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.01))
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
    }

    private static func stage(_ document: Document) async throws -> (NativeTextView, NativeTextViewCoordinator) {
        _ = NSApplication.shared
        let window = NSWindow(
            contentRect: NSRect(x: -30000, y: -30000, width: 900, height: 600),
            styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: Host(document: document))
        window.orderFrontRegardless()
        windows.append(window)
        await spin(0.4)
        let tv = try #require(findTextView(window.contentView!))
        let coordinator = try #require(tv.delegate as? NativeTextViewCoordinator)
        return (tv, coordinator)
    }

    @Test("switching between two empty documents completes", arguments: ["", "Same words in both notes."])
    func identicalTextStillSwitches(text: String) async throws {
        let document = Document(id: "A", text: text)
        let (tv, coordinator) = try await Self.stage(document)
        #expect(coordinator.documentId == "A")

        document.id = "B"
        await Self.spin(0.3)
        #expect(coordinator.documentId == "B", "the editor must follow the switch even when the text is the same")
        #expect(tv.string == text)

        // Undo now belongs to B: an edit there lands on B's stack, never on A's.
        tv.insertText("x", replacementRange: NSRange(location: (tv.string as NSString).length, length: 0))
        await Self.spin(0.1)
        #expect(coordinator.undoManagers["B"]?.canUndo == true)
        #expect(coordinator.undoManagers["A"]?.canUndo != true)
    }

    /// Nodes' tabs replace their file in place, so the file left behind is no
    /// longer among the embedder's open documents. Its undo stack used to be
    /// pruned with that set, and ⌘Z did nothing on the way back.
    @Test("undo survives a tab switching to another file and back")
    func undoSurvivesReplacedTab() async throws {
        let document = Document(id: "A", text: "Alpha")
        document.openDocuments = ["A"]
        let (tv, coordinator) = try await Self.stage(document)

        tv.insertText(" typed", replacementRange: NSRange(location: 5, length: 0))
        await Self.spin(0.3)
        #expect(coordinator.undoManagers["A"]?.canUndo == true)
        #expect(document.text == "Alpha typed")

        // The tab shows B now; A is open nowhere.
        document.openDocuments = ["B"]
        document.id = "B"
        document.text = "Beta"
        await Self.spin(0.3)
        #expect(coordinator.documentId == "B")

        // Back to A, its file as it was saved.
        document.openDocuments = ["A"]
        document.id = "A"
        document.text = "Alpha typed"
        await Self.spin(0.3)
        let undo = try #require(coordinator.undoManagers["A"])
        #expect(undo.canUndo)
        undo.undo()
        await Self.spin(0.2)
        #expect(tv.string == "Alpha")
    }

    /// Nodes switches in two passes: the new documentId first, still with the
    /// outgoing text, the new file's text one pass later.
    private static func switchInTwoPasses(_ document: Document, to id: String, text: String) async {
        document.id = id
        await spin(0.3)
        document.text = text
        await spin(0.3)
    }

    /// A switch completes on its first pass (#212), which still carries the outgoing
    /// document's text: a staleness check there saw a "rewritten" file and cleared
    /// the stack on every switch back. Staleness is judged when the stack is used.
    @Test("undo survives a switch whose text arrives one pass after its id")
    func undoSurvivesTwoPassSwitch() async throws {
        let document = Document(id: "A", text: "Alpha")
        let (tv, coordinator) = try await Self.stage(document)
        tv.insertText(" typed", replacementRange: NSRange(location: 5, length: 0))
        await Self.spin(0.3)
        #expect(document.text == "Alpha typed")

        await Self.switchInTwoPasses(document, to: "B", text: "Beta")
        #expect(tv.string == "Beta")
        await Self.switchInTwoPasses(document, to: "A", text: "Alpha typed")
        #expect(tv.string == "Alpha typed")

        let undo = try #require(coordinator.undoManagers["A"])
        #expect(undo.canUndo)
        undo.undo()
        await Self.spin(0.2)
        #expect(tv.string == "Alpha")
    }

    @Test("a file rewritten while switched away still drops its stack, two passes or not")
    func rewriteStillDropsStack() async throws {
        let document = Document(id: "A", text: "Alpha")
        let (tv, coordinator) = try await Self.stage(document)
        tv.insertText(" typed", replacementRange: NSRange(location: 5, length: 0))
        await Self.spin(0.3)

        await Self.switchInTwoPasses(document, to: "B", text: "Beta")
        await Self.switchInTwoPasses(document, to: "A", text: "Alpha rewritten elsewhere")
        #expect(tv.string == "Alpha rewritten elsewhere")
        // Judged when the stack is used, not at the switch (whose first pass can
        // carry any text).
        tv.undo(nil)
        await Self.spin(0.2)
        #expect(tv.string == "Alpha rewritten elsewhere",
                "stale ranges would replay over text they were not recorded on")
        #expect(coordinator.undoManagers["A"]?.canUndo != true)
    }

    /// A rebuild leaves the caret at the end of the text, so a switch back used to
    /// put the next keystroke there, far from where the reader had been typing.
    @Test("the caret comes back with its document")
    func caretComesBack() async throws {
        let document = Document(id: "A", text: "Alpha, a line long enough to hold a caret somewhere in the middle.")
        let (tv, _) = try await Self.stage(document)
        tv.setSelectedRange(NSRange(location: 12, length: 4))
        await Self.spin(0.2)

        await Self.switchInTwoPasses(document, to: "B", text: "Beta")
        await Self.switchInTwoPasses(document, to: "A", text: "Alpha, a line long enough to hold a caret somewhere in the middle.")

        #expect(tv.selectedRange() == NSRange(location: 12, length: 4))
    }

    @Test("a document rewritten while switched away gets no caret from the old text")
    func caretIsNotPutIntoOtherText() async throws {
        let document = Document(id: "A", text: "Alpha, a line long enough to hold a caret somewhere in the middle.")
        let (tv, _) = try await Self.stage(document)
        tv.setSelectedRange(NSRange(location: 12, length: 4))
        await Self.spin(0.2)

        await Self.switchInTwoPasses(document, to: "B", text: "Beta")
        await Self.switchInTwoPasses(document, to: "A", text: "Rewritten elsewhere, and long enough that the old range would still fit in it.")

        #expect(tv.selectedRange() != NSRange(location: 12, length: 4))
    }

    /// The switch's first pass carries the new id with the previous document's
    /// text. The restore was clamped against THAT text and then gave up because
    /// "the text is not empty", so nothing was armed when the document arrived
    /// (measured in Nodes: want 5504, the other note allowed 1559, stayed there).
    @Test("back from a shorter document, the reader is where they were")
    func scrollComesBackFromAShorterDocument() async throws {
        let long = (1...200).map { "Line \($0) of a long document." }.joined(separator: "\n\n")
        let document = Document(id: "A", text: long)
        let (tv, coordinator) = try await Self.stage(document)
        let scrollView = try #require(tv.enclosingScrollView)
        scrollView.contentView.scroll(to: NSPoint(x: 0, y: 3000))
        scrollView.reflectScrolledClipView(scrollView.contentView)
        await Self.spin(0.3)

        await Self.switchInTwoPasses(document, to: "B", text: "Beta, a short note.")
        await Self.switchInTwoPasses(document, to: "A", text: long)

        #expect(abs(scrollView.contentView.bounds.origin.y - 3000) < 1)
        #expect(coordinator.pendingScrollRestoreDocumentId == nil, "nothing stays armed once it landed")
    }
}
