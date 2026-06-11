//
//  NativeTextViewContainerTests.swift
//  MarkdownEngineTests
//
//  The container document view: header-band stacking, scrollable-height
//  composition, and reading-column centering — headless (no window).
//

import AppKit
import Testing
@testable import MarkdownEngine

@MainActor
@Suite("NativeTextViewContainer stacking")
struct NativeTextViewContainerTests {

    /// Scroll view + container + text view wired the way `makeNSView` wires them.
    /// Bind the whole stack in the test — the scroll view must outlive the
    /// assertions or the view hierarchy tears down mid-test.
    struct Stack {
        let scrollView: ClampedScrollView
        let container: NativeTextViewContainer
        let textView: NativeTextView
    }

    private func makeStack(
        viewport: NSSize = NSSize(width: 600, height: 800),
        readingWidth: CGFloat? = nil
    ) -> Stack {
        let scrollView = ClampedScrollView(frame: NSRect(origin: .zero, size: viewport))
        let textView = NativeTextView(frame: .zero)
        var config = MarkdownEditorConfiguration.default
        config.readingWidth = readingWidth
        textView.configuration = config
        textView.autoresizingMask = []
        let container = NativeTextViewContainer(frame: NSRect(origin: .zero, size: viewport))
        container.autoresizingMask = [.width]
        container.textView = textView
        let initialWidth = readingWidth != nil ? textView.readingColumnWidth : viewport.width
        textView.frame = NSRect(x: 0, y: 0, width: initialWidth, height: 0)
        container.addSubview(textView)
        scrollView.documentView = container
        return Stack(scrollView: scrollView, container: container, textView: textView)
    }

    @Test func headerBandMovesTextViewBelowIt() {
        let stack = makeStack()
        stack.textView.baseContentHeight = 900
        stack.textView.applyManagedFrameSize(width: 600)
        #expect(stack.textView.frame.height == 900)

        stack.container.headerHeight = 40

        #expect(stack.textView.frame.origin.y == 40)
        // Band changes re-run the overscroll policy — assert slack-agnostic
        // stacking so policy tuning can't break this test.
        #expect(stack.textView.frame.height == 900 + stack.textView.activeBottomOverscroll)
        #expect(stack.container.frame.height == 40 + stack.textView.frame.height)
    }

    @Test func containerNeverShrinksBelowViewport() {
        let stack = makeStack()
        stack.textView.baseContentHeight = 100
        stack.textView.applyManagedFrameSize(width: 600)

        #expect(stack.textView.frame.height == 800)   // viewport-fill inflation
        #expect(stack.container.frame.height == 800)

        // Exercise the container's OWN viewport floor: force the text view to an
        // under-filling height (bypassing the managed inflation) — the container
        // must still span the viewport so there's no dead band below the body.
        stack.textView.isApplyingManagedFrameSize = true
        stack.textView.setFrameSize(NSSize(width: 600, height: 100))
        stack.textView.isApplyingManagedFrameSize = false
        stack.container.textViewDidResize()

        #expect(stack.textView.frame.height == 100)
        #expect(stack.container.frame.height == 800)
    }

    @Test func scrollableContentHeightComposesHeaderAndContent() {
        let stack = makeStack()
        stack.textView.baseContentHeight = 500
        stack.textView.activeBottomOverscroll = 60

        stack.container.headerHeight = 40

        // The band change re-runs the policy (slack > primed 60), while the primed
        // base content height must survive un-clobbered (no re-measure).
        #expect(stack.textView.activeBottomOverscroll > 60)
        #expect(stack.container.scrollableContentHeight
            == 40 + 500 + stack.textView.activeBottomOverscroll)
    }

    @Test func readingColumnKeepsCenteredXThroughRestacks() {
        let stack = makeStack(readingWidth: 400)
        stack.textView.baseContentHeight = 500
        stack.textView.applyManagedFrameSize(width: 600)
        stack.textView.centerReadingColumn(forClipWidth: 600)
        let expectedX = floor((600 - stack.textView.readingColumnWidth) / 2)
        #expect(stack.textView.frame.origin.x == expectedX)

        // A height-only restack (header change) must not reset the centered X.
        stack.container.headerHeight = 40
        #expect(stack.textView.frame.origin.x == expectedX)
        #expect(stack.textView.frame.origin.y == 40)
    }

    @Test func viewportWidthChangeRecentersReadingColumn() {
        let stack = makeStack(readingWidth: 400)
        stack.textView.baseContentHeight = 500
        stack.textView.applyManagedFrameSize(width: 600)
        stack.textView.centerReadingColumn(forClipWidth: 600)

        stack.container.setFrameSize(NSSize(width: 1000, height: stack.container.frame.height))

        let expectedX = floor((1000 - stack.textView.readingColumnWidth) / 2)
        #expect(stack.textView.frame.origin.x == expectedX)
        // The column keeps its fixed width — only its position moves.
        #expect(stack.textView.frame.width == stack.textView.readingColumnWidth)
    }

    @Test func headerGrowthOnShortDocAddsNoPhantomScrollRange() {
        let stack = makeStack()
        stack.textView.baseContentHeight = 100
        stack.textView.applyManagedFrameSize(width: 600)
        #expect(stack.container.frame.height == 800)

        // Reserving a header band must re-apply the viewport-fill inflation:
        // header + text view == viewport, otherwise a short doc grows a
        // phantom scroll range (spurious scroller, clamp-fighting jitter).
        stack.container.headerHeight = 40
        #expect(stack.textView.frame.height == 760)
        #expect(stack.container.frame.height == 800)

        // Expanding the header (animation drives headerHeight per frame).
        stack.container.headerHeight = 300
        #expect(stack.textView.frame.height == 500)
        #expect(stack.container.frame.height == 800)

        // Collapsing back restores the band split.
        stack.container.headerHeight = 40
        #expect(stack.textView.frame.height == 760)
        #expect(stack.container.frame.height == 800)
    }

    @Test func fullWidthModePropagatesViewportWidth() {
        let stack = makeStack()
        stack.textView.baseContentHeight = 900
        stack.textView.applyManagedFrameSize(width: 600)

        stack.container.setFrameSize(NSSize(width: 1000, height: stack.container.frame.height))

        #expect(stack.textView.frame.width == 1000)
        #expect(stack.textView.frame.origin.x == 0)
    }
}
