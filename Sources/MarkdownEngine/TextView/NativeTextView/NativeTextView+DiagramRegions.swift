//
//  NativeTextView+DiagramRegions.swift
//  MarkdownEngine
//
//  Exposes where rendered diagram blocks are displayed, so an embedder can
//  attach its own decorations (badges, pins, highlights) over each diagram.
//  The geometry mirrors the fragment's own image drawing, so decorations land
//  exactly on the rendered image. Companion to the code-block seam
//  (`onCodeBlockSelectionChange` / `CodeBlockButton`), but AppKit-level: wide
//  diagrams live inside a horizontal-scrolling overlay, so decorations must be
//  able to join that overlay's view hierarchy to track its scroll.
//

import AppKit

/// One rendered diagram block and where its image is displayed.
public struct RenderedDiagramRegion {
    /// The fenced block's source text (identifies the diagram).
    public let source: String
    /// The view decorations should be added to: the text view itself for an
    /// inline-drawn diagram, or the scrollable overlay's document view for a
    /// wide diagram (so decorations track the image through horizontal
    /// scrolling).
    public let container: NSView
    /// The image's display frame within `container`.
    public let frame: CGRect
}

public extension NSTextView {
    /// Rendered diagram blocks in document order with their display geometry.
    /// Empty when diagrams render as raw fences (the feature off, or
    /// marker-visible mode) — and for text views not created by this engine.
    func renderedDiagramRegions() -> [RenderedDiagramRegion] {
        (self as? NativeTextView)?.diagramRegions() ?? []
    }
}

extension NativeTextView {

    func diagramRegions() -> [RenderedDiagramRegion] {
        guard let ts = textStorage, ts.length > 0,
              let tlm = textLayoutManager,
              let tcs = textContentStorage else { return [] }
        let full = NSRange(location: 0, length: ts.length)

        // Cheap presence check first, so documents without diagrams skip the
        // full-document layout pass entirely.
        var hasAny = false
        ts.enumerateAttribute(.mermaidSource, in: full, options: []) { v, _, stop in
            if v != nil { hasAny = true; stop.pointee = true }
        }
        guard hasAny else { return [] }

        // Settle layout before measuring — stale fragments would yield wrong
        // frames (same pattern as the wide-table overlay reconcile).
        tlm.ensureLayout(for: tlm.documentRange)

        var regions: [RenderedDiagramRegion] = []
        ts.enumerateAttribute(.mermaidSource, in: full, options: []) { value, range, _ in
            guard let source = value as? String else { return }
            // The rendered image rides a one-character anchor inside the
            // block's range (see `emitCollapsedAttrs`); find it.
            var anchorLoc: Int?
            ts.enumerateAttribute(.latexImage, in: range, options: []) { v, r, stop in
                if v is NSImage { anchorLoc = r.location; stop.pointee = true }
            }
            guard let loc = anchorLoc else { return }

            // Wide block → the image is hosted in its overlay's document view
            // at natural size; decorations belong there so they scroll with it.
            if let id = ts.attribute(.scrollableBlockSourceID, at: loc, effectiveRange: nil) as? Int {
                guard let overlay = wideTableOverlays[id], let doc = overlay.documentView else { return }
                regions.append(RenderedDiagramRegion(source: source, container: doc, frame: doc.bounds))
                return
            }

            // Inline-drawn image → fragment-local frame, translated into the
            // text view's coordinate space.
            guard let start = tcs.location(tcs.documentRange.location, offsetBy: loc),
                  let fragment = tlm.textLayoutFragment(for: start) as? MarkdownTextLayoutFragment,
                  let local = fragment.blockImageFrame(forCharacterAt: loc) else { return }
            let fragFrame = fragment.layoutFragmentFrame
            regions.append(RenderedDiagramRegion(
                source: source,
                container: self,
                frame: CGRect(x: textContainerOrigin.x + fragFrame.minX + local.minX,
                              y: textContainerOrigin.y + fragFrame.minY + local.minY,
                              width: local.width, height: local.height)))
        }
        return regions
    }
}
