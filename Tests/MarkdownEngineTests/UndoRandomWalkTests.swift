//
//  UndoRandomWalkTests.swift
//  MarkdownEngineTests
//
//  Created by Luca Chen on 10.11.26.
//
//  ⌘Z across everything an embedder does to the editor, in random order: typing,
//  undo, a two-pass document switch, routing away (parking) and back onto any
//  document, a reload of the shown document and a file rewritten while it is not
//  shown. Checked against a model of what undo is meant to do: step back through
//  this document's own edits, or do nothing and drop the history when the text is
//  no longer the one it was recorded on. Never anything else.
//
//  The seeds are ones the engine failed before the switch stopped judging
//  staleness (undo lost on the way back from a removal).
//

import AppKit
import SwiftUI
import Testing
@testable import MarkdownEngine

@MainActor
@Suite("Undo: random walks", .serialized)
struct UndoRandomWalkTests {

    private final class Document: ObservableObject {
        @Published var id: String
        @Published var text: String
        init(id: String, text: String) {
            self.id = id
            self.text = text
        }
    }

    private final class Route: ObservableObject {
        @Published var showsEditor = true
        @Published var document: Document
        init(_ document: Document) { self.document = document }
    }

    private struct EditorHost: View {
        @ObservedObject var document: Document
        let parkingKey: String
        var body: some View {
            NativeTextViewWrapper(text: $document.text, documentId: document.id, parkingKey: parkingKey)
        }
    }

    private struct Host: View {
        @ObservedObject var route: Route
        let parkingKey: String
        var body: some View {
            if route.showsEditor {
                EditorHost(document: route.document, parkingKey: parkingKey)
            } else {
                Color.gray
            }
        }
    }

    private struct Generator {
        var state: UInt64
        mutating func next(below bound: Int) -> Int {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Int((state >> 33) % UInt64(bound))
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

    @Test("undo steps back through the document's own edits or does nothing", arguments: [1, 6])
    func randomWalk(seed: Int) async throws {
        var random = Generator(state: UInt64(seed) &* 0x9E3779B97F4A7C15)
        let ids = ["D0", "D1", "D2", "D3"]
        // What the embedder would load for each document.
        var file: [String: String] = [:]
        for id in ids { file[id] = "Start of \(id). Some words here to edit." }
        // The model: the texts ⌘Z steps back through, and the text they were recorded on.
        var history: [String: [String]] = [:]
        var recordedOn: [String: String] = [:]
        func dropHistoryIfReplaced(_ id: String, shown: String) {
            if let recorded = recordedOn[id], recorded != shown { history[id] = [] }
        }

        var document = Document(id: "D0", text: file["D0"]!)
        let route = Route(document)
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: -30000, y: -30000, width: 700, height: 400),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: Host(route: route, parkingKey: "walk-\(UUID().uuidString)"))
        window.orderFrontRegardless()
        Self.windows.append(window)
        await Self.spin(0.4)

        var shown: String? = "D0"
        var trail: [String] = []
        for step in 0..<70 {
            let roll = random.next(below: 100)
            guard let id = shown, let tv = Self.findTextView(window.contentView!) else {
                if roll < 70 {
                    // Back the way Nodes comes back: a new view, empty first.
                    let to = ids[random.next(below: ids.count)]
                    document = Document(id: to, text: "")
                    route.document = document
                    route.showsEditor = true
                    await Self.spin(0.12)
                    document.text = file[to]!
                    await Self.spin(0.18)
                    shown = to
                    trail.append("\(step) back on \(to)")
                    #expect(Self.findTextView(window.contentView!)?.string == file[to]!)
                } else {
                    let other = ids[random.next(below: ids.count)]
                    file[other] = "[rewritten \(step)] " + file[other]!
                    trail.append("\(step) rewrite \(other) while away")
                }
                continue
            }
            switch roll {
            case ..<30:
                let before = tv.string
                dropHistoryIfReplaced(id, shown: before)
                tv.breakUndoCoalescing()
                tv.insertText("<\(step)>", replacementRange: NSRange(location: random.next(below: (before as NSString).length + 1), length: 0))
                tv.breakUndoCoalescing()
                await Self.spin(0.12)
                history[id, default: []].append(before)
                file[id] = tv.string
                recordedOn[id] = tv.string
                trail.append("\(step) type in \(id)")
                #expect(document.text == tv.string, "typing reaches the binding")
            case ..<55:
                let before = tv.string
                dropHistoryIfReplaced(id, shown: before)
                let expected = history[id]?.popLast() ?? before
                tv.undo(nil)
                // The app's key window posts this after an undo; the test host does not.
                (tv.delegate as? NativeTextViewCoordinator)?
                    .textDidChange(Notification(name: NSText.didChangeNotification, object: tv))
                await Self.spin(0.12)
                trail.append("\(step) undo in \(id)")
                #expect(tv.string == expected, "step \(step), after: \(trail.suffix(10))")
                if tv.string != expected { history[id] = [] }
                file[id] = tv.string
                recordedOn[id] = tv.string
            case ..<75:
                // Nodes switches in two passes: the id first, the file one pass later.
                let to = ids[random.next(below: ids.count)]
                guard to != id else { continue }
                document.id = to
                await Self.spin(0.1)
                document.text = file[to]!
                await Self.spin(0.15)
                shown = to
                trail.append("\(step) switch \(id) to \(to)")
                #expect(tv.string == file[to]!)
            case ..<87:
                route.showsEditor = false
                await Self.spin(0.15)
                shown = nil
                trail.append("\(step) away from \(id)")
            case ..<94:
                file[id] = file[id]! + " [reload \(step)]"
                document.text = file[id]!
                await Self.spin(0.12)
                trail.append("\(step) reload \(id)")
            default:
                let other = ids[random.next(below: ids.count)]
                guard other != id else { continue }
                file[other] = "[rewritten \(step)] " + file[other]!
                trail.append("\(step) rewrite \(other)")
            }
        }
    }
}
