//
//  MarkdownTextLayoutFragment.swift
//  MarkdownEngine
//
//  Created by Luca Chen on 12.04.26.
//
//  TextKit 2 replacement for CodeBlockLayoutManager.
//  Draws code-block backgrounds, LaTeX images, and task checkboxes
//  via NSTextLayoutFragment instead of NSLayoutManager glyph overrides.

import AppKit

// MARK: - Custom attribute keys for rendering overlays

extension NSAttributedString.Key {
    static let latexImage = NSAttributedString.Key("LatexRenderedImage")
    static let latexBounds = NSAttributedString.Key("LatexImageBounds")
    static let latexIsBlock = NSAttributedString.Key("LatexIsBlock")
    static let latexBlockOffsetY = NSAttributedString.Key("LatexBlockOffsetY")
    static let thematicBreak = NSAttributedString.Key("ThematicBreak")
    /// Int nesting level (1-based) of a blockquote line; the fragment
    /// paints that many vertical bars in the left gutter.
    static let blockquoteLevel = NSAttributedString.Key("BlockquoteLevel")
    /// Marks a bullet-list marker char (`-`/`*`/`+`) whose glyph is hidden so
    /// the fragment can paint a `•` in its place. Set to `true`.
    static let bulletMarker = NSAttributedString.Key("BulletListMarker")
    /// CGFloat — natural image width; presence flags block as overlay-rendered.
    static let scrollableBlockNaturalWidth = NSAttributedString.Key("ScrollableBlockNaturalWidth")
    /// Int — hash of source text; key for overlay reconcile + offset persistence.
    static let scrollableBlockSourceID = NSAttributedString.Key("ScrollableBlockSourceID")
    /// CGFloat — total reserved height (image + scroller strip) for overlay sizing.
    static let scrollableBlockTotalHeight = NSAttributedString.Key("ScrollableBlockTotalHeight")
    /// NSValue(range:) — full multi-line range of the wide-table source, used to scope width-change restyles.
    static let scrollableBlockFullRange = NSAttributedString.Key("ScrollableBlockFullRange")
}

final class MarkdownTextLayoutFragment: NSTextLayoutFragment {

    /// Horizontal space (points) each blockquote nesting level occupies —
    /// shared so the styler's text indent and the painted bars line up.
    static let blockquoteIndentPerLevel: CGFloat = 18
    static let blockquoteBarWidth: CGFloat = 3

    /// Strip below an overlay block for the legacy-small scroller (~11pt) + buffer.
    static let scrollableBlockScrollerStrip: CGFloat = 14

    // MARK: - FB15131180

    /// Maps to TextKit-2's private `extraLineFragmentAttributes` selector so we can pin the trailing extra-line metrics to body font; otherwise a trailing heading paragraph inflates `usageBoundsForTextContainer` by ~30pt when the caret enters it. Pattern from STTextView.
    @objc(extraLineFragmentAttributes)
    dynamic var stExtraLineFragmentAttributes: NSDictionary?

    // MARK: - Rendering surface

    /// Extend rendering bounds for code-block backgrounds (full container width)
    /// and block images drawn below text via paragraphSpacing.
    override var renderingSurfaceBounds: CGRect {
        var bounds = super.renderingSurfaceBounds
        if hasCodeBlockBackground || hasThematicBreak || hasBlockquote {
            let containerWidth = textLayoutManager?.textContainer?.size.width ?? bounds.width
            // Extend left to container edge
            bounds.origin.x = -layoutFragmentFrame.origin.x
            bounds.size.width = containerWidth
        }
        // Extend bounds to cover block images that render below the text line
        // (visibleSource mode uses paragraphSpacing to create space for the image).
        for rect in blockImageRects(at: .zero) {
            bounds = bounds.union(rect)
        }
        return bounds
    }

    // MARK: - Drawing

    override func draw(at point: CGPoint, in context: CGContext) {
        // 1. Code-block backgrounds (behind text)
        drawCodeBlockBackground(at: point, in: context)

        // 2. LaTeX images (behind text — hidden markers are invisible anyway)
        drawLatexImages(at: point, in: context)

        // 3. Normal text
        super.draw(at: point, in: context)

        // 4. Task checkboxes (on top of hidden [ ]/[x] markers)
        drawTaskCheckboxes(at: point, in: context)

        // 4b. Bullet glyphs (on top of hidden -/*/+ markers)
        drawBulletMarkers(at: point, in: context)

        // 5. Thematic breaks (full-width line, painted last so it doesn't
        //    fight with anything that already drew at the line's center)
        drawThematicBreaks(at: point, in: context)

        // 6. Blockquote bars (left gutter, behind nothing — text is indented)
        drawBlockquoteBars(at: point, in: context)
    }

    // MARK: - Helpers

    /// NSRange in the document for this fragment's content.
    private var fragmentNSRange: NSRange? {
        guard let tcs = textLayoutManager?.textContentManager as? NSTextContentStorage else { return nil }
        let start = tcs.offset(from: tcs.documentRange.location, to: rangeInElement.location)
        let end = tcs.offset(from: tcs.documentRange.location, to: rangeInElement.endLocation)
        guard start != NSNotFound, end != NSNotFound, end > start else { return nil }
        return NSRange(location: start, length: end - start)
    }

    private var textStorage: NSTextStorage? {
        (textLayoutManager?.textContentManager as? NSTextContentStorage)?.textStorage
    }

    /// Returns the drawing position for a character at `docIndex` (document-level NSRange location).
    /// `point` is the draw origin passed to `draw(at:in:)`.
    private func drawPosition(forDocumentCharAt docIndex: Int, point: CGPoint) -> (x: CGFloat, baselineY: CGFloat, lineHeight: CGFloat)? {
        guard let fragRange = fragmentNSRange else { return nil }
        let localIndex = docIndex - fragRange.location
        guard localIndex >= 0 else { return nil }

        // NSTextLineFragment.typographicBounds.origin.y is already relative to the
        // parent layout fragment, so we use it directly — accumulating per-line
        // heights would double-count the inter-line offset on wrapped lines.
        for lineFragment in textLineFragments {
            let lr = lineFragment.characterRange
            if localIndex >= lr.location && localIndex < lr.location + lr.length {
                let charPos = lineFragment.locationForCharacter(at: localIndex)
                let tb = lineFragment.typographicBounds
                return (
                    x: point.x + tb.origin.x + charPos.x,
                    baselineY: point.y + tb.origin.y + charPos.y,
                    lineHeight: tb.height
                )
            }
        }
        return nil
    }

    /// Typographic bounds of the line fragment containing `localIndex`
    /// (index relative to the fragment, not the document).
    private func lineBounds(forLocalIndex localIndex: Int, point: CGPoint) -> CGRect? {
        for lineFragment in textLineFragments {
            let lr = lineFragment.characterRange
            if localIndex >= lr.location && localIndex < lr.location + lr.length {
                let tb = lineFragment.typographicBounds
                return CGRect(x: point.x + lineFragment.glyphOrigin.x + tb.origin.x,
                              y: point.y + tb.origin.y,
                              width: tb.width,
                              height: tb.height)
            }
        }
        return nil
    }

    // MARK: - Code Block Background

    private var hasCodeBlockBackground: Bool {
        guard let ts = textStorage, let range = fragmentNSRange, range.length > 0 else { return false }
        let bgColor = ts.attribute(.backgroundColor, at: range.location, effectiveRange: nil) as? NSColor
        guard let bgColor else { return false }
        return isCodeBlockBackgroundColor(bgColor)
    }

    private var hasThematicBreak: Bool {
        guard let ts = textStorage, let range = fragmentNSRange, range.length > 0 else { return false }
        var found = false
        ts.enumerateAttribute(.thematicBreak, in: range, options: []) { value, _, stop in
            if value as? Bool == true {
                found = true
                stop.pointee = true
            }
        }
        return found
    }

    private var hasBlockquote: Bool {
        guard let ts = textStorage, let range = fragmentNSRange, range.length > 0 else { return false }
        var found = false
        ts.enumerateAttribute(.blockquoteLevel, in: range, options: []) { value, _, stop in
            if value is Int {
                found = true
                stop.pointee = true
            }
        }
        return found
    }

    private func drawCodeBlockBackground(at point: CGPoint, in context: CGContext) {
        guard let ts = textStorage, let range = fragmentNSRange, range.length > 0 else { return }

        // Only fenced code-block fragments get the full-width fill (first char must carry the code background).
        guard let color = ts.attribute(.backgroundColor, at: range.location, effectiveRange: nil) as? NSColor,
              isCodeBlockBackgroundColor(color) else { return }

        let containerWidth = textLayoutManager?.textContainer?.size.width ?? layoutFragmentFrame.width

        var effectiveHeight = layoutFragmentFrame.height
        if textLineFragments.count > 1,
           let lastLF = textLineFragments.last,
           lastLF.characterRange.length == 0 {
            effectiveHeight -= lastLF.typographicBounds.height
        }

        let scale = textLayoutManager?.textContainer?.textView?.window?.backingScaleFactor
            ?? NSScreen.main?.backingScaleFactor ?? 2.0
        let rawY = point.y
        let rawMaxY = point.y + effectiveHeight
        let snappedY = floor(rawY * scale) / scale
        let snappedMaxY = ceil(rawMaxY * scale) / scale

        // Draw full-width background, clipping out any active selection rects
        // so the system's blue selection highlight remains visible inside code blocks.
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        let nsContext = NSGraphicsContext(cgContext: context, flipped: true)
        NSGraphicsContext.current = nsContext

        let bgRect = CGRect(
            x: point.x - layoutFragmentFrame.origin.x,
            y: snappedY,
            width: containerWidth,
            height: snappedMaxY - snappedY
        )

        let selectionRects = selectionRectsInDrawCoordinates(drawPoint: point, snappedY: snappedY, snappedMaxY: snappedMaxY)
        color.setFill()
        if selectionRects.isEmpty {
            NSBezierPath(rect: bgRect).fill()
        } else {
            let path = NSBezierPath()
            path.windingRule = .evenOdd
            path.appendRect(bgRect)
            for r in selectionRects {
                path.appendRect(r.intersection(bgRect))
            }
            path.fill()
        }

        // Optional border. Sides are drawn on every segment; top/bottom only at the
        // block's real top/bottom — a code block can span multiple layout fragments,
        // so detect the boundary by whether the neighbouring char still carries the
        // code background (a continuation) or not (a block edge).
        let theme = (textLayoutManager?.textContainer?.textView as? NativeTextView)?.configuration.theme
        if let borderColor = theme?.codeBlockBorder, let bw = theme?.codeBlockBorderWidth, bw > 0 {
            func continuesCodeBg(at idx: Int) -> Bool {
                guard idx >= 0, idx < ts.length,
                      let c = ts.attribute(.backgroundColor, at: idx, effectiveRange: nil) as? NSColor
                else { return false }
                return isCodeBlockBackgroundColor(c)
            }
            let half = bw / 2
            let left = bgRect.minX + half
            let right = bgRect.maxX - half
            let path = NSBezierPath()
            path.lineWidth = bw
            path.move(to: CGPoint(x: left, y: bgRect.minY));  path.line(to: CGPoint(x: left, y: bgRect.maxY))
            path.move(to: CGPoint(x: right, y: bgRect.minY)); path.line(to: CGPoint(x: right, y: bgRect.maxY))
            if !continuesCodeBg(at: range.location - 1) {
                path.move(to: CGPoint(x: bgRect.minX, y: bgRect.minY + half))
                path.line(to: CGPoint(x: bgRect.maxX, y: bgRect.minY + half))
            }
            if !continuesCodeBg(at: NSMaxRange(range)) {
                path.move(to: CGPoint(x: bgRect.minX, y: bgRect.maxY - half))
                path.line(to: CGPoint(x: bgRect.maxX, y: bgRect.maxY - half))
            }
            borderColor.setStroke()
            path.stroke()
        }
    }

    /// Returns active text-selection rectangles intersecting this fragment, in
    /// the same draw-relative coordinate system used by `drawCodeBlockBackground`.
    private func selectionRectsInDrawCoordinates(drawPoint: CGPoint, snappedY: CGFloat, snappedMaxY: CGFloat) -> [CGRect] {
        guard let tlm = textLayoutManager else { return [] }
        var rects: [CGRect] = []

        let dx = drawPoint.x - layoutFragmentFrame.origin.x
        let myRange = self.rangeInElement

        for selection in tlm.textSelections {
            for textRange in selection.textRanges {
                let interStart = textRange.location.compare(myRange.location) == .orderedAscending
                    ? myRange.location : textRange.location
                let interEnd = textRange.endLocation.compare(myRange.endLocation) == .orderedDescending
                    ? myRange.endLocation : textRange.endLocation
                guard interStart.compare(interEnd) == .orderedAscending,
                      let intersection = NSTextRange(location: interStart, end: interEnd) else { continue }

                tlm.enumerateTextSegments(in: intersection, type: .selection, options: []) { _, segFrame, _, _ in
                    // Expand vertically to match the bgRect's snapped span so the
                    // even-odd cut-out is geometrically congruent with the fill.
                    let drawRect = CGRect(
                        x: segFrame.origin.x + dx,
                        y: snappedY,
                        width: segFrame.width,
                        height: snappedMaxY - snappedY
                    )
                    rects.append(drawRect)
                    return true
                }
            }
        }
        return rects
    }

    private func isCodeBlockBackgroundColor(_ color: NSColor) -> Bool {
        // Fenced code blocks carry the theme's code-block background (full-width
        // fill); inline `code` carries a different fill, so this distinguishes
        // them (inline code must NOT get the gutter-to-gutter fill).
        let currentBg = (textLayoutManager?.textContainer?.textView as? NativeTextView)?
            .configuration.theme.codeBlockBackground ?? MarkdownEditorTheme.default.codeBlockBackground
        guard let colorRGB = color.usingColorSpace(.deviceRGB),
              let currentBgRGB = currentBg.usingColorSpace(.deviceRGB) else { return false }
        let tolerance: CGFloat = 0.03
        return abs(colorRGB.redComponent - currentBgRGB.redComponent) < tolerance &&
               abs(colorRGB.greenComponent - currentBgRGB.greenComponent) < tolerance &&
               abs(colorRGB.blueComponent - currentBgRGB.blueComponent) < tolerance
    }

    // MARK: - LaTeX / Block Image Helpers

    /// Compute the draw rect for a block image at `attrRange` using `point` as
    /// the draw origin.  Shared by `drawLatexImages` and `blockImageRects` so
    /// bounds and rendering stay in sync.
    private func blockImageDrawRect(
        attrRange: NSRange,
        imageBounds: CGRect,
        blockOffsetY: CGFloat?,
        point: CGPoint
    ) -> CGRect? {
        guard let pos = drawPosition(forDocumentCharAt: attrRange.location, point: point) else { return nil }
        let fragLocation = fragmentNSRange?.location ?? 0
        let localStart = attrRange.location - fragLocation
        let localLast = max(localStart, localStart + attrRange.length - 1)
        let firstLb = lineBounds(forLocalIndex: localStart, point: point)
        // For a wrapped source span (e.g. a long `![alt](url)` that wraps in
        // a narrow window), anchor to the LAST line's maxY so the image
        // doesn't paint over subsequent wrapped lines of its own source.
        let lastLb = lineBounds(forLocalIndex: localLast, point: point) ?? firstLb
        let lineHeight = firstLb?.height ?? pos.lineHeight
        let firstLineMinY = firstLb?.origin.y ?? (pos.baselineY - lineHeight)
        let lastLineMaxY = (lastLb?.origin.y ?? firstLineMinY) + (lastLb?.height ?? lineHeight)

        let yPosition: CGFloat
        if let blockOffsetY {
            // Backward-compatible interpretation: `blockOffsetY` is the gap
            // from the FIRST line's top to the image's top (= baseLineHeight
            // + imageGap on a single-line source). Re-anchor to the last
            // line by subtracting one line height, leaving the same single-
            // line geometry intact while pushing the image down by one
            // extra line per wrap.
            yPosition = lastLineMaxY + blockOffsetY - lineHeight
        } else {
            yPosition = firstLineMinY + (lineHeight - imageBounds.height) / 2
        }
        return CGRect(x: pos.x, y: yPosition,
                       width: imageBounds.width, height: imageBounds.height)
    }

    /// Returns the rects of all block images in this fragment, relative to
    /// `point`.  Used by `renderingSurfaceBounds` (with `.zero`) to extend
    /// the surface so images drawn in paragraphSpacing aren't clipped.
    private func blockImageRects(at point: CGPoint) -> [CGRect] {
        guard let ts = textStorage, let range = fragmentNSRange, range.length > 0 else { return [] }
        var rects: [CGRect] = []
        ts.enumerateAttribute(.latexImage, in: range, options: []) { value, attrRange, _ in
            guard value is NSImage else { return }
            let isBlock = ts.attribute(.latexIsBlock, at: attrRange.location, effectiveRange: nil) as? Bool ?? false
            guard isBlock else { return }
            // Skip overlay blocks; surface bounds must stay within container.
            if ts.attribute(.scrollableBlockNaturalWidth, at: attrRange.location, effectiveRange: nil) != nil {
                return
            }
            let boundsVal = ts.attribute(.latexBounds, at: attrRange.location, effectiveRange: nil) as? NSValue
            let imageBounds = boundsVal?.rectValue ?? .zero
            let blockOffsetY = ts.attribute(.latexBlockOffsetY, at: attrRange.location, effectiveRange: nil) as? CGFloat
            if let rect = blockImageDrawRect(attrRange: attrRange, imageBounds: imageBounds, blockOffsetY: blockOffsetY, point: point) {
                rects.append(rect)
            }
        }
        return rects
    }

    // MARK: - LaTeX Images

    private func drawLatexImages(at point: CGPoint, in context: CGContext) {
        guard let ts = textStorage, let range = fragmentNSRange, range.length > 0 else { return }

        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        let nsContext = NSGraphicsContext(cgContext: context, flipped: true)
        NSGraphicsContext.current = nsContext

        ts.enumerateAttribute(.latexImage, in: range, options: []) { [weak self] value, attrRange, _ in
            guard let self, let image = value as? NSImage else { return }

            // Skip overlay-rendered blocks; WideTableOverlay owns the visual.
            if ts.attribute(.scrollableBlockNaturalWidth, at: attrRange.location, effectiveRange: nil) != nil {
                return
            }

            let boundsVal = ts.attribute(.latexBounds, at: attrRange.location, effectiveRange: nil) as? NSValue
            let imageBounds = boundsVal?.rectValue ?? CGRect(origin: .zero, size: image.size)
            let isBlock = ts.attribute(.latexIsBlock, at: attrRange.location, effectiveRange: nil) as? Bool ?? false
            let blockOffsetY = ts.attribute(.latexBlockOffsetY, at: attrRange.location, effectiveRange: nil) as? CGFloat

            guard let pos = drawPosition(forDocumentCharAt: attrRange.location, point: point) else { return }

            let drawRect: CGRect
            if isBlock {
                guard let rect = blockImageDrawRect(attrRange: attrRange, imageBounds: imageBounds, blockOffsetY: blockOffsetY, point: point) else { return }
                drawRect = rect
            } else {
                let descent = imageBounds.origin.y
                drawRect = CGRect(x: pos.x,
                                  y: pos.baselineY + descent - imageBounds.height,
                                  width: imageBounds.width, height: imageBounds.height)
            }
            image.draw(in: drawRect)
        }
    }

    // MARK: - Thematic Breaks (---, ***, ___)

    /// Draw a 1pt horizontal rule across the full container width for any
    /// line fragment whose backing text carries the `.thematicBreak`
    /// attribute. This decouples HR rendering from the source-text length,
    /// so a 3-char `---` looks the same as a 80-char auto-expanded line.
    private func drawThematicBreaks(at point: CGPoint, in context: CGContext) {
        guard let ts = textStorage, let range = fragmentNSRange, range.length > 0 else { return }
        var hasThematic = false
        ts.enumerateAttribute(.thematicBreak, in: range, options: []) { value, _, stop in
            if value as? Bool == true {
                hasThematic = true
                stop.pointee = true
            }
        }
        guard hasThematic else { return }

        let containerWidth = textLayoutManager?.textContainer?.size.width ?? layoutFragmentFrame.width
        let theme = (textLayoutManager?.textContainer?.textView as? NativeTextView)?
            .configuration.theme ?? .default

        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        let nsContext = NSGraphicsContext(cgContext: context, flipped: true)
        NSGraphicsContext.current = nsContext

        let strokeColor = theme.strikethroughColor.withAlphaComponent(0.4)
        strokeColor.setFill()

        // Walk each line fragment in this layout fragment and paint a
        // band on those whose first character carries the marker. (HR
        // tokens are always single-line, but the loop is robust if a
        // future caller ever stacks several rules in one paragraph.)
        let fragLocation = fragmentNSRange?.location ?? 0
        for lineFragment in textLineFragments {
            let lr = lineFragment.characterRange
            let docStart = fragLocation + lr.location
            // TextKit 2 appends a synthetic trailing empty line fragment whose
            // characterRange lands at exactly `tsLen` — `attribute(at:)` needs
            // a strictly in-bounds index, so skip the sentinel.
            guard docStart < ts.length else { continue }
            let isHR = ts.attribute(.thematicBreak, at: docStart, effectiveRange: nil) as? Bool == true
            let tb = lineFragment.typographicBounds
            if isHR {
                // tb.origin.y is already relative to this layout fragment.
                let centerY = point.y + tb.origin.y + tb.height / 2
                let bandRect = CGRect(
                    x: point.x - layoutFragmentFrame.origin.x,
                    y: centerY - 0.5,
                    width: containerWidth,
                    height: 1
                )
                NSBezierPath(rect: bandRect).fill()
            }
        }
    }

    // MARK: - Blockquote Bars

    /// Paint `level` vertical bars in the left gutter of every line that
    /// carries `.blockquoteLevel`. Each line paints its own segment, so a
    /// run of quote lines reads as one continuous bar.
    private func drawBlockquoteBars(at point: CGPoint, in context: CGContext) {
        guard let ts = textStorage, let range = fragmentNSRange, range.length > 0 else { return }
        var anyLevel = false
        ts.enumerateAttribute(.blockquoteLevel, in: range, options: []) { value, _, stop in
            if value is Int { anyLevel = true; stop.pointee = true }
        }
        guard anyLevel else { return }

        let theme = (textLayoutManager?.textContainer?.textView as? NativeTextView)?
            .configuration.theme ?? .default
        let indentPerLevel = Self.blockquoteIndentPerLevel
        let barWidth = theme.blockquoteBarWidth

        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        let nsContext = NSGraphicsContext(cgContext: context, flipped: true)
        NSGraphicsContext.current = nsContext
        theme.blockquoteBar.setFill()

        let fragLocation = fragmentNSRange?.location ?? 0
        let leftEdge = point.x - layoutFragmentFrame.origin.x
        for lineFragment in textLineFragments {
            let lr = lineFragment.characterRange
            let docStart = fragLocation + lr.location
            // TextKit 2 appends a synthetic trailing empty line fragment whose
            // characterRange lands at exactly `tsLen` — `attribute(at:)` needs
            // a strictly in-bounds index, so skip the sentinel.
            guard docStart < ts.length else { continue }
            let tb = lineFragment.typographicBounds
            if let level = ts.attribute(.blockquoteLevel, at: docStart, effectiveRange: nil) as? Int {
                // tb.origin.y is already relative to this layout fragment.
                let barY = point.y + tb.origin.y
                for i in 0..<level {
                    let barX = leftEdge + CGFloat(i) * indentPerLevel + indentPerLevel * 0.25
                    NSBezierPath(rect: CGRect(
                        x: barX, y: barY, width: barWidth, height: tb.height
                    )).fill()
                }
            }
        }
    }

    // MARK: - Bullet Markers

    /// Paint a `•` over every hidden bullet marker (`.bulletMarker`). The
    /// glyph is drawn in the same font as the source so its baseline matches
    /// the surrounding text, and centered within the original marker char's
    /// advance so a `•` of a different width still sits where `-`/`*`/`+` was.
    private func drawBulletMarkers(at point: CGPoint, in context: CGContext) {
        guard let ts = textStorage, let range = fragmentNSRange, range.length > 0 else { return }
        let selectionRanges: [NSRange] = {
            guard let tv = textLayoutManager?.textContainer?.textView else { return [] }
            return tv.selectedRanges.map { $0.rangeValue }.filter { $0.length > 0 }
        }()

        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        let nsContext = NSGraphicsContext(cgContext: context, flipped: true)
        NSGraphicsContext.current = nsContext

        let theme = (textLayoutManager?.textContainer?.textView as? NativeTextView)?
            .configuration.theme ?? .default
        let storageString = ts.string as NSString

        ts.enumerateAttribute(.bulletMarker, in: range, options: []) { [weak self] value, attrRange, _ in
            guard let self, (value as? Bool) == true else { return }
            // Leave a selected marker alone so the highlighted raw char shows.
            if selectionRanges.contains(where: { NSIntersectionRange($0, attrRange).length > 0 }) { return }
            guard let pos = self.drawPosition(forDocumentCharAt: attrRange.location, point: point) else { return }

            let font = (ts.attribute(.font, at: attrRange.location, effectiveRange: nil) as? NSFont)
                ?? (self.textLayoutManager?.textContainer?.textView?.font ?? NSFont.systemFont(ofSize: NSFont.systemFontSize))
            let bulletAttrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: theme.bodyText]
            let bullet = "•" as NSString

            let markerWidth = storageString.substring(with: attrRange).size(withAttributes: [.font: font]).width
            let bulletWidth = bullet.size(withAttributes: bulletAttrs).width
            let xOffset = max(0, (markerWidth - bulletWidth) / 2)
            // Flipped context: text origin is its top edge, baseline sits one
            // ascent below — so top = baseline − ascent aligns the glyph.
            let topY = pos.baselineY - font.ascender
            bullet.draw(at: CGPoint(x: pos.x + xOffset, y: topY), withAttributes: bulletAttrs)
        }
    }

    // MARK: - Task List Checkboxes

    private func drawTaskCheckboxes(at point: CGPoint, in context: CGContext) {
        guard let ts = textStorage, let range = fragmentNSRange, range.length > 0 else { return }
        let selectionRanges: [NSRange] = {
            guard let tv = textLayoutManager?.textContainer?.textView else { return [] }
            return tv.selectedRanges.map { $0.rangeValue }.filter { $0.length > 0 }
        }()

        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        let nsContext = NSGraphicsContext(cgContext: context, flipped: true)
        NSGraphicsContext.current = nsContext

        ts.enumerateAttribute(.taskCheckbox, in: range, options: []) { [weak self] value, attrRange, _ in
            guard let self, value != nil else { return }
            if selectionRanges.contains(where: { NSIntersectionRange($0, attrRange).length > 0 }) { return }

            let isChecked = (value as? Bool) ?? false
            guard let pos = drawPosition(forDocumentCharAt: attrRange.location, point: point) else { return }

            let font = (ts.attribute(.font, at: attrRange.location, effectiveRange: nil) as? NSFont)
                ?? (textLayoutManager?.textContainer?.textView?.font ?? NSFont.systemFont(ofSize: NSFont.systemFontSize))
            let ascent = max(0, font.ascender)
            let descent = max(0, -font.descender)
            let fontHeight = max(1, ceil(ascent + descent))
            let markerWidth = ("[ ]" as NSString).size(withAttributes: [.font: font]).width
            let size = max(1.0, min(floor(fontHeight * 1.2), floor(markerWidth * 1.2)))
            let boxX = pos.x + max(0, (markerWidth - size) / 2)
            let centerY = pos.baselineY + (descent - ascent) / 2
            let boxY = centerY - size / 2

            let scale = textLayoutManager?.textContainer?.textView?.window?.backingScaleFactor
                ?? NSScreen.main?.backingScaleFactor ?? 2.0
            func alignToPixel(_ value: CGFloat) -> CGFloat {
                (value * scale).rounded(.toNearestOrAwayFromZero) / scale
            }
            let boxRect = CGRect(x: alignToPixel(boxX), y: alignToPixel(boxY), width: size, height: size)
            guard !boxRect.isEmpty, !boxRect.isNull else { return }

            let iconInset = max(0.0, size * 0.01)
            let iconRect = boxRect.insetBy(dx: iconInset, dy: iconInset)
            let symbolName = isChecked ? "checkmark.square.fill" : "square"
            if let baseSymbol = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil) {
                let sizeConfig = NSImage.SymbolConfiguration(pointSize: iconRect.height, weight: .regular)
                let theme = (textLayoutManager?.textContainer?.textView as? NativeTextView)?.configuration.theme ?? .default
                let tint = isChecked ? theme.bodyText : theme.mutedText
                let colorConfig = NSImage.SymbolConfiguration(hierarchicalColor: tint)
                let symbolConfig = sizeConfig.applying(colorConfig)
                let symbol = baseSymbol.withSymbolConfiguration(symbolConfig) ?? baseSymbol
                symbol.draw(in: iconRect)
            }
        }
    }
}

// MARK: - Layout Manager Delegate

final class MarkdownLayoutManagerDelegate: NSObject, NSTextLayoutManagerDelegate {
    func textLayoutManager(
        _ textLayoutManager: NSTextLayoutManager,
        textLayoutFragmentFor location: any NSTextLocation,
        in textElement: NSTextElement
    ) -> NSTextLayoutFragment {
        let fragment = MarkdownTextLayoutFragment(textElement: textElement, range: textElement.elementRange)
        // Seed body font + paragraphStyle so the trailing fragment doesn't inherit heading metrics (FB15131180).
        if let textView = textLayoutManager.textContainer?.textView as? NativeTextView {
            let baseFont = textView.baseFont
            let para = NSMutableParagraphStyle()
            let lineHeight = layoutBridgeDefaultLineHeight(for: baseFont, using: textView.layoutBridge)
            para.minimumLineHeight = ceil(lineHeight) + textView.configuration.paragraph.lineHeightExtraSpacing
            para.paragraphSpacing = ceil(lineHeight * textView.configuration.paragraph.spacingFactor)
            para.paragraphSpacingBefore = 0
            fragment.stExtraLineFragmentAttributes = NSDictionary(dictionary: [
                NSAttributedString.Key.font: baseFont,
                NSAttributedString.Key.foregroundColor: textView.configuration.theme.bodyText,
                NSAttributedString.Key.paragraphStyle: para
            ])
        }
        return fragment
    }
}
