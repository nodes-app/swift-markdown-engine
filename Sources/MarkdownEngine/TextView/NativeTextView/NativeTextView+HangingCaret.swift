//
//  NativeTextView+HangingCaret.swift
//  MarkdownEngine
//
//  Created by Luca Chen on 31.10.26.
//
//  Spaces at a soft wrap hang past the right margin, and TextKit clamps the
//  caret to that margin, so a space typed there looked like it did nothing.
//  A caret in hanging whitespace is drawn where the next glyph will land: the
//  start of the next line, or of the line the next glyph would open.
//

import AppKit

/// Where a caret in whitespace past the right margin is drawn instead of the margin.
struct HangingCaret: Equatable {
    enum Placement: Equatable {
        /// The start of the paragraph's next line.
        case nextLine
        /// The start of the line the next glyph would open below the paragraph's last line.
        case newLine
    }

    let placement: Placement
    /// Caret rect in text-view coordinates, width 0 like TextKit's.
    let rect: CGRect
    /// A location whose ordinary caret sits on the drawn row, so line moves start
    /// from it. nil when there is none (the end of the document).
    let navigationAnchor: Int?
}

extension NativeTextView {
    /// The caret is kept this far inside the right edge: the text view clips, and
    /// with no horizontal inset a caret at the margin of a full line is cut off.
    static let caretEdgeInset: CGFloat = 2

    /// Where to draw a collapsed caret at `location`; nil when TextKit's own spot is right.
    func hangingCaret(at location: Int, affinity: NSSelectionAffinity) -> HangingCaret? {
        guard let ts = textStorage, let tlm = textLayoutManager,
              let tcs = tlm.textContentManager as? NSTextContentStorage else { return nil }
        let ns = ts.string as NSString
        // Only a hanging space puts the caret past the margin; every other caret leaves here.
        guard location > 0, location <= ns.length,
              Self.isHangingWhitespace(ns.character(at: location - 1)),
              // Tables draw an image over their source, not the source's own glyphs.
              ts.attribute(.scrollableBlockNaturalWidth, at: location - 1, effectiveRange: nil) == nil
        else { return nil }
        let docStart = tcs.documentRange.location
        guard let before = tcs.location(docStart, offsetBy: location - 1),
              let caretLocation = tcs.location(docStart, offsetBy: location),
              let fragment = tlm.textLayoutFragment(for: before),
              fragment.state == .layoutAvailable else { return nil }

        let paragraphStart = tcs.offset(from: docStart, to: fragment.rangeInElement.location)
        let local = location - paragraphStart
        let lines = fragment.textLineFragments
        // The line holding the space before the caret.
        guard let index = lines.firstIndex(where: {
            $0.characterRange.location < local && local <= NSMaxRange($0.characterRange)
        }) else { return nil }
        let line = lines[index]
        let lineRange = line.characterRange
        // The last fragment can end in an empty sentinel line; it is not a line of text.
        let nextLine = lines.indices.contains(index + 1) && lines[index + 1].characterRange.length > 0
            ? lines[index + 1] : nil
        // At the wrap point a downstream caret is already drawn at the next line's start.
        if local == NSMaxRange(lineRange), nextLine != nil, affinity == .downstream { return nil }
        let paragraph = line.attributedString.string as NSString
        for i in local..<NSMaxRange(lineRange) {
            guard let scalar = Unicode.Scalar(paragraph.character(at: i)),
                  CharacterSet.whitespacesAndNewlines.contains(scalar) else { return nil }
        }

        guard let clamped = caretSegment(at: caretLocation, upstream: affinity == .upstream, in: tlm) else {
            return nil
        }
        // Where the caret would be without the clamp, in container coordinates
        // (the same sum the layout fragment draws bullets and checkboxes with).
        let unclampedX = fragment.layoutFragmentFrame.minX + line.typographicBounds.minX
            + line.locationForCharacter(at: local).x
        guard unclampedX > clamped.minX + 0.5 else { return nil }

        let origin = textContainerOrigin
        if let nextLine {
            let nextStart = paragraphStart + nextLine.characterRange.location
            guard let start = lineStart(at: nextStart, in: tlm, tcs, onRow: { $0.minY > clamped.minY + 0.5 })
            else { return nil }
            return HangingCaret(
                placement: .nextLine,
                rect: CGRect(x: start.minX + origin.x, y: start.minY + origin.y, width: 0, height: start.height),
                navigationAnchor: nextStart
            )
        }

        // The paragraph's last line: the next glyph opens a new line below it.
        // Drawn only over empty space, never on top of the next paragraph's text.
        let paragraphEnd = tcs.offset(from: docStart, to: fragment.rangeInElement.endLocation)
        guard paragraphEnd >= ns.length || ns.character(at: paragraphEnd) == 0x0A else { return nil }
        let style = ts.attribute(.paragraphStyle, at: location - 1, effectiveRange: nil) as? NSParagraphStyle
        // headIndent marks where a wrapped line starts only in left-to-right, left-aligned text.
        guard [NSTextAlignment.natural, .left, .justified].contains(style?.alignment ?? .natural),
              style?.baseWritingDirection != .rightToLeft else { return nil }
        let startX: CGFloat
        if index > 0, let start = lineStart(at: paragraphStart + lineRange.location, in: tlm, tcs,
                                            onRow: { abs($0.minY - clamped.minY) < 0.5 }) {
            startX = start.minX
        } else {
            startX = fragment.layoutFragmentFrame.minX + (style?.headIndent ?? 0)
        }
        let rect = CGRect(x: startX + origin.x, y: clamped.maxY + origin.y, width: 0, height: clamped.height)
        guard rect.maxY <= bounds.maxY else { return nil }
        // The drawn row belongs to the empty paragraph below, or to the document's
        // trailing empty line; a document ending in this line has nothing there.
        let anchor: Int?
        if paragraphEnd < ns.length {
            anchor = paragraphEnd
        } else if ns.length > 0, ns.character(at: ns.length - 1) == 0x0A {
            anchor = ns.length
        } else {
            anchor = nil
        }
        return HangingCaret(placement: .newLine, rect: rect, navigationAnchor: anchor)
    }

    /// Moves the indicator of a caret in hanging whitespace to where the next
    /// glyph lands, and keeps a caret at the clipped right edge inside it.
    func placeCaretPastMargin() {
        guard let indicator = observedCaretIndicator, !indicator.isHidden, !hasMarkedText() else { return }
        let selection = selectedRange()
        guard selection.length == 0 else { return }
        var target = indicator.frame
        if let hanging = hangingCaret(at: selection.location, affinity: selectionAffinity) {
            target.origin = hanging.rect.origin
            target.size.height = hanging.rect.height
        }
        target.origin.x = min(target.origin.x, bounds.maxX - Self.caretEdgeInset)
        guard abs(target.minX - indicator.frame.minX) >= 0.5
                || abs(target.minY - indicator.frame.minY) >= 0.5
                || abs(target.height - indicator.frame.height) >= 0.5 else { return }
        isApplyingCaretShift = true
        indicator.frame = target
        isApplyingCaretShift = false
    }

    /// ↑ ↓ ⌘← ⌘→ from a hanging caret start on the row it is drawn on, not at the
    /// margin TextKit clamps it to: the caret moves onto that row and AppKit
    /// performs the command from there. True when the move is already complete.
    func startLineMoveFromHangingCaret(_ command: Selector) -> Bool {
        let vertical = command == #selector(NSResponder.moveUp(_:))
            || command == #selector(NSResponder.moveDown(_:))
        let alongLine = command == #selector(NSResponder.moveToBeginningOfLine(_:))
            || command == #selector(NSResponder.moveToEndOfLine(_:))
            || command == #selector(NSResponder.moveToLeftEndOfLine(_:))
            || command == #selector(NSResponder.moveToRightEndOfLine(_:))
        guard vertical || alongLine, !hasMarkedText() else { return false }
        let selection = selectedRange()
        guard selection.length == 0,
              let hanging = hangingCaret(at: selection.location, affinity: selectionAffinity) else { return false }
        if hanging.placement == .newLine, !vertical { return false }
        if let anchor = hanging.navigationAnchor {
            setSelectedRange(NSRange(location: anchor, length: 0), affinity: .downstream, stillSelecting: false)
            return false
        }
        // The new line at the very end of the document has nothing below it; ↑
        // lands on the line above the drawn caret, at its x.
        guard command == #selector(NSResponder.moveUp(_:)) else { return false }
        let above = characterIndexForInsertion(at: NSPoint(x: hanging.rect.minX, y: hanging.rect.minY - hanging.rect.height / 2))
        setSelectedRange(NSRange(location: above, length: 0), affinity: .downstream, stillSelecting: false)
        scrollRangeToVisible(selectedRange())
        return true
    }

    override func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
        let rect = super.firstRect(forCharacterRange: range, actualRange: actualRange)
        // Input panels (emoji, dictation) anchor to this rect, so they follow the drawn caret.
        guard range.length == 0, !hasMarkedText(), let window else { return rect }
        let affinity = range.location == selectedRange().location ? selectionAffinity : .downstream
        guard let hanging = hangingCaret(at: range.location, affinity: affinity) else { return rect }
        return window.convertToScreen(convert(hanging.rect, to: nil))
    }

    /// Spaces that hang at a soft wrap; no-break spaces never end a line there.
    static func isHangingWhitespace(_ character: unichar) -> Bool {
        guard character != 0xA0, character != 0x2007, character != 0x202F,
              let scalar = Unicode.Scalar(character) else { return false }
        return CharacterSet.whitespaces.contains(scalar)
    }

    private func caretSegment(at location: NSTextLocation, upstream: Bool, in tlm: NSTextLayoutManager) -> CGRect? {
        var options: NSTextLayoutManager.SegmentOptions = [.rangeNotRequired]
        if upstream { options.insert(.upstreamAffinity) }
        var frame: CGRect?
        tlm.enumerateTextSegments(in: NSTextRange(location: location), type: .selection, options: options) { _, f, _, _ in
            frame = f
            return false
        }
        return frame
    }

    /// The caret rect at the start of the wrapped line beginning at `offset`, in
    /// container coordinates; `onRow` rejects a rect TextKit put on another row.
    private func lineStart(at offset: Int, in tlm: NSTextLayoutManager, _ tcs: NSTextContentStorage,
                           onRow: (CGRect) -> Bool) -> CGRect? {
        guard let location = tcs.location(tcs.documentRange.location, offsetBy: offset) else { return nil }
        if let caret = caretSegment(at: location, upstream: false, in: tlm), onRow(caret) { return caret }
        // The wrap point can resolve to the previous line's end; the first character's box cannot.
        guard let end = tcs.location(location, offsetBy: 1),
              let range = NSTextRange(location: location, end: end) else { return nil }
        var frame: CGRect?
        tlm.enumerateTextSegments(in: range, type: .selection, options: []) { _, f, _, _ in
            frame = f
            return false
        }
        guard let frame, onRow(frame) else { return nil }
        return CGRect(x: frame.minX, y: frame.minY, width: 0, height: frame.height)
    }
}
