//
//  ScrollingHeaderControllerTests.swift
//  MarkdownEngineTests
//
//  The scroll-away header: build, content refresh, collapse/expand reserved
//  height, and removal — headless (no window).
//

import AppKit
import SwiftUI
import Testing
@testable import MarkdownEngine

@MainActor
@Suite("ScrollingHeaderController")
struct ScrollingHeaderControllerTests {

    struct Stack {
        let scrollView: ClampedScrollView
        let container: NativeTextViewContainer
        let textView: NativeTextView
        let controller: ScrollingHeaderController
    }

    private func makeStack(viewport: NSSize = NSSize(width: 600, height: 800)) -> Stack {
        let scrollView = ClampedScrollView(frame: NSRect(origin: .zero, size: viewport))
        let textView = NativeTextView(frame: .zero)
        textView.configuration = .default
        textView.autoresizingMask = []
        let container = NativeTextViewContainer(frame: NSRect(origin: .zero, size: viewport))
        container.autoresizingMask = [.width]
        container.textView = textView
        textView.frame = NSRect(x: 0, y: 0, width: viewport.width, height: 0)
        container.addSubview(textView)
        scrollView.documentView = container
        return Stack(
            scrollView: scrollView, container: container, textView: textView,
            controller: ScrollingHeaderController()
        )
    }

    private func fixedHeightHeader(_ height: CGFloat) -> AnyView {
        AnyView(Color.clear.frame(width: 200, height: height))
    }

    /// Spin the main run loop until `condition` holds (or ~2s passes), laying
    /// out the container each turn — headless stand-in for the window's
    /// per-frame layout during an animation.
    private func spinUntil(_ container: NativeTextViewContainer, _ condition: () -> Bool) {
        let deadline = Date(timeIntervalSinceNow: 2.0)
        while !condition() && Date() < deadline {
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.02))
            container.layoutSubtreeIfNeeded()
        }
    }

    /// Animated settles go through the clip-frame observer, which carries a
    /// small deadband — compare with a matching tolerance, not exact equality.
    private func nearly(_ value: CGFloat, _ target: CGFloat) -> Bool {
        abs(value - target) <= 0.25
    }

    @Test func buildReservesCollapsedHeightWhenCollapsed() {
        let stack = makeStack()

        stack.controller.reconcile(
            header: fixedHeightHeader(120), collapsedHeight: 30, expanded: false,
            container: stack.container
        )
        stack.container.layoutSubtreeIfNeeded()

        #expect(stack.controller.clipView != nil)
        #expect(stack.controller.reservedHeight == 30)
        #expect(stack.container.headerHeight == 30)
        #expect(stack.textView.frame.origin.y == 30)
    }

    @Test func buildTracksContentHeightWhenExpanded() {
        let stack = makeStack()

        stack.controller.reconcile(
            header: fixedHeightHeader(120), collapsedHeight: 30, expanded: true,
            container: stack.container
        )
        stack.container.layoutSubtreeIfNeeded()

        #expect(stack.controller.reservedHeight == 120)
        #expect(stack.container.headerHeight == 120)
    }

    @Test func reconcileRefreshesHeaderContentWithinSameDocument() {
        let stack = makeStack()
        stack.controller.reconcile(
            header: fixedHeightHeader(120), collapsedHeight: 30, expanded: true,
            container: stack.container
        )
        stack.container.layoutSubtreeIfNeeded()
        #expect(stack.container.headerHeight == 120)

        // Same document, new content (e.g. the user renamed the title): the
        // hosted rootView must refresh — the reserved band tracks the new
        // intrinsic height without any document switch.
        stack.controller.reconcile(
            header: fixedHeightHeader(90), collapsedHeight: 30, expanded: true,
            container: stack.container
        )
        spinUntil(stack.container) { nearly(stack.container.headerHeight, 90) }

        #expect(nearly(stack.container.headerHeight, 90))
    }

    @Test func collapsedSteadyTracksCollapsedHeightChanges() {
        let stack = makeStack()
        stack.controller.reconcile(
            header: fixedHeightHeader(120), collapsedHeight: 30, expanded: false,
            container: stack.container
        )
        stack.container.layoutSubtreeIfNeeded()

        stack.controller.reconcile(
            header: fixedHeightHeader(120), collapsedHeight: 44, expanded: false,
            container: stack.container
        )
        stack.container.layoutSubtreeIfNeeded()

        #expect(stack.controller.reservedHeight == 44)
        #expect(stack.container.headerHeight == 44)
    }

    @Test func expandAnimatesToContentHeightAndSettles() {
        let stack = makeStack()
        stack.controller.animationDuration = 0.05
        stack.controller.reconcile(
            header: fixedHeightHeader(120), collapsedHeight: 30, expanded: false,
            container: stack.container
        )
        stack.container.layoutSubtreeIfNeeded()
        #expect(stack.container.headerHeight == 30)

        stack.controller.reconcile(
            header: fixedHeightHeader(120), collapsedHeight: 30, expanded: true,
            container: stack.container
        )
        spinUntil(stack.container) { nearly(stack.container.headerHeight, 120) }

        #expect(nearly(stack.container.headerHeight, 120))
        // After settling, the live-tracking equality constraint governs again.
        #expect(stack.controller.reservedHeight == 120)
    }

    @Test func collapseAnimatesBackToCollapsedHeight() {
        let stack = makeStack()
        stack.controller.animationDuration = 0.05
        stack.controller.reconcile(
            header: fixedHeightHeader(120), collapsedHeight: 30, expanded: true,
            container: stack.container
        )
        stack.container.layoutSubtreeIfNeeded()

        stack.controller.reconcile(
            header: fixedHeightHeader(120), collapsedHeight: 30, expanded: false,
            container: stack.container
        )
        spinUntil(stack.container) { nearly(stack.container.headerHeight, 30) }

        #expect(nearly(stack.container.headerHeight, 30))
        #expect(stack.controller.reservedHeight == 30)
    }

    @Test func bodyClippingIsGatedOnHeaderPresence() {
        let stack = makeStack()
        // Header-less editors keep AppKit's defaults — no clipping or redraw-policy
        // change for embedders that never pass a header. (TextKit 2 text views are
        // layer-backed by default; that part was never a change.)
        #expect(stack.textView.clipsToBounds == false)

        stack.controller.reconcile(
            header: fixedHeightHeader(120), collapsedHeight: 30, expanded: false,
            container: stack.container
        )

        // With a header, the body must be layer-backed, clipped, and redrawn on
        // explicit invalidation so responsive-scroll overdraw can't bleed into the
        // band above it.
        #expect(stack.textView.wantsLayer == true)
        #expect(stack.textView.clipsToBounds == true)
        #expect(stack.textView.layerContentsRedrawPolicy == .onSetNeedsDisplay)
    }

    @Test func removeRestoresHeaderlessStacking() {
        let stack = makeStack()
        stack.controller.reconcile(
            header: fixedHeightHeader(120), collapsedHeight: 30, expanded: false,
            container: stack.container
        )
        stack.container.layoutSubtreeIfNeeded()
        #expect(stack.container.headerHeight == 30)

        stack.controller.remove(from: stack.container)

        #expect(stack.controller.clipView == nil)
        #expect(stack.container.headerHeight == 0)
        #expect(stack.textView.frame.origin.y == 0)
        #expect(stack.container.subviews.count == 1)   // text view only
    }
}
