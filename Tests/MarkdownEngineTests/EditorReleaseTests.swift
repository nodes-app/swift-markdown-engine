//
//  EditorReleaseTests.swift
//  MarkdownEngineTests
//
//  Created by Luca Chen on 27.11.26.
//
//  An editor taken off screen is freed (#227). Finder's Quick Look builds one
//  for every Markdown file it previews, in a process it keeps alive, and the
//  clip view's block observers kept every one of them.
//
//  Each editor lives its whole life inside one run-loop callout
//  (`MainRunLoop.callout`, which says why).
//

import AppKit
import SwiftUI
import Testing
@testable import MarkdownEngine

@MainActor
@Suite("Editor release", .serialized)
struct EditorReleaseTests {

    /// Weak only: holding any part of the editor would keep it.
    private final class Probe {
        weak var textView: NativeTextView?
        weak var storage: NSTextStorage?
        weak var coordinator: NativeTextViewCoordinator?
        var wasShown = false
        var isFreed: Bool { textView == nil && storage == nil && coordinator == nil }
    }

    /// What the embedder shows: the editor, or another screen.
    private final class Route: ObservableObject {
        @Published var showsEditor = true
    }

    /// The code blocks as the editor last reported them.
    private final class Reports {
        var codeBlocks: [CodeBlockSelection] = []
    }

    private struct Host: View {
        @ObservedObject var route: Route
        let documentId: String
        let parkingKey: String?
        var reports = Reports()
        var body: some View {
            if route.showsEditor {
                NativeTextViewWrapper(
                    text: .constant(EditorReleaseTests.document),
                    documentId: documentId,
                    parkingKey: parkingKey,
                    onCodeBlockSelectionChange: { [reports] in reports.codeBlocks = $0 }
                )
            } else {
                Color.gray
            }
        }
    }

    private static let document = "Intro\n\n```swift\nlet x = 1\n```\n\n"
        + (1...80).map { "Line \($0) of a document long enough to scroll." }.joined(separator: "\n\n")

    /// The first editor in a process takes AppKit a few seconds to let go.
    private static func spin(untilFreed probe: Probe) {
        let deadline = Date(timeIntervalSinceNow: 10)
        while !probe.isFreed, Date() < deadline {
            MainRunLoop.spin(0.05)
        }
    }

    private static func findTextView(_ root: NSView?) -> NativeTextView? {
        guard let root else { return nil }
        if let sv = root as? NSScrollView, let tv = sv.nativeTextView { return tv }
        for sub in root.subviews {
            if let found = findTextView(sub) { return found }
        }
        return nil
    }

    private static func makeWindow() -> NSWindow {
        autoreleasepool {
            _ = NSApplication.shared
            let window = NSWindow(contentRect: NSRect(x: -30000, y: -30000, width: 600, height: 400),
                                  styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            return window
        }
    }

    private static func key() -> String { "release-test-\(UUID().uuidString)" }

    private static func show<V: View>(_ content: V, in window: NSWindow) {
        autoreleasepool {
            window.contentView = NSHostingView(rootView: content)
            window.orderFrontRegardless()
        }
        MainRunLoop.spin()
    }

    /// Weak references to the editor `window` shows.
    private static func probe(_ window: NSWindow) -> Probe {
        autoreleasepool {
            let probe = Probe()
            if let textView = findTextView(window.contentView) {
                probe.textView = textView
                probe.storage = textView.textStorage
                probe.coordinator = textView.delegate as? NativeTextViewCoordinator
                probe.wasShown = true
            }
            return probe
        }
    }

    /// Routes away from the editor, the way an embedder unmounts it.
    private static func routeAway(_ route: Route) {
        autoreleasepool { route.showsEditor = false }
        MainRunLoop.spin()
    }

    private static func isParked(_ key: String) -> Bool {
        autoreleasepool { EditorParking.parked[key] != nil }
    }

    @Test("an editor without a parking key is freed once its window lets it go")
    func unkeyedEditorIsFreed() async {
        let probe = await MainRunLoop.callout {
            let window = Self.makeWindow()
            defer { window.close() }
            Self.show(Host(route: Route(), documentId: "A", parkingKey: nil), in: window)
            let probe = Self.probe(window)
            // What Quick Look does when the next file is previewed.
            autoreleasepool {
                window.contentView = NSView()
                window.orderOut(nil)
            }
            Self.spin(untilFreed: probe)
            return probe
        }
        #expect(probe.wasShown)
        #expect(probe.textView == nil, "the text view is freed")
        #expect(probe.storage == nil, "and its text storage with it")
        #expect(probe.coordinator == nil)
    }

    @Test("an editor routed away without a parking key is freed")
    func unkeyedEditorRoutedAwayIsFreed() async {
        let (probe, unmounted) = await MainRunLoop.callout {
            let window = Self.makeWindow()
            defer { window.close() }
            let route = Route()
            Self.show(Host(route: route, documentId: "A", parkingKey: nil), in: window)
            let probe = Self.probe(window)
            Self.routeAway(route)
            let unmounted = autoreleasepool { Self.findTextView(window.contentView) == nil }
            Self.spin(untilFreed: probe)
            return (probe, unmounted)
        }
        #expect(probe.wasShown && unmounted)
        #expect(probe.isFreed)
    }

    @Test("a parked editor that comes back and is then let go is freed")
    func parkedEditorLetGoIsFreed() async {
        let seen = await MainRunLoop.callout {
            let key = Self.key()
            let window = Self.makeWindow()
            defer { window.close() }
            let route = Route()
            Self.show(Host(route: route, documentId: "A", parkingKey: key), in: window)
            let parked = Self.probe(window)
            Self.routeAway(route)
            let keptWhileParked = Self.isParked(key) && !parked.isFreed

            // Back, beside a second editor with its key: removed now, it is not kept.
            let left = Route(), right = Route()
            Self.show(HStack {
                Host(route: left, documentId: "A", parkingKey: key)
                Host(route: right, documentId: "B", parkingKey: key)
            }, in: window)
            let cameBack = !Self.isParked(key) && autoreleasepool { parked.textView?.window === window }
            Self.routeAway(left)
            let keptBesideAnother = Self.isParked(key)
            Self.spin(untilFreed: parked)
            return (parked: parked, keptWhileParked: keptWhileParked, cameBack: cameBack, keptBesideAnother: keptBesideAnother)
        }
        #expect(seen.parked.wasShown)
        #expect(seen.keptWhileParked, "parked, it is kept")
        #expect(seen.cameBack)
        #expect(!seen.keptBesideAnother, "the right editor is still up")
        #expect(seen.parked.isFreed)
    }

    @Test("a parked editor never taken back is freed when another is parked in its place")
    func replacedParkedEditorIsFreed() async {
        let seen = await MainRunLoop.callout {
            let key = Self.key(), staleKey = Self.key()
            let window = Self.makeWindow(), other = Self.makeWindow()
            defer { window.close(); other.close() }

            // The state makeNSView leaves when the parked editor is not the one its
            // coordinator came from: a new editor up, the old one still parked.
            let current = Route()
            Self.show(Host(route: current, documentId: "B", parkingKey: key), in: window)
            let staleRoute = Route()
            Self.show(Host(route: staleRoute, documentId: "A", parkingKey: staleKey), in: other)
            let stale = Self.probe(other)
            Self.routeAway(staleRoute)
            autoreleasepool {
                EditorParking.parked[key] = EditorParking.parked.removeValue(forKey: staleKey)
            }
            let keptWhileParked = !stale.isFreed

            Self.routeAway(current)
            let replaced = autoreleasepool { EditorParking.parked[key]?.coordinator.documentId == "B" }
            Self.spin(untilFreed: stale)
            return (stale: stale, keptWhileParked: keptWhileParked, replaced: replaced)
        }
        #expect(seen.stale.wasShown && seen.keptWhileParked)
        #expect(seen.replaced)
        #expect(seen.stale.isFreed)
    }

    @Test("a mounted editor still follows its viewport", arguments: [false, true])
    func mountedEditorFollowsItsViewport(cameBackFromParking: Bool) async throws {
        let seen = await MainRunLoop.callout {
            let window = Self.makeWindow()
            defer { window.close() }
            let route = Route()
            let reports = Reports()
            Self.show(Host(route: route, documentId: "A", parkingKey: cameBackFromParking ? Self.key() : nil, reports: reports),
                      in: window)
            let probe = Self.probe(window)
            var cameBack = true
            if cameBackFromParking {
                Self.routeAway(route)
                autoreleasepool { route.showsEditor = true }
                MainRunLoop.spin()
                cameBack = autoreleasepool { Self.findTextView(window.contentView) === probe.textView }
            }
            // Each read right after its change: SwiftUI's update pass reports the
            // code blocks too, one main-queue turn later.
            return autoreleasepool { () -> (cameBack: Bool, before: CGRect?, scrolled: CGRect?, widened: CGRect?) in
                guard let clip = probe.textView?.enclosingScrollView?.contentView else {
                    return (cameBack, nil, nil, nil)
                }
                let before = reports.codeBlocks.first?.rect
                clip.scroll(to: NSPoint(x: 0, y: clip.bounds.origin.y + 30))
                let scrolled = reports.codeBlocks.first?.rect
                window.setContentSize(NSSize(width: 800, height: 400))
                window.layoutIfNeeded()
                let widened = reports.codeBlocks.first?.rect
                return (cameBack, before, scrolled, widened)
            }
        }
        #expect(seen.cameBack, "the parked editor came back")
        let before = try #require(seen.before)
        let scrolled = try #require(seen.scrolled)
        let widened = try #require(seen.widened)
        #expect(abs(scrolled.minY - (before.minY - 30)) < 0.5, "the code block moved with the scroll")
        #expect(widened.width > before.width + 100, "and was re-measured at the new width")
    }
}
