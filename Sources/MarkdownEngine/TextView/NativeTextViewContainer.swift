//
//  NativeTextViewContainer.swift
//  MarkdownEngine
//
//  Document view of the editor's scroll view. Hosts the `NativeTextView` plus two
//  optional siblings: the scroll-away header (a top band, stacked ABOVE the text view
//  with a disjoint frame) and, in reading-column mode, the full-width wide-table
//  overlays around the centered fixed-width column.
//
//  The header is a sibling rather than a subview of the text view because a subview
//  (reserving space via a `textContainerOrigin` shift) cannot be composited reliably:
//  during a responsive-scroll blit the cached body bitmap and the header's own
//  `NSHostingView` layer advance against slightly different origins, so the body
//  drifts up over the header's lower rows. No compositing fix can unify them
//  (NSHostingView always forces its own layer); with disjoint sibling frames the
//  overlap is geometrically impossible.
//
//  The text view sits at the container's ORIGIN; the header band and the reading
//  column's offset are the container's bounds origin (#205). AppKit's Writing Tools
//  overlay draws in text-view coordinates against the container's origin, so a text
//  view offset inside it got its proofreading words drawn that far up and left.
//  Auto Layout ignores the bounds origin, so the header clip's constraints carry it.
//

import AppKit

final class NativeTextViewContainer: NSView {
    /// The body. Sizes its OWN height (content + overscroll); the container only shows
    /// it below the header band and sizes itself to the sum.
    weak var textView: NativeTextView?

    /// Reserved header band height (mirrors the clip's resolved height). Sole driver of
    /// the vertical stack: the text view shows at `y = headerHeight`.
    var headerHeight: CGFloat = 0 {
        didSet {
            guard abs(headerHeight - oldValue) > 0.01 else { return }
            if let textView {
                // Band height feeds the overscroll activation — re-run the policy
                // first (no re-measure; skipped when detached, e.g. teardown).
                if let scrollView = enclosingScrollView {
                    textView.reapplyOverscrollPolicy(for: scrollView)
                }
                // The viewport-fill inflation depends on the band height
                // (header + text view ≥ viewport); re-apply before the restack so a
                // short doc never grows a phantom scroll range.
                textView.applyManagedFrameSize(width: textView.frame.width)
            }
            restack(propagateWidth: false)
        }
    }

    private var isRestacking = false

    /// Where the reading column shows, from the container's left edge (0 in full width).
    private(set) var columnOriginX: CGFloat = 0

    /// The header clip's position constraints, which carry the bounds origin.
    private var headerPins: (top: NSLayoutConstraint, left: NSLayoutConstraint,
                             right: NSLayoutConstraint)?
    private weak var headerClip: NSView?

    func pinHeader(_ clip: NSView, top: NSLayoutConstraint, left: NSLayoutConstraint,
                   right: NSLayoutConstraint) {
        headerClip = clip
        headerPins = (top, left, right)
        applyBoundsOrigin()
    }

    func unpinHeader() {
        headerClip = nil
        headerPins = nil
    }

    func setColumnOriginX(_ x: CGFloat) {
        guard x != columnOriginX else { return }
        columnOriginX = x
        applyBoundsOrigin()
    }

    /// Shows the text view at `(columnOriginX, headerHeight)` while it stays at (0, 0).
    private func applyBoundsOrigin() {
        let origin = NSPoint(x: -columnOriginX, y: -headerHeight)
        if bounds.origin != origin { setBoundsOrigin(origin) }
        guard let headerPins else { return }
        headerPins.top.constant = origin.y
        headerPins.left.constant = origin.x
        headerPins.right.constant = origin.x
        // Placed now as well: the next layout pass would leave it one frame behind the band.
        headerClip?.setFrameOrigin(origin)
    }

    /// Flipped (top-left origin) to match `NSTextView`, so the header band is the
    /// negative bounds origin above it and the text view's local space IS the
    /// container's. A non-flipped container would invert the stack and break every
    /// `convert(_:to:)`-based coordinate path.
    override var isFlipped: Bool { true }

    /// Real scrollable height = header band + the text view's real content (no
    /// min-viewport inflation), so the scroll view can't scroll past actual content.
    var scrollableContentHeight: CGFloat {
        headerHeight + (textView?.scrollableContentHeight ?? 0)
    }

    /// Single layout method. Shows the text view below the header (bounds origin only —
    /// never `setFrameSize`, so the text view's self-measure isn't re-triggered) and sizes the
    /// container to `headerHeight + textViewHeight` (min the viewport). The header clip
    /// keeps its own height; its position follows the bounds origin through its pins.
    func restack(propagateWidth: Bool) {
        guard !isRestacking, let textView else { return }
        isRestacking = true
        defer { isRestacking = false }

        let w = bounds.width
        // Width propagation happens ONLY from the scroll-view-driven path; a height-only
        // restack must never resize the text view (that would re-measure → loop).
        if propagateWidth {
            if textView.configuration.readingWidth != nil {
                // Reading column: the column keeps its fixed width; re-center its X
                // (and shift the wide-table overlay insets) instead of resizing.
                textView.centerReadingColumn(forClipWidth: w)
            } else if textView.frame.width != w {
                textView.setFrameSize(NSSize(width: w, height: textView.frame.height))
            }
        }
        // Below the header band and at the column's X, through the bounds origin.
        if textView.frame.origin != .zero { textView.setFrameOrigin(.zero) }
        if textView.configuration.readingWidth == nil { columnOriginX = 0 }
        applyBoundsOrigin()
        let viewportH = enclosingScrollView?.contentView.bounds.height ?? 0
        let stacked = headerHeight + textView.frame.height
        let totalH = (textView.configuration.heightBehavior == .fitsContent) ? stacked
                                                                              : max(stacked, viewportH)
        if abs(frame.height - totalH) > 0.5 {
            setFrameSize(NSSize(width: w, height: totalH))
        }
    }

    /// The text view calls this after it self-resizes its height.
    func textViewDidResize() {
        guard !isRestacking else { return }
        restack(propagateWidth: false)
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        // Width came from the scroll view's clip view (autoresizing); propagate it.
        restack(propagateWidth: true)
    }
}

extension NSScrollView {
    /// Editor text view inside the container document view.
    var nativeTextView: NativeTextView? {
        (documentView as? NativeTextViewContainer)?.textView
    }
}

extension NSView {
    /// `rect` in the enclosing clip view's space, the one scroll offsets are in.
    func rectInClipView(_ rect: NSRect) -> NSRect {
        guard let clip = enclosingScrollView?.contentView else { return rect }
        return convert(rect, to: clip)
    }
}
