//
//  NativeTextView+CalloutFold.swift
//  MarkdownEngine
//
//  Hit-test the gutter of a collapsible callout's header line and toggle its
//  fold marker (`[!type]-` ⇄ `[!type]+`) in the source, then restyle so the
//  body collapses/expands. Mirrors the task-checkbox click handling.
//

import AppKit

extension NativeTextView {
    func toggleCalloutFoldIfHit(event: NSEvent) -> Bool {
        guard let textContainer = textContainer,
              let bridge = layoutBridge,
              let storage = textStorage else { return false }
        let localPoint = convert(event.locationInWindow, from: nil)
        let containerPoint = CGPoint(
            x: localPoint.x - textContainerOrigin.x,
            y: localPoint.y - textContainerOrigin.y
        )

        let fullRange = NSRange(location: 0, length: storage.length)
        var hitRange: NSRange? = nil
        storage.enumerateAttribute(.calloutFold, in: fullRange, options: []) { value, attrRange, stop in
            guard (value as? Bool) != nil else { return }
            let rect = bridge.boundingRect(forCharacterRange: attrRange, in: textContainer)
            // The chevron sits in the gutter to the LEFT of the header text; accept
            // clicks from a little before the text up to just inside it.
            let gutter = CGRect(x: rect.minX - 26, y: rect.minY, width: 30, height: rect.height)
            if gutter.contains(containerPoint) {
                hitRange = attrRange
                stop.pointee = true
            }
        }
        guard let headerRange = hitRange else { return false }

        // Re-parse the header line to locate the `]±` marker and toggle it.
        let nsText = storage.string as NSString
        let lineRange = nsText.lineRange(for: NSRange(location: headerRange.location, length: 0))
        let line = nsText.substring(with: lineRange)
        guard let bracket = line.range(of: #"\]([+-]?)"#, options: .regularExpression) else { return false }
        let markerStart = lineRange.location + line.distance(from: line.startIndex, to: bracket.lowerBound) + 1
        let existing = nsText.substring(with: NSRange(location: markerStart, length: min(1, NSMaxRange(lineRange) - markerStart)))
        let (oldMarkerRange, replacement): (NSRange, String)
        switch existing {
        case "-": (oldMarkerRange, replacement) = (NSRange(location: markerStart, length: 1), "+")   // expand
        case "+": (oldMarkerRange, replacement) = (NSRange(location: markerStart, length: 1), "-")   // collapse
        default:  return false   // not a foldable header
        }

        if shouldChangeText(in: oldMarkerRange, replacementString: replacement) {
            storage.replaceCharacters(in: oldMarkerRange, with: replacement)
            didChangeText()
            if let coord = delegate as? NativeTextViewCoordinator {
                let fullRange = NSRange(location: 0, length: storage.length)
                coord.restyleParagraphs([fullRange], in: self)
            }
        }
        return true
    }
}
