#if os(macOS)
//
//  HeightBehaviorTests.swift
//  MarkdownEngineTests
//
//  Configuration, inflation gating, overscroll zeroing, intrinsic content
//  size, runtime switching, async re-report, readingWidth composition, and
//  empty-document minimum height for the .fitsContent height behavior —
//  headless (no window).
//
//  Known coverage gap: `propagateCaretRevealToEnclosingScroller` (caret
//  visibility in a tall .fitsContent block). This requires a live
//  nested-scroll-view hierarchy (SwiftUI ScrollView hosting our
//  NSScrollView) which cannot be constructed in a headless test.
//  Verify manually in a host app.
//

import AppKit
import Testing
@testable import MarkdownEngine

// MARK: - Shared test stack

/// Scroll view + container + text view wired the way `makeNSView` wires them,
/// used by all HeightBehavior test suites.
@MainActor
struct HeightBehaviorStack {
    let scrollView: ClampedScrollView
    let container: NativeTextViewContainer
    let textView: NativeTextView

    init(
        viewport: NSSize = NSSize(width: 600, height: 800),
        heightBehavior: MarkdownEditorConfiguration.HeightBehavior = .scrolls
    ) {
        let sv = ClampedScrollView(frame: NSRect(origin: .zero, size: viewport))
        sv.fitsContent = heightBehavior == .fitsContent
        let tv = NativeTextView(frame: .zero)
        var config = MarkdownEditorConfiguration.default
        config.heightBehavior = heightBehavior
        tv.configuration = config
        tv.overscrollPercent = config.overscroll.percent
        tv.maxOverscrollPoints = config.overscroll.maxPoints
        tv.minOverscrollPoints = config.overscroll.minPoints
        tv.autoresizingMask = []
        let c = NativeTextViewContainer(frame: NSRect(origin: .zero, size: viewport))
        c.autoresizingMask = [.width]
        c.textView = tv
        tv.frame = NSRect(x: 0, y: 0, width: viewport.width, height: 0)
        c.addSubview(tv)
        sv.documentView = c
        self.scrollView = sv
        self.container = c
        self.textView = tv
    }
}

// MARK: - Configuration defaults

@Suite("HeightBehavior configuration")
struct HeightBehaviorDefaultTests {

    @Test func defaultIsScrolls() {
        let config = MarkdownEditorConfiguration.default
        #expect(config.heightBehavior == .scrolls)
    }

    @Test func initWithFitsContent() {
        let config = MarkdownEditorConfiguration(heightBehavior: .fitsContent)
        #expect(config.heightBehavior == .fitsContent)
    }

    @Test func defaultInitExplicitlyScrolls() {
        let config = MarkdownEditorConfiguration(heightBehavior: .scrolls)
        #expect(config.heightBehavior == .scrolls)
    }
}

// MARK: - Inflation gating

@MainActor
@Suite("FitsContent inflation gating")
struct FitsContentInflationTests {

    @Test func scrollsInflatesShortDocToViewport() {
        let stack = HeightBehaviorStack(heightBehavior: .scrolls)
        stack.textView.baseContentHeight = 100
        stack.textView.applyManagedFrameSize(width: 600)

        // Existing behavior: short text view inflates to fill viewport.
        #expect(stack.textView.frame.height == 800)
        #expect(stack.container.frame.height == 800)
    }

    @Test func fitsContentNoInflation() {
        let stack = HeightBehaviorStack(heightBehavior: .fitsContent)
        stack.textView.baseContentHeight = 100
        stack.textView.applyManagedFrameSize(width: 600)

        // In .fitsContent, the text view is exactly content height, no inflation.
        #expect(stack.textView.frame.height == 100)
        // Container should also NOT inflate to viewport.
        #expect(stack.container.frame.height == 100)
    }

    @Test func fitsContentRestackNoInflation() {
        let stack = HeightBehaviorStack(heightBehavior: .fitsContent)
        stack.textView.baseContentHeight = 200
        stack.textView.applyManagedFrameSize(width: 600)

        // With a header band, the container should still be exactly header + text.
        stack.container.headerHeight = 40

        let expectedTextHeight = stack.textView.frame.height
        let expectedContainerHeight = 40 + expectedTextHeight
        #expect(stack.container.frame.height == expectedContainerHeight)
    }

    @Test func scrollsRestackInflatesToViewport() {
        let stack = HeightBehaviorStack(heightBehavior: .scrolls)
        stack.textView.baseContentHeight = 100
        stack.textView.applyManagedFrameSize(width: 600)

        // The container inflates to viewport height.
        #expect(stack.container.frame.height == 800)

        // Adding a header still keeps the container at viewport height.
        stack.container.headerHeight = 40
        #expect(stack.container.frame.height == 800)
    }
}

// MARK: - Overscroll zeroing

@MainActor
@Suite("FitsContent overscroll")
struct FitsContentOverscrollTests {

    @Test func fitsContentOverscrollIsAlwaysZero() {
        let stack = HeightBehaviorStack(heightBehavior: .fitsContent)
        // Manually prime a tall content height and run the overscroll policy via
        // reapplyOverscrollPolicy (which re-evaluates without re-measuring).
        stack.textView.baseContentHeight = 1200
        stack.textView.reapplyOverscrollPolicy(for: stack.scrollView)

        #expect(stack.textView.activeBottomOverscroll == 0)
    }

    @Test func scrollsOverscrollIsNonZeroForTallContent() {
        let stack = HeightBehaviorStack(heightBehavior: .scrolls)
        // Manually prime a tall content height that exceeds the viewport.
        stack.textView.baseContentHeight = 1200
        stack.textView.reapplyOverscrollPolicy(for: stack.scrollView)

        #expect(stack.textView.activeBottomOverscroll > 0)
    }

    @Test func fitsContentRecalcOverscrollStillMeasuresHeight() {
        // Verify that recalcOverscroll still updates baseContentHeight in
        // .fitsContent mode (critical: sizeThatFits / intrinsicContentSize
        // report this value). The measuredBaseContentHeight in a headless
        // text view returns the minimum (one line height), but the important
        // assertion is that the call runs and assigns a value rather than
        // short-circuiting the measurement.
        let stack = HeightBehaviorStack(heightBehavior: .fitsContent)
        stack.textView.baseContentHeight = 0
        stack.textView.recalcOverscroll(for: stack.scrollView)

        // baseContentHeight must be set to the measured value (> 0 for even
        // an empty document in TextKit-2, which returns at least one line).
        #expect(stack.textView.baseContentHeight > 0)
        // Overscroll must still be zero in .fitsContent.
        #expect(stack.textView.activeBottomOverscroll == 0)
    }
}

// MARK: - ClampedScrollView intrinsic content size

@MainActor
@Suite("ClampedScrollView fitsContent")
struct ClampedScrollViewFitsContentTests {

    @Test func intrinsicContentSizeReportsHeightWhenFitsContent() {
        let stack = HeightBehaviorStack(heightBehavior: .fitsContent)
        stack.textView.baseContentHeight = 350
        stack.textView.applyManagedFrameSize(width: 600)

        let intrinsic = stack.scrollView.intrinsicContentSize
        #expect(intrinsic.width == NSView.noIntrinsicMetric)
        #expect(intrinsic.height == stack.container.scrollableContentHeight)
    }

    @Test func intrinsicContentSizeDefaultsToNoMetricWhenScrolls() {
        let stack = HeightBehaviorStack(heightBehavior: .scrolls)
        stack.textView.baseContentHeight = 350
        stack.textView.applyManagedFrameSize(width: 600)

        let intrinsic = stack.scrollView.intrinsicContentSize
        // Default NSScrollView returns noIntrinsicMetric for both dimensions.
        #expect(intrinsic.width == NSView.noIntrinsicMetric)
        #expect(intrinsic.height == NSView.noIntrinsicMetric)
    }

    @Test func intrinsicContentSizeIncludesHeaderHeight() {
        let stack = HeightBehaviorStack(heightBehavior: .fitsContent)
        stack.textView.baseContentHeight = 300
        stack.textView.applyManagedFrameSize(width: 600)
        stack.container.headerHeight = 50

        let intrinsic = stack.scrollView.intrinsicContentSize
        // scrollableContentHeight = headerHeight + textView.scrollableContentHeight
        #expect(intrinsic.height == stack.container.scrollableContentHeight)
        #expect(intrinsic.height == 50 + stack.textView.scrollableContentHeight)
    }
}

// MARK: - Runtime heightBehavior switch

@MainActor
@Suite("Runtime heightBehavior switch")
struct RuntimeHeightBehaviorSwitchTests {

    @Test func switchFromScrollsToFitsContentRemovesInflation() {
        // Start in .scrolls — short content inflated to viewport.
        let stack = HeightBehaviorStack(heightBehavior: .scrolls)
        stack.textView.baseContentHeight = 100
        stack.textView.applyManagedFrameSize(width: 600)
        #expect(stack.textView.frame.height == 800)
        #expect(stack.container.frame.height == 800)

        // Switch to .fitsContent at runtime.
        var newConfig = stack.textView.configuration
        newConfig.heightBehavior = .fitsContent
        stack.textView.configuration = newConfig
        stack.scrollView.fitsContent = true
        // Use reapplyOverscrollPolicy (not recalcOverscroll) to avoid
        // TextKit-2 re-measuring the content height in a headless test,
        // then applyManagedFrameSize to reconfigure the frame.
        stack.textView.reapplyOverscrollPolicy(for: stack.scrollView)
        stack.textView.applyManagedFrameSize(width: 600)

        // Inflation removed: text view and container match content height.
        #expect(stack.textView.frame.height == 100)
        #expect(stack.container.frame.height == 100)
    }

    @Test func switchFromFitsContentToScrollsRestoresInflation() {
        // Start in .fitsContent — exact content height.
        let stack = HeightBehaviorStack(heightBehavior: .fitsContent)
        stack.textView.baseContentHeight = 100
        stack.textView.applyManagedFrameSize(width: 600)
        #expect(stack.textView.frame.height == 100)

        // Switch to .scrolls at runtime.
        var newConfig = stack.textView.configuration
        newConfig.heightBehavior = .scrolls
        stack.textView.configuration = newConfig
        stack.scrollView.fitsContent = false
        stack.textView.recalcOverscroll(for: stack.scrollView)

        // Inflation restored: text view fills the viewport.
        #expect(stack.textView.frame.height == 800)
        #expect(stack.container.frame.height == 800)
    }

    @Test func switchToFitsContentZerosOverscroll() {
        // Start in .scrolls with tall content that has overscroll.
        let stack = HeightBehaviorStack(heightBehavior: .scrolls)
        stack.textView.baseContentHeight = 1200
        stack.textView.reapplyOverscrollPolicy(for: stack.scrollView)
        #expect(stack.textView.activeBottomOverscroll > 0)

        // Switch to .fitsContent.
        var newConfig = stack.textView.configuration
        newConfig.heightBehavior = .fitsContent
        stack.textView.configuration = newConfig
        stack.scrollView.fitsContent = true
        stack.textView.reapplyOverscrollPolicy(for: stack.scrollView)

        #expect(stack.textView.activeBottomOverscroll == 0)
    }

    @Test func switchToScrollsRestoresOverscroll() {
        // Start in .fitsContent — overscroll is zero.
        let stack = HeightBehaviorStack(heightBehavior: .fitsContent)
        stack.textView.baseContentHeight = 1200
        stack.textView.reapplyOverscrollPolicy(for: stack.scrollView)
        #expect(stack.textView.activeBottomOverscroll == 0)

        // Switch to .scrolls.
        var newConfig = stack.textView.configuration
        newConfig.heightBehavior = .scrolls
        stack.textView.configuration = newConfig
        stack.scrollView.fitsContent = false
        stack.textView.reapplyOverscrollPolicy(for: stack.scrollView)

        #expect(stack.textView.activeBottomOverscroll > 0)
    }

    @Test func switchReconfiguresIntrinsicContentSize() {
        let stack = HeightBehaviorStack(heightBehavior: .scrolls)
        stack.textView.baseContentHeight = 400
        stack.textView.applyManagedFrameSize(width: 600)

        // In .scrolls, intrinsicContentSize.height is noIntrinsicMetric.
        #expect(stack.scrollView.intrinsicContentSize.height == NSView.noIntrinsicMetric)

        // Switch to .fitsContent.
        var newConfig = stack.textView.configuration
        newConfig.heightBehavior = .fitsContent
        stack.textView.configuration = newConfig
        stack.scrollView.fitsContent = true
        stack.textView.recalcOverscroll(for: stack.scrollView)

        // Now intrinsicContentSize should report actual height.
        #expect(stack.scrollView.intrinsicContentSize.height == stack.container.scrollableContentHeight)
    }
}

// MARK: - Reading width + fitsContent

@MainActor
@Suite("ReadingWidth + fitsContent")
struct ReadingWidthFitsContentTests {

    @Test func readingWidthPreservedNoInflation() {
        let viewport = NSSize(width: 800, height: 600)
        let sv = ClampedScrollView(frame: NSRect(origin: .zero, size: viewport))
        sv.fitsContent = true
        let tv = NativeTextView(frame: .zero)
        var config = MarkdownEditorConfiguration.default
        config.heightBehavior = .fitsContent
        config.readingWidth = 400
        tv.configuration = config
        tv.autoresizingMask = []
        let c = NativeTextViewContainer(frame: NSRect(origin: .zero, size: viewport))
        c.autoresizingMask = [.width]
        c.textView = tv
        let columnWidth = tv.readingColumnWidth
        tv.frame = NSRect(x: 0, y: 0, width: columnWidth, height: 0)
        c.addSubview(tv)
        sv.documentView = c

        tv.baseContentHeight = 200
        tv.applyManagedFrameSize(width: columnWidth)

        // Column keeps its fixed width.
        #expect(tv.frame.width == columnWidth)
        // Height is exact content (no viewport inflation).
        #expect(tv.frame.height == 200)
        // Container is also content-tall, not viewport-inflated.
        #expect(c.frame.height == 200)
    }
}

// MARK: - Empty-document minimum height

@MainActor
@Suite("FitsContent empty-document minimum height")
struct FitsContentEmptyDocMinHeightTests {

    @Test func emptyDocHasPositiveHeight() {
        let stack = HeightBehaviorStack(heightBehavior: .fitsContent)
        // A fresh text view with no text inserted — recalcOverscroll measures
        // the TextKit-2 content height, which returns at least one line height.
        stack.textView.recalcOverscroll(for: stack.scrollView)

        // baseContentHeight must be positive (at least one body line).
        #expect(stack.textView.baseContentHeight > 0)
        // The frame must reflect that minimum.
        #expect(stack.textView.frame.height > 0)
        // scrollableContentHeight = baseContentHeight (no overscroll).
        #expect(stack.textView.scrollableContentHeight == stack.textView.baseContentHeight)
    }
}

// MARK: - Header + fitsContent height composition

@MainActor
@Suite("Header + fitsContent height")
struct HeaderFitsContentTests {

    @Test func staticHeaderIncludedInScrollableContentHeight() {
        let stack = HeightBehaviorStack(heightBehavior: .fitsContent)
        stack.textView.baseContentHeight = 300
        stack.textView.applyManagedFrameSize(width: 600)
        stack.container.headerHeight = 60

        // scrollableContentHeight = header + text view's scrollableContentHeight
        let expectedTotal: CGFloat = 60 + 300
        #expect(stack.container.scrollableContentHeight == expectedTotal)
        // Container frame matches exactly (no viewport inflation).
        #expect(stack.container.frame.height == expectedTotal)
        // Text view sits below the header.
        #expect(stack.textView.frame.origin.y == 60)
    }

    @Test func headerChangeReReportsIntrinsicSize() {
        let stack = HeightBehaviorStack(heightBehavior: .fitsContent)
        stack.textView.baseContentHeight = 300
        stack.textView.applyManagedFrameSize(width: 600)

        let beforeHeader = stack.scrollView.intrinsicContentSize.height
        stack.container.headerHeight = 80
        let afterHeader = stack.scrollView.intrinsicContentSize.height

        // Adding a header should increase the reported height by the header band.
        #expect(afterHeader == beforeHeader + 80)
    }
}

// MARK: - Scroll-wheel forwarding

@MainActor
@Suite("FitsContent scroll-wheel forwarding")
struct ScrollWheelForwardingTests {

    /// Minimal NSView that records whether it received a scrollWheel event.
    final class ScrollWheelSpy: NSView {
        var receivedScrollWheel = false
        override func scrollWheel(with event: NSEvent) {
            receivedScrollWheel = true
        }
    }

    @Test func fitsContentForwardsScrollWheelToNextResponder() {
        let stack = HeightBehaviorStack(heightBehavior: .fitsContent)
        let spy = ScrollWheelSpy(frame: .zero)
        // Wire the spy as the scroll view's nextResponder.
        stack.scrollView.nextResponder = spy

        // Create a synthetic scroll event. CGEvent is used because
        // NSEvent(scrollWheel:) does not exist as a public initializer.
        guard let cgEvent = CGEvent(
            scrollWheelEvent2Source: nil,
            units: .pixel,
            wheelCount: 1,
            wheel1: 10,
            wheel2: 0,
            wheel3: 0
        ) else { return }
        guard let nsEvent = NSEvent(cgEvent: cgEvent) else { return }
        stack.scrollView.scrollWheel(with: nsEvent)

        #expect(spy.receivedScrollWheel == true)
    }

    @Test func scrollsDoesNotForwardScrollWheel() {
        let stack = HeightBehaviorStack(heightBehavior: .scrolls)
        let spy = ScrollWheelSpy(frame: .zero)
        stack.scrollView.nextResponder = spy

        guard let cgEvent = CGEvent(
            scrollWheelEvent2Source: nil,
            units: .pixel,
            wheelCount: 1,
            wheel1: 10,
            wheel2: 0,
            wheel3: 0
        ) else { return }
        guard let nsEvent = NSEvent(cgEvent: cgEvent) else { return }
        stack.scrollView.scrollWheel(with: nsEvent)

        // In .scrolls mode, scrollWheel is handled by super (NSScrollView),
        // not forwarded to nextResponder.
        #expect(spy.receivedScrollWheel == false)
    }
}

// MARK: - Async height-change re-report

@MainActor
@Suite("FitsContent async height-change re-report")
struct AsyncHeightChangeTests {

    @Test func contentHeightChangeUpdatesFrame() {
        // Simulate an async content height change (e.g. image/LaTeX finishing layout)
        // by mutating baseContentHeight and calling applyManagedFrameSize.
        let stack = HeightBehaviorStack(heightBehavior: .fitsContent)
        stack.textView.baseContentHeight = 200
        stack.textView.applyManagedFrameSize(width: 600)
        #expect(stack.textView.frame.height == 200)
        #expect(stack.container.frame.height == 200)

        // Async height change: content grows.
        stack.textView.baseContentHeight = 450
        stack.textView.applyManagedFrameSize(width: 600)

        #expect(stack.textView.frame.height == 450)
        #expect(stack.container.frame.height == 450)
        // intrinsicContentSize reflects the new height.
        #expect(stack.scrollView.intrinsicContentSize.height == 450)
    }

    @Test func contentHeightChangePreservesExactHeight() {
        // After an async height change, no viewport inflation occurs.
        let stack = HeightBehaviorStack(
            viewport: NSSize(width: 600, height: 800),
            heightBehavior: .fitsContent
        )
        stack.textView.baseContentHeight = 300
        stack.textView.applyManagedFrameSize(width: 600)

        // Grow past the viewport: still exact content height, not clamped.
        stack.textView.baseContentHeight = 1200
        stack.textView.applyManagedFrameSize(width: 600)

        #expect(stack.textView.frame.height == 1200)
        #expect(stack.container.frame.height == 1200)
    }

    @Test func heightShrinkUpdatesFrame() {
        // Content can also shrink (e.g. image removed, text deleted).
        let stack = HeightBehaviorStack(heightBehavior: .fitsContent)
        stack.textView.baseContentHeight = 600
        stack.textView.applyManagedFrameSize(width: 600)
        #expect(stack.textView.frame.height == 600)

        stack.textView.baseContentHeight = 150
        stack.textView.applyManagedFrameSize(width: 600)

        #expect(stack.textView.frame.height == 150)
        #expect(stack.container.frame.height == 150)
        #expect(stack.scrollView.intrinsicContentSize.height == 150)
    }

    @Test func heightChangeInScrollsModeInflates() {
        // Contrast: in .scrolls mode, short content inflates to viewport.
        let stack = HeightBehaviorStack(
            viewport: NSSize(width: 600, height: 800),
            heightBehavior: .scrolls
        )
        stack.textView.baseContentHeight = 200
        stack.textView.applyManagedFrameSize(width: 600)
        #expect(stack.textView.frame.height == 800)

        // Growing past viewport: frame matches content.
        stack.textView.baseContentHeight = 1200
        stack.textView.applyManagedFrameSize(width: 600)
        #expect(stack.textView.frame.height == 1200)

        // Shrinking below viewport: inflates back to viewport.
        stack.textView.baseContentHeight = 300
        stack.textView.applyManagedFrameSize(width: 600)
        #expect(stack.textView.frame.height == 800)
    }

    @Test func asyncChangeWithHeaderUpdatesTotal() {
        // Async height change with a header band present.
        let stack = HeightBehaviorStack(heightBehavior: .fitsContent)
        stack.textView.baseContentHeight = 200
        stack.textView.applyManagedFrameSize(width: 600)
        stack.container.headerHeight = 60

        // Simulate async growth.
        stack.textView.baseContentHeight = 400
        stack.textView.applyManagedFrameSize(width: 600)

        let expectedTotal: CGFloat = 60 + 400
        #expect(stack.textView.frame.height == 400)
        #expect(stack.container.frame.height == expectedTotal)
        #expect(stack.scrollView.intrinsicContentSize.height == expectedTotal)
    }
}

// MARK: - Per-keystroke recalc chain

@MainActor
@Suite("FitsContent per-keystroke recalc chain")
struct FitsContentRecalcChainTests {

    @Test func recalcUpdatesFrameAndContainer() {
        // The per-keystroke chain: recalcOverscroll measures content,
        // calls applyManagedFrameSize, which sizes the frame and
        // triggers container restack.
        let stack = HeightBehaviorStack(heightBehavior: .fitsContent)

        // Prime with an initial recalc (empty doc → one line height).
        stack.textView.recalcOverscroll(for: stack.scrollView)
        let initialHeight = stack.textView.frame.height
        #expect(initialHeight > 0)

        // The container matches the text view (no header, no inflation).
        #expect(stack.container.frame.height == initialHeight)
        // Overscroll stays zero.
        #expect(stack.textView.activeBottomOverscroll == 0)
    }

    @Test func recalcAfterHeightChangeUpdatesIntrinsicSize() {
        // After a height change driven through recalcOverscroll, the
        // scroll view's intrinsicContentSize must reflect the new value.
        let stack = HeightBehaviorStack(heightBehavior: .fitsContent)
        stack.textView.recalcOverscroll(for: stack.scrollView)
        let initial = stack.scrollView.intrinsicContentSize.height

        // Manually set a taller base and re-run the recalc chain.
        stack.textView.baseContentHeight = 500
        stack.textView.applyManagedFrameSize(width: 600)

        let updated = stack.scrollView.intrinsicContentSize.height
        #expect(updated == 500)
        #expect(updated > initial)
    }
}

// MARK: - Height change after runtime switch

@MainActor
@Suite("Height change after runtime switch")
struct HeightChangeAfterRuntimeSwitchTests {

    @Test func heightChangeAfterSwitchToFitsContent() {
        // Start in .scrolls, switch to .fitsContent, then change height.
        let stack = HeightBehaviorStack(
            viewport: NSSize(width: 600, height: 800),
            heightBehavior: .scrolls
        )
        stack.textView.baseContentHeight = 200
        stack.textView.applyManagedFrameSize(width: 600)
        #expect(stack.textView.frame.height == 800) // inflated

        // Switch to .fitsContent.
        var config = stack.textView.configuration
        config.heightBehavior = .fitsContent
        stack.textView.configuration = config
        stack.scrollView.fitsContent = true
        stack.textView.reapplyOverscrollPolicy(for: stack.scrollView)
        stack.textView.applyManagedFrameSize(width: 600)
        #expect(stack.textView.frame.height == 200) // deflated

        // Now simulate an async height change.
        stack.textView.baseContentHeight = 350
        stack.textView.applyManagedFrameSize(width: 600)

        // Must be exact content height, no inflation.
        #expect(stack.textView.frame.height == 350)
        #expect(stack.container.frame.height == 350)
        #expect(stack.scrollView.intrinsicContentSize.height == 350)
    }

    @Test func heightChangeAfterSwitchToScrolls() {
        // Start in .fitsContent, switch to .scrolls, then change height.
        let stack = HeightBehaviorStack(
            viewport: NSSize(width: 600, height: 800),
            heightBehavior: .fitsContent
        )
        stack.textView.baseContentHeight = 200
        stack.textView.applyManagedFrameSize(width: 600)
        #expect(stack.textView.frame.height == 200)

        // Switch to .scrolls.
        var config = stack.textView.configuration
        config.heightBehavior = .scrolls
        stack.textView.configuration = config
        stack.scrollView.fitsContent = false
        stack.textView.recalcOverscroll(for: stack.scrollView)
        #expect(stack.textView.frame.height == 800) // inflated

        // Async height change: still below viewport → stays inflated.
        stack.textView.baseContentHeight = 400
        stack.textView.applyManagedFrameSize(width: 600)
        #expect(stack.textView.frame.height == 800)

        // intrinsicContentSize should revert to noIntrinsicMetric.
        #expect(stack.scrollView.intrinsicContentSize.height == NSView.noIntrinsicMetric)
    }
}

// MARK: - Runtime switch scroller visibility

@MainActor
@Suite("Runtime switch scroller visibility")
struct RuntimeSwitchScrollerVisibilityTests {

    // All tests call the shared production function
    // `HeightBehavior.wantsVerticalScroller(for:)` — the same function
    // used by `makeNSView` and `updateNSView` to set
    // `scrollView.hasVerticalScroller`. No duplicated logic.

    @Test func fitsContentAlwaysDisablesVerticalScroller() {
        // Even when the scrollers policy has vertical scroller = true,
        // .fitsContent overrides it to false (nothing to scroll).
        let policy = ScrollersPolicy(hasVerticalScroller: true)
        let result = MarkdownEditorConfiguration.HeightBehavior.fitsContent
            .wantsVerticalScroller(for: policy)
        #expect(result == false)
    }

    @Test func scrollsRespectsScrollersPolicy() {
        // In .scrolls, the scroller follows the policy.
        let policyOn = ScrollersPolicy(hasVerticalScroller: true)
        #expect(
            MarkdownEditorConfiguration.HeightBehavior.scrolls
                .wantsVerticalScroller(for: policyOn) == true
        )

        let policyOff = ScrollersPolicy(hasVerticalScroller: false)
        #expect(
            MarkdownEditorConfiguration.HeightBehavior.scrolls
                .wantsVerticalScroller(for: policyOff) == false
        )
    }

}

// MARK: - Full runtime reconfiguration chain

@MainActor
@Suite("Full runtime reconfiguration")
struct FullRuntimeReconfigurationTests {

    @Test func switchReconfiguresAllThreeLayers() {
        // Verify that a runtime switch syncs the heightBehavior across
        // scroll view (fitsContent flag), text view (configuration),
        // and that intrinsicContentSize reflects the new mode.
        let stack = HeightBehaviorStack(
            viewport: NSSize(width: 600, height: 800),
            heightBehavior: .scrolls
        )
        stack.textView.baseContentHeight = 300
        stack.textView.applyManagedFrameSize(width: 600)

        // Verify initial state: .scrolls.
        #expect(stack.scrollView.fitsContent == false)
        #expect(stack.textView.configuration.heightBehavior == .scrolls)
        #expect(stack.scrollView.intrinsicContentSize.height == NSView.noIntrinsicMetric)

        // Switch to .fitsContent, mimicking updateNSView.
        var newConfig = stack.textView.configuration
        newConfig.heightBehavior = .fitsContent
        stack.textView.configuration = newConfig
        stack.scrollView.fitsContent = true
        stack.textView.reapplyOverscrollPolicy(for: stack.scrollView)
        stack.textView.applyManagedFrameSize(width: 600)
        stack.scrollView.invalidateIntrinsicContentSize()

        // All three layers should reflect .fitsContent.
        #expect(stack.scrollView.fitsContent == true)
        #expect(stack.textView.configuration.heightBehavior == .fitsContent)
        #expect(stack.textView.activeBottomOverscroll == 0)
        #expect(stack.textView.frame.height == 300)
        #expect(stack.container.frame.height == 300)
        #expect(stack.scrollView.intrinsicContentSize.height == 300)
    }

    @Test func switchPreservesContentHeight() {
        // Content height should survive a round-trip switch:
        // .scrolls → .fitsContent → .scrolls
        // Uses reapplyOverscrollPolicy (not recalcOverscroll) to avoid
        // TextKit-2 re-measuring in a headless test, which would overwrite
        // the primed baseContentHeight.
        //
        // Use a short content (100pt) that stays below the overscroll
        // activation threshold so the .scrolls frame inflates to exactly
        // the viewport height with no added overscroll.
        let stack = HeightBehaviorStack(
            viewport: NSSize(width: 600, height: 800),
            heightBehavior: .scrolls
        )
        stack.textView.baseContentHeight = 100
        stack.textView.applyManagedFrameSize(width: 600)
        let originalBaseHeight = stack.textView.baseContentHeight

        // → .fitsContent
        var fc = stack.textView.configuration
        fc.heightBehavior = .fitsContent
        stack.textView.configuration = fc
        stack.scrollView.fitsContent = true
        stack.textView.reapplyOverscrollPolicy(for: stack.scrollView)
        stack.textView.applyManagedFrameSize(width: 600)
        #expect(stack.textView.baseContentHeight == originalBaseHeight)
        #expect(stack.textView.frame.height == 100)

        // → back to .scrolls
        var sc = stack.textView.configuration
        sc.heightBehavior = .scrolls
        stack.textView.configuration = sc
        stack.scrollView.fitsContent = false
        stack.textView.reapplyOverscrollPolicy(for: stack.scrollView)
        stack.textView.applyManagedFrameSize(width: 600)
        #expect(stack.textView.baseContentHeight == originalBaseHeight)
        // Frame is inflated to viewport since content (100) < viewport (800)
        // and content is below the overscroll activation threshold.
        #expect(stack.textView.frame.height == 800)
    }

    @Test func switchWithHeaderPreservesTotal() {
        // With a header band, switching should preserve the total
        // scrollableContentHeight composition.
        let stack = HeightBehaviorStack(
            viewport: NSSize(width: 600, height: 800),
            heightBehavior: .fitsContent
        )
        stack.textView.baseContentHeight = 250
        stack.textView.applyManagedFrameSize(width: 600)
        stack.container.headerHeight = 50

        let expectedTotal: CGFloat = 50 + 250
        #expect(stack.container.scrollableContentHeight == expectedTotal)

        // Switch to .scrolls.
        var sc = stack.textView.configuration
        sc.heightBehavior = .scrolls
        stack.textView.configuration = sc
        stack.scrollView.fitsContent = false
        stack.textView.reapplyOverscrollPolicy(for: stack.scrollView)
        stack.textView.applyManagedFrameSize(width: 600)

        // scrollableContentHeight still composes header + content.
        // (The container inflates to viewport, but scrollableContentHeight
        // is the real content height, used by clampToInsets.)
        let scrollsTotal: CGFloat = 50 + stack.textView.scrollableContentHeight
        #expect(stack.container.scrollableContentHeight == scrollsTotal)
    }
}
#endif
