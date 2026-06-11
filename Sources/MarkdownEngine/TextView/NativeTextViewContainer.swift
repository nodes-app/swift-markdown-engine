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

import AppKit

final class NativeTextViewContainer: NSView {
    /// The body. Sizes its OWN height (content + overscroll); the container only moves
    /// it below the header band and sizes itself to the sum.
    weak var textView: NativeTextView?

    /// Reserved header band height (mirrors the clip's resolved height). Sole driver of
    /// the vertical stack: the text view sits at `y = headerHeight`.
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

    /// Flipped (top-left origin) to match `NSTextView`, so `y = headerHeight` means
    /// "below the header" and the text view's local space is a pure translation of the
    /// container's. A non-flipped container would invert the stack and break every
    /// `convert(_:to:)`-based coordinate path.
    override var isFlipped: Bool { true }

    /// Real scrollable height = header band + the text view's real content (no
    /// min-viewport inflation), so the scroll view can't scroll past actual content.
    var scrollableContentHeight: CGFloat {
        headerHeight + (textView?.scrollableContentHeight ?? 0)
    }

    /// Single layout method. Moves the text view below the header (ORIGIN only — never
    /// `setFrameSize`, so the text view's self-measure isn't re-triggered) and sizes the
    /// container to `headerHeight + textViewHeight` (min the viewport). The header clip
    /// is positioned by its own Auto Layout against this container, so it isn't touched.
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
            } else if abs(textView.frame.width - w) > 0.5 {
                textView.setFrameSize(NSSize(width: w, height: textView.frame.height))
            }
        }
        // Y: below the header band. X is owned by the reading-column centering
        // (0 in full-width mode) — preserve it here.
        let x = textView.configuration.readingWidth != nil ? textView.frame.origin.x : 0
        if abs(textView.frame.origin.y - headerHeight) > 0.01 || abs(textView.frame.origin.x - x) > 0.01 {
            let deltaY = headerHeight - textView.frame.origin.y
            textView.setFrameOrigin(NSPoint(x: x, y: headerHeight))
            // Breakout wide-table overlays are siblings whose frames bake in the
            // text view's offset — keep them glued to their anchor paragraphs.
            textView.shiftWideTableOverlays(byY: deltaY)
        }
        let viewportH = enclosingScrollView?.contentView.bounds.height ?? 0
        let totalH = max(headerHeight + textView.frame.height, viewportH)
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
