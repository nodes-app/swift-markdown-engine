//
//  ClampedScrollView.swift
//  MarkdownEngine
//
//  Created by Luca Chen on 18.02.26.
//

// Scroll view that keeps vertical scrolling within a clean top and bottom range.
import AppKit

final class ClampedScrollView: NSScrollView {
    /// Saved at the start of every live-resize (including spurious one-click resizes triggered by edge-cursor clicks) so the position is restored when the resize ends. Without this, NSScrollView's default top-anchor-during-resize would jolt a bottom-anchored user back up by hundreds of points on a single edge click.
    private var scrollYBeforeLiveResize: CGFloat?

    override func scrollWheel(with event: NSEvent) {
        super.scrollWheel(with: event)
        clampToInsets()
    }

    override func viewWillStartLiveResize() {
        super.viewWillStartLiveResize()
        scrollYBeforeLiveResize = contentView.bounds.origin.y
    }

    override func viewDidEndLiveResize() {
        super.viewDidEndLiveResize()
        if let y = scrollYBeforeLiveResize {
            contentView.scroll(to: NSPoint(x: contentView.bounds.origin.x, y: y))
            reflectScrolledClipView(contentView)
            clampToInsets()
        }
        scrollYBeforeLiveResize = nil
    }

    func clampToInsets() {
        guard let doc = documentView else { return }
        let minY = -contentInsets.top
        // Use the real content height (not the inflated frame) so small
        // documents can't scroll past their actual content.
        let realHeight = (doc as? NativeTextView)?.scrollableContentHeight ?? doc.bounds.height
        let maxY = max(minY, realHeight - contentView.bounds.height)
        let b = contentView.bounds
        let clampedY = min(max(b.origin.y, minY), maxY)
        if clampedY != b.origin.y {
            contentView.scroll(to: NSPoint(x: b.origin.x, y: clampedY))
            reflectScrolledClipView(contentView)
        }
    }
}
