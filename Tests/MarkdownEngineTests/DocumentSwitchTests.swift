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
                header: AnyView(Color.gray.frame(height: 60))
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
}
