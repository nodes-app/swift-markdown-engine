//
//  EditorParkingTests.swift
//  MarkdownEngineTests
//
//  `parkingKey`: an editor removed from the hierarchy (Nodes routing to Home, a
//  tag page or an empty tab) is kept and comes back, so ⌘Z still has its
//  history. AppKit's undo actions belong to the text view instance, so nothing
//  short of the same view keeps them.
//

import AppKit
import SwiftUI
import Testing
@testable import MarkdownEngine

@MainActor
@Suite("Editor parking", .serialized)
struct EditorParkingTests {

    private final class Document: ObservableObject {
        @Published var id: String
        @Published var text: String
        init(id: String, text: String) {
            self.id = id
            self.text = text
        }
    }

    /// What the embedder shows: the editor for `document`, or another screen.
    private final class Route: ObservableObject {
        @Published var showsEditor = true
        @Published var document: Document
        init(_ document: Document) { self.document = document }
    }

    private struct EditorHost: View {
        @ObservedObject var document: Document
        let parkingKey: String?
        var body: some View {
            NativeTextViewWrapper(text: $document.text, documentId: document.id, parkingKey: parkingKey)
        }
    }

    private struct Host: View {
        @ObservedObject var route: Route
        let parkingKey: String?
        var body: some View {
            if route.showsEditor {
                EditorHost(document: route.document, parkingKey: parkingKey)
            } else {
                Color.gray
            }
        }
    }

    private static var windows: [NSWindow] = []

    private static func findTextView(_ root: NSView) -> NativeTextView? {
        if let sv = root as? NSScrollView, let tv = sv.nativeTextView { return tv }
        for sub in root.subviews {
            if let found = findTextView(sub) { return found }
        }
        return nil
    }

    private static func spin(_ seconds: TimeInterval) async {
        let deadline = Date(timeIntervalSinceNow: seconds)
        while Date() < deadline {
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.01))
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
    }

    private static func stage<V: View>(_ view: V) async -> NSWindow {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: -30000, y: -30000, width: 700, height: 400),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: view)
        window.orderFrontRegardless()
        windows.append(window)
        await spin(0.4)
        return window
    }

    private static func key() -> String { "parking-test-\(UUID().uuidString)" }

    /// Edit "Alpha" into "Alpha typed" in a staged editor; returns its text view.
    private static func typeIntoAlpha(_ window: NSWindow) async throws -> NativeTextView {
        let tv = try #require(findTextView(window.contentView!))
        tv.insertText(" typed", replacementRange: NSRange(location: 5, length: 0))
        await spin(0.3)
        return tv
    }

    /// Route back to the editor the way Nodes does: a new view whose buffer starts
    /// empty and is filled from the file one pass later.
    private static func returnToEditor(_ route: Route, id: String, fileText: String) async -> Document {
        let reopened = Document(id: id, text: "")
        route.document = reopened
        route.showsEditor = true
        await spin(0.3)
        reopened.text = fileText
        await spin(0.3)
        return reopened
    }

    @Test("the editor comes back with its undo, and writes to the new view's binding")
    func editorAndUndoComeBack() async throws {
        let route = Route(Document(id: "A", text: "Alpha"))
        let window = await Self.stage(Host(route: route, parkingKey: Self.key()))
        let before = try await Self.typeIntoAlpha(window)
        let original = route.document
        #expect(original.text == "Alpha typed")

        route.showsEditor = false
        await Self.spin(0.3)
        #expect(Self.findTextView(window.contentView!) == nil)

        let reopened = await Self.returnToEditor(route, id: "A", fileText: "Alpha typed")
        let after = try #require(Self.findTextView(window.contentView!))
        #expect(after === before, "the parked text view itself comes back")
        #expect(after.string == "Alpha typed")

        after.undo(nil)
        await Self.spin(0.3)
        #expect(after.string == "Alpha")

        // The removed view's binding is dead: text written there is lost. (Typing, not
        // the undo, is what syncs here: without a key window TextKit 2's undo posts
        // no text change, which the app's window does.)
        after.insertText("!", replacementRange: NSRange(location: 5, length: 0))
        await Self.spin(0.3)
        #expect(reopened.text == "Alpha!", "the edit reached the new view's binding")
        #expect(original.text == "Alpha typed", "nothing went to the removed view's binding")
    }

    @Test("a file rewritten while parked: ⌘Z clears the stack instead of replaying it")
    func rewriteWhileParkedClearsUndo() async throws {
        let route = Route(Document(id: "A", text: "Alpha"))
        let window = await Self.stage(Host(route: route, parkingKey: Self.key()))
        _ = try await Self.typeIntoAlpha(window)

        route.showsEditor = false
        await Self.spin(0.3)
        _ = await Self.returnToEditor(route, id: "A", fileText: "Rewritten elsewhere")
        let tv = try #require(Self.findTextView(window.contentView!))
        #expect(tv.string == "Rewritten elsewhere")

        tv.undo(nil)
        await Self.spin(0.2)
        #expect(tv.string == "Rewritten elsewhere", "stale ranges must not replay over other text")
        #expect(tv.undoManager?.canUndo == false)
    }

    @Test("without a key a removal builds a new editor, as before")
    func noKeyBuildsNewEditor() async throws {
        let route = Route(Document(id: "A", text: "Alpha"))
        let window = await Self.stage(Host(route: route, parkingKey: nil))
        let before = try await Self.typeIntoAlpha(window)

        route.showsEditor = false
        await Self.spin(0.3)
        _ = await Self.returnToEditor(route, id: "A", fileText: "Alpha typed")
        let after = try #require(Self.findTextView(window.contentView!))
        #expect(after !== before)
        #expect(after.undoManager?.canUndo != true)
    }

    @Test("while another editor with the key is up, a removed one is not kept")
    func secondMountedEditorPreventsParking() async throws {
        let key = Self.key()
        let left = Route(Document(id: "L", text: "Left"))
        let right = Route(Document(id: "R", text: "Right"))
        let window = await Self.stage(HStack {
            Host(route: left, parkingKey: key)
            Host(route: right, parkingKey: key)
        })
        _ = window

        left.showsEditor = false
        await Self.spin(0.3)
        #expect(EditorParking.parked[key] == nil, "the right editor is still up")

        right.showsEditor = false
        await Self.spin(0.3)
        #expect(EditorParking.parked[key] != nil)
        #expect(EditorParking.parked[key]?.coordinator.documentId == "R")
    }

    @Test("back on another document, then a two-pass switch: the first one's undo is kept")
    func comeBackOnAnotherDocument() async throws {
        let route = Route(Document(id: "A", text: "Alpha"))
        let window = await Self.stage(Host(route: route, parkingKey: Self.key()))
        let before = try await Self.typeIntoAlpha(window)

        route.showsEditor = false
        await Self.spin(0.3)
        let b = await Self.returnToEditor(route, id: "B", fileText: "Beta")
        let tv = try #require(Self.findTextView(window.contentView!))
        #expect(tv === before)
        #expect(tv.string == "Beta")

        // Nodes switches in two passes: the id first, the file one pass later.
        b.id = "A"
        await Self.spin(0.3)
        b.text = "Alpha typed"
        await Self.spin(0.3)
        #expect(tv.string == "Alpha typed")

        tv.undo(nil)
        await Self.spin(0.3)
        #expect(tv.string == "Alpha")
    }
}
