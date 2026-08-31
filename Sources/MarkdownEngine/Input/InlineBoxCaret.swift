//
//  InlineBoxCaret.swift
//  MarkdownEngine
//
//  Treats a span laid out as a box (`InlineSyntax.inlineBoxWidth`) as one
//  indivisible thing for the caret, the selection, and delete.
//
//  A box has no glyphs of its own: its characters are collapsed and its
//  reserved space rides on the first one. So every position inside it draws at
//  the same place, and without this an arrow key stops a dozen times in a spot
//  that never moves, a click can drop the caret inside the construct, and one
//  backspace shaves a delimiter off it — turning the box back into raw text in
//  the middle of a sentence.
//
//  Boxes are found through the `.inlineExtensionBox` attribute the styler
//  leaves on the span. Two boxes of the same extension placed directly against
//  each other read as one box here; every construct that wants a box in
//  practice is separated by at least a space.
//

import AppKit

enum InlineBoxCaret {

    // MARK: Lookup

    /// The box whose interior holds `location` — strictly inside, so a position
    /// on either edge is not in a box.
    static func box(strictlyContaining location: Int, in storage: NSAttributedString) -> NSRange? {
        guard location > 0, let box = box(coveringCharacterAt: location - 1, in: storage),
              location < NSMaxRange(box)
        else { return nil }
        return box
    }

    /// The box that ends exactly at `location`, which is where a backspace
    /// would otherwise eat its closing delimiter.
    static func box(endingAt location: Int, in storage: NSAttributedString) -> NSRange? {
        guard location > 0, let box = box(coveringCharacterAt: location - 1, in: storage),
              NSMaxRange(box) == location
        else { return nil }
        return box
    }

    /// The box that starts exactly at `location`.
    static func box(startingAt location: Int, in storage: NSAttributedString) -> NSRange? {
        guard let box = box(coveringCharacterAt: location, in: storage),
              box.location == location
        else { return nil }
        return box
    }

    private static func box(coveringCharacterAt index: Int, in storage: NSAttributedString) -> NSRange? {
        guard index >= 0, index < storage.length else { return nil }
        var range = NSRange(location: NSNotFound, length: 0)
        guard storage.attribute(
            .inlineExtensionBox,
            at: index,
            longestEffectiveRange: &range,
            in: NSRange(location: 0, length: storage.length)
        ) != nil else { return nil }
        return range
    }

    // MARK: Selection

    /// `proposed` with no edge left inside a box.
    ///
    /// A caret is pushed out to one side; a range grows to cover every box it
    /// only partly holds, so a selection can never carry half a construct into
    /// a copy or a deletion.
    ///
    /// - Parameter previous: Where the caret was, which is what tells a step
    ///   apart from a jump. Stepping off an edge continues in that direction —
    ///   otherwise the caret would bounce back to where it came from and the
    ///   box would be a wall. Anything else (a click, a programmatic set) takes
    ///   the nearer edge.
    static func normalized(
        _ proposed: NSRange,
        movingFrom previous: Int,
        in storage: NSAttributedString
    ) -> NSRange {
        guard storage.length > 0 else { return proposed }
        guard proposed.length > 0 else {
            guard let box = box(strictlyContaining: proposed.location, in: storage) else { return proposed }
            return NSRange(location: exit(of: box, from: previous, toward: proposed.location), length: 0)
        }
        var result = proposed
        for edge in [proposed.location, NSMaxRange(proposed)] {
            guard let box = box(strictlyContaining: edge, in: storage) else { continue }
            result = NSUnionRange(result, box)
        }
        return result
    }

    private static func exit(of box: NSRange, from previous: Int, toward proposed: Int) -> Int {
        if previous == box.location { return NSMaxRange(box) }
        if previous == NSMaxRange(box) { return box.location }
        let fromStart = proposed - box.location
        let fromEnd = NSMaxRange(box) - proposed
        return fromStart <= fromEnd ? box.location : NSMaxRange(box)
    }

    // MARK: Delete

    /// Backspace directly behind a box removes the whole box.
    static func handleDeleteBackward(textView: NSTextView) -> Bool {
        guard let storage = textView.textStorage else { return false }
        let selection = textView.selectedRange()
        guard selection.length == 0,
              let box = box(endingAt: selection.location, in: storage) else { return false }
        return delete(box, in: textView)
    }

    /// Forward delete directly in front of a box removes the whole box.
    static func handleDeleteForward(textView: NSTextView) -> Bool {
        guard let storage = textView.textStorage else { return false }
        let selection = textView.selectedRange()
        guard selection.length == 0,
              let box = box(startingAt: selection.location, in: storage) else { return false }
        return delete(box, in: textView)
    }

    private static func delete(_ box: NSRange, in textView: NSTextView) -> Bool {
        MarkdownLists.performEdit(textView, replace: box, with: "")
        textView.setSelectedRange(NSRange(location: box.location, length: 0))
        return true
    }
}
