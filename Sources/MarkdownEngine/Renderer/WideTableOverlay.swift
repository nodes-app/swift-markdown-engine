//
//  WideTableOverlay.swift
//  MarkdownEngine
//
//  NSScrollView subview of NativeTextView hosting a wide-table image with
//  native horizontal scrolling. Sidesteps TextKit 2's fragment surface
//  cache that defeats in-fragment custom scrolling.
//

import AppKit

// MARK: - Overlay view

final class WideTableOverlay: NSScrollView {

    /// Hash of table source; key for offset persistence + reconcile lookup.
    let sourceID: Int

    /// Document index of the table anchor; click on image moves caret here.
    var anchorTextLocation: Int

    /// Weak parent ref for offset persistence + caret forwarding.
    weak var ownerTextView: NativeTextView?

    private let tableImageView: WideTableImageView

    init(sourceID: Int, image: NSImage, ownerTextView: NativeTextView, anchorLocation: Int) {
        self.sourceID = sourceID
        self.anchorTextLocation = anchorLocation
        self.ownerTextView = ownerTextView
        self.tableImageView = WideTableImageView(frame: CGRect(origin: .zero, size: image.size))
        tableImageView.image = image
        tableImageView.imageScaling = .scaleNone
        tableImageView.imageAlignment = .alignTopLeft

        super.init(frame: .zero)

        hasHorizontalScroller = true
        hasVerticalScroller = false
        autohidesScrollers = false
        borderType = .noBorder
        drawsBackground = false
        scrollerStyle = .legacy
        horizontalScrollElasticity = .allowed
        verticalScrollElasticity = .none
        usesPredominantAxisScrolling = true
        horizontalScroller?.controlSize = .small

        documentView = tableImageView
        tableImageView.ownerOverlay = self

        NotificationCenter.default.addObserver(
            self, selector: #selector(scrollOffsetDidChange),
            name: NSScrollView.didLiveScrollNotification, object: self
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(scrollOffsetDidChange),
            name: NSScrollView.didEndLiveScrollNotification, object: self
        )
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    deinit { NotificationCenter.default.removeObserver(self) }

    /// Clamp vertical scroll to 0 on every layout — kills sub-pixel wobble.
    override func tile() {
        super.tile()
        let origin = contentView.bounds.origin
        if origin.y != 0 {
            contentView.scroll(to: NSPoint(x: origin.x, y: 0))
            reflectScrolledClipView(contentView)
        }
    }

    /// Forward everything except clearly-horizontal events to the outer
    /// document scroll. Zero-delta phase/momentum lifecycle events count
    /// as "not horizontal" so the outer scroll view still receives the
    /// gesture-ended notifications it needs to stop cleanly.
    override func scrollWheel(with event: NSEvent) {
        if abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY) {
            super.scrollWheel(with: event)
        } else {
            nextResponder?.scrollWheel(with: event)
        }
    }

    /// Swap the rendered image after a restyle regenerated it.
    func updateImage(_ image: NSImage) {
        if tableImageView.image !== image {
            tableImageView.image = image
            tableImageView.frame = CGRect(origin: .zero, size: image.size)
        }
    }

    var horizontalOffset: CGFloat {
        get { contentView.bounds.origin.x }
        set {
            contentView.scroll(to: NSPoint(x: max(0, newValue), y: 0))
            reflectScrolledClipView(contentView)
        }
    }

    @objc private func scrollOffsetDidChange() {
        ownerTextView?.tableHorizontalScrollOffsets[sourceID] = horizontalOffset
    }
}

// MARK: - Document view inside the overlay

/// Forwards mouseDown to caret-into-table (so clicking switches to edit mode) —
/// unless the block carries an activation source (e.g. a rendered diagram), in
/// which case it fires the activate callback instead. Wide blocks live inside
/// this scroll-view subview, so a click here never reaches the text view's own
/// mouseDown; the activation has to be re-dispatched from here.
final class WideTableImageView: NSImageView {

    weak var ownerOverlay: WideTableOverlay?

    override func mouseDown(with event: NSEvent) {
        guard let overlay = ownerOverlay,
              let textView = overlay.ownerTextView else {
            super.mouseDown(with: event)
            return
        }
        let location = overlay.anchorTextLocation
        let docLen = (textView.string as NSString).length
        guard location >= 0, location <= docLen else {
            super.mouseDown(with: event)
            return
        }
        // A wide rendered block tagged with an activation source (a diagram)
        // opens its zoom view on click, matching the narrow/inline path; only
        // un-tagged wide blocks (plain wide tables) fall through to edit-mode.
        if location < docLen,
           let src = textView.textStorage?.attribute(.mermaidSource, at: location, effectiveRange: nil) as? String,
           let coord = textView.delegate as? NativeTextViewCoordinator,
           let activate = coord.onMermaidActivate {
            activate(src)
            return
        }
        textView.window?.makeFirstResponder(textView)
        textView.setSelectedRange(NSRange(location: location, length: 0))
    }
}

// MARK: - NativeTextView reconcile extension

extension NativeTextView {

    /// Walk storage; create / position / destroy overlays to match attrs.
    /// Doubles as the "rendered layout settled" beat: after the reconcile, the
    /// embedder is notified so its own block decorations (see
    /// `renderedDiagramRegions()`) can reposition on the same cadence.
    func updateWideTableOverlays() {
        reconcileWideTableOverlays()
        (delegate as? NativeTextViewCoordinator)?.onRenderedLayoutChange?()
    }

    private func reconcileWideTableOverlays() {
        guard let storage = textStorage,
              let bridge = layoutBridge,
              let container = bridge.firstTextContainer,
              let tlm = textLayoutManager,
              let tcs = tlm.textContentManager as? NSTextContentStorage else {
            removeAllWideTableOverlays()
            return
        }

        let containerWidth = container.size.width
        guard containerWidth.isFinite, containerWidth > 0 else { return }

        var seenSourceIDs: Set<Int> = []
        let fullRange = NSRange(location: 0, length: storage.length)

        // Cheap presence-check first: skip the full-document layout pass when
        // the doc has no wide tables. enumerateAttribute stops on first hit.
        var hasAnyWideTable = false
        storage.enumerateAttribute(.scrollableBlockSourceID, in: fullRange, options: []) { value, _, stop in
            if value is Int { hasAnyWideTable = true; stop.pointee = true }
        }
        guard hasAnyWideTable else {
            removeAllWideTableOverlays()
            return
        }

        // Settle layout before measuring — stale fragments would yield wrong anchor Ys.
        tlm.ensureLayout(for: tlm.documentRange)

        storage.enumerateAttribute(.scrollableBlockSourceID, in: fullRange, options: []) { value, attrRange, _ in
            guard let sourceID = value as? Int,
                  let image = storage.attribute(.latexImage, at: attrRange.location, effectiveRange: nil) as? NSImage else { return }
            seenSourceIDs.insert(sourceID)

            if let start = tcs.location(tcs.documentRange.location, offsetBy: attrRange.location),
               let end = tcs.location(start, offsetBy: attrRange.length),
               let textRange = NSTextRange(location: start, end: end) {
                tlm.ensureLayout(for: textRange)
            }

            let anchorRect = bridge.boundingRect(forCharacterRange: attrRange, in: container)
            guard !anchorRect.isEmpty else { return }

            let totalHeight = (storage.attribute(.scrollableBlockTotalHeight, at: attrRange.location, effectiveRange: nil) as? CGFloat) ?? image.size.height
            let overlayFrame = NSRect(
                x: textContainerOrigin.x + anchorRect.minX,
                y: textContainerOrigin.y + anchorRect.minY,
                width: containerWidth,
                height: totalHeight
            )

            if let existing = wideTableOverlays[sourceID] {
                if !existing.frame.equalTo(overlayFrame) {
                    // Invalidate both old + new region so the vacated area redraws.
                    self.setNeedsDisplay(existing.frame)
                    existing.frame = overlayFrame
                    self.setNeedsDisplay(overlayFrame)
                }
                existing.updateImage(image)
                existing.anchorTextLocation = attrRange.location
            } else {
                let overlay = WideTableOverlay(
                    sourceID: sourceID, image: image,
                    ownerTextView: self, anchorLocation: attrRange.location
                )
                overlay.frame = overlayFrame
                addSubview(overlay)
                wideTableOverlays[sourceID] = overlay
                let savedOffset = tableHorizontalScrollOffsets[sourceID] ?? 0
                if savedOffset > 0 { overlay.horizontalOffset = savedOffset }
            }
        }

        for (sourceID, overlay) in wideTableOverlays where !seenSourceIDs.contains(sourceID) {
            self.setNeedsDisplay(overlay.frame)
            overlay.removeFromSuperview()
            wideTableOverlays.removeValue(forKey: sourceID)
        }
    }

    /// Drop all overlays synchronously (file switch path).
    func removeAllWideTableOverlays() {
        for (_, overlay) in wideTableOverlays { overlay.removeFromSuperview() }
        wideTableOverlays.removeAll()
    }
}
