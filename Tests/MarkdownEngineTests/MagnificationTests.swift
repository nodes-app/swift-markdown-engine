//
//  MagnificationTests.swift
//  MarkdownEngineTests
//
//  An embedder that magnifies the editor's scroll view (page zoom) gets the page
//  scaled as one: the reading column stays centred, the header band stays as wide as
//  the page, the top inset stays the scaled inset, and the clamp settles.
//

import AppKit
import SwiftUI
import Testing
@testable import MarkdownEngine

@MainActor
@Suite("Magnification", .serialized)
struct MagnificationTests {

    private struct Host: View {
        @State var text = String(repeating: "A line of prose for the reading column.\n\n", count: 40)
        var body: some View {
            var configuration = MarkdownEditorConfiguration.default
            configuration.readingWidth = 650
            configuration.safeAreaInsets = SafeAreaInsets(top: 56)
            return NativeTextViewWrapper(
                text: $text,
                configuration: configuration,
                documentId: "page",
                header: AnyView(Color.gray.frame(width: 650, height: 80))
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

    private static func spin(_ seconds: TimeInterval) async {
        let deadline = Date(timeIntervalSinceNow: seconds)
        while Date() < deadline {
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.01))
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
    }

    @Test("a magnified page keeps the column centred under a header as wide as the page")
    func magnifiedPageKeepsItsLayout() async throws {
        _ = NSApplication.shared
        let window = NSWindow(
            contentRect: NSRect(x: -30000, y: -30000, width: 1100, height: 700),
            styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: Host())
        window.orderFrontRegardless()
        Self.windows.append(window)
        await Self.spin(0.4)

        let tv = try #require(Self.findTextView(window.contentView!))
        let scrollView = try #require(tv.enclosingScrollView as? ClampedScrollView)
        let container = try #require(scrollView.documentView as? NativeTextViewContainer)
        let coordinator = try #require(tv.delegate as? NativeTextViewCoordinator)
        let clip = scrollView.contentView

        scrollView.allowsMagnification = true
        scrollView.maxMagnification = 3
        scrollView.setMagnification(1.5, centeredAt: NSPoint(x: clip.bounds.midX, y: 0))
        await Self.spin(0.3)

        let viewport = clip.bounds.width
        #expect(abs(viewport - clip.frame.width / 1.5) < 0.5)
        #expect(abs(container.frame.width - viewport) < 0.5, "the page must be exactly as wide as the magnified viewport")
        let header = try #require(coordinator.headerController?.clipView)
        #expect(abs(header.frame.width - container.frame.width) < 0.5,
                "the header band must span the page, not the clip's width in points")
        let expectedOrigin = floor((viewport - tv.readingColumnWidth) / 2)
        #expect(abs(container.columnOriginX - expectedOrigin) < 0.5, "the reading column must stay centred")
        #expect(abs(clip.bounds.origin.x) < 0.5, "a page that fits has nothing to the side")

        // Asked past the top, the clamp settles on the inset in page units, and settles at all.
        clip.scroll(to: NSPoint(x: 0, y: -10_000))
        scrollView.clampToInsets()
        await Self.spin(0.1)
        #expect(abs(clip.bounds.origin.y + 56 / 1.5) < 0.5)

        // Back to 100%: autoresizing takes the page again.
        scrollView.setMagnification(1, centeredAt: NSPoint(x: clip.bounds.midX, y: 0))
        await Self.spin(0.3)
        #expect(container.autoresizingMask == [.width])
        #expect(abs(container.frame.width - clip.frame.width) < 0.5)
    }
}
