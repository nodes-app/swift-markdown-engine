//
//  ClampedScrollView.swift
//  MarkdownEngine
//
//  Created by Luca Chen on 18.02.26.
//

// Scroll view that keeps vertical scrolling within a clean top and bottom range.
import AppKit

final class ClampedScrollView: NSScrollView {
    /// When true, the scroll view has no scrollable range — the editor reports its
    /// own height to SwiftUI and the enclosing scroll view owns paging.
    var fitsContent: Bool = false

    /// AppKit can process a physical window resize inside a nested tracking
    /// loop without servicing deferred run-loop blocks. Keep explicit state so
    /// width-dependent rendering can finish before each frame-size callback
    /// returns instead of waiting for mouse-up.
    private(set) var isLiveResizeActive = false
    private var isAwaitingPostLiveResizeWidthUpdate = false

    /// SwiftUI can deliver the final document-view width after AppKit's
    /// `viewDidEndLiveResize`. Keep the synchronous path armed until that
    /// concrete width update arrives; already-settled geometry never arms it.
    var requiresSynchronousTableWidthUpdate: Bool {
        isLiveResizeActive || isAwaitingPostLiveResizeWidthUpdate
    }

    func acknowledgePostLiveResizeWidthUpdate() {
        guard !isLiveResizeActive, isAwaitingPostLiveResizeWidthUpdate else {
            return
        }
        isAwaitingPostLiveResizeWidthUpdate = false
    }

    private var hasUnpropagatedLiveResizeWidth: Bool {
        guard let container = documentView as? NativeTextViewContainer,
              let textView = container.textView else {
            return false
        }
        let viewportWidth = contentView.bounds.width
        guard viewportWidth.isFinite, viewportWidth >= 0 else { return false }
        if container.bounds.width != viewportWidth { return true }
        return textView.configuration.readingWidth == nil
            && textView.frame.width != container.bounds.width
    }

    /// Saved at the start of every live-resize (including spurious one-click resizes triggered by edge-cursor clicks) so the position is restored when the resize ends. Without this, NSScrollView's default top-anchor-during-resize would jolt a bottom-anchored user back up by hundreds of points on a single edge click.
    private var scrollYBeforeLiveResize: CGFloat?

    override var intrinsicContentSize: NSSize {
        guard fitsContent, let container = documentView as? NativeTextViewContainer else {
            return super.intrinsicContentSize
        }
        return NSSize(width: NSView.noIntrinsicMetric, height: container.scrollableContentHeight)
    }

    /// Offset waiting for geometry. `updateNSView` runs on a SwiftUI state tick, where
    /// the clip view can still be zero-height — a scroll applied there is accepted
    /// verbatim (nothing to clamp against) and then discarded by the first real layout.
    /// Restores are therefore handed here and applied from `layout()`, which is the
    /// first moment the viewport and document heights actually exist.
    private var pendingRestoreY: CGFloat?
    /// Layout passes left to land it. The document keeps growing for a few passes after
    /// a remount, so the first laid-out pass can still be too short for the offset.
    private var pendingRestoreLayouts = 0
    /// A pass budget is not a time bound: passes only tick when one happens, so an
    /// offset that never lands stays armed indefinitely and a much later relayout —
    /// a find match, ⌘+, a window resize — replays it onto a reader who has long
    /// since gone somewhere else. Restoring is only ever correct immediately after
    /// the document arrives.
    private var pendingRestoreDeadline: Date?

    /// Restore `y` once the geometry can carry it.
    func armScrollRestore(to y: CGFloat) {
        guard !fitsContent else { return }
        pendingRestoreY = y
        pendingRestoreLayouts = 8
        pendingRestoreDeadline = Date(timeIntervalSinceNow: 1.0)
    }

    /// The reader (or something acting for them) moved the viewport — that position
    /// wins over anything still queued. Every path that scrolls the clip view
    /// directly must call this: find-match reveal, keyboard paging, drag-select
    /// autoscroll. They bypass `scrollWheel` entirely.
    func cancelPendingScrollRestore() {
        pendingRestoreY = nil
        pendingRestoreDeadline = nil
    }

    override func layout() {
        super.layout()
        guard let y = pendingRestoreY else { return }
        if let deadline = pendingRestoreDeadline, Date() > deadline {
            cancelPendingScrollRestore()
            return
        }
        guard contentView.bounds.height > 0 else { return }
        pendingRestoreLayouts -= 1
        contentView.scroll(to: NSPoint(x: contentView.bounds.origin.x, y: y))
        reflectScrolledClipView(contentView)
        clampToInsets()
        let landed = abs(contentView.bounds.origin.y - y) < 1
        if landed || pendingRestoreLayouts <= 0 { cancelPendingScrollRestore() }
    }

    override func scrollWheel(with event: NSEvent) {
        // The reader took over; never yank them back to a remembered offset.
        cancelPendingScrollRestore()
        if fitsContent {
            // No scrollable range — forward to the responder chain so the
            // enclosing (SwiftUI) scroll view receives the event. In the
            // standard SwiftUI hosting layout nextResponder is the clip view's
            // superview; if the hosting hierarchy ever differs, AppKit's
            // default responder-chain traversal still routes the event up.
            nextResponder?.scrollWheel(with: event)
            return
        }
        super.scrollWheel(with: event)
        clampToInsets()
    }

    override func viewWillStartLiveResize() {
        super.viewWillStartLiveResize()
        isLiveResizeActive = true
        isAwaitingPostLiveResizeWidthUpdate = false
        guard !fitsContent else { return }
        scrollYBeforeLiveResize = contentView.bounds.origin.y
    }

    override func viewDidEndLiveResize() {
        super.viewDidEndLiveResize()
        isLiveResizeActive = false
        nativeTextView?.flushPendingTableWidthChangeUpdate()
        // A lagging SwiftUI document view is observable as a width mismatch.
        // Keep synchronous table rendering armed until that concrete geometry
        // propagation is consumed; never guess its delivery time with a timer.
        isAwaitingPostLiveResizeWidthUpdate = hasUnpropagatedLiveResizeWidth
        guard !fitsContent else { return }
        if let y = scrollYBeforeLiveResize {
            contentView.scroll(to: NSPoint(x: contentView.bounds.origin.x, y: y))
            reflectScrolledClipView(contentView)
            clampToInsets()
        }
        scrollYBeforeLiveResize = nil
    }

    func clampToInsets() {
        guard !fitsContent else { return }
        guard let doc = documentView else { return }
        let minY = -contentInsets.top
        // Use the real content height (not the inflated frame) so small
        // documents can't scroll past their actual content. The document view is
        // always a `NativeTextViewContainer` (header band + text column).
        let container = doc as? NativeTextViewContainer
        var realHeight = container?.scrollableContentHeight ?? doc.bounds.height
        let b = contentView.bounds

        // `scrollableContentHeight` comes from a cached TextKit-2 measurement that can
        // under-measure. A continuous trackpad refreshes it mid-gesture, but a discrete
        // device (mouse wheel, Ploopy trackball) sends one event with no relayout — so a
        // stale-small height clamps the tick straight back = "scroll doesn't work". When
        // a clamp-back is imminent, force one fresh full-layout re-measure first. This is
        // self-limiting (only at the bottom) and still clamps to the real content height.
        if let textView = container?.textView,
           b.origin.y > realHeight - b.height {
            textView.pendingFullLayoutMeasure = true
            textView.recalcOverscroll(for: self)
            realHeight = container?.scrollableContentHeight ?? doc.bounds.height
        }

        let maxY = max(minY, realHeight - contentView.bounds.height)
        let clampedY = min(max(b.origin.y, minY), maxY)
        if clampedY != b.origin.y {
            contentView.scroll(to: NSPoint(x: b.origin.x, y: clampedY))
            reflectScrolledClipView(contentView)
        }
    }
}
