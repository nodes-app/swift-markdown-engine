//
//  OrderedListDisplayNumberingTests.swift
//  MarkdownEngineTests
//
//  Created by Luca Chen on 30.07.26.
//
//  Ordered items are numbered by POSITION and painted over the source digits.
//  Two things the styler alone cannot get right, and that a styler-only test
//  would happily hide:
//  * the block array a SCOPED restyle sees is not the document — the text
//    between two scoped regions is missing, so a run can look continuous when
//    prose actually ended it;
//  * unlike every other markdown construct, the overlay does NOT step aside for
//    the caret or a selection — the source digit is positional, not authored,
//    and revealing it renamed the item the reader was pointing at.
//

import AppKit
import Foundation
import Testing
@testable import MarkdownEngine

@MainActor
@Suite("Ordered list display numbering")
struct OrderedListDisplayNumberingTests {

    private let fontSize: CGFloat = 14
    private var fontName: String { NSFont.systemFont(ofSize: 14).fontName }

    /// `(markerLocation, paintedMarker)` for every overlaid ordered marker.
    /// Absent = the item paints its own literal digits (styler emits the
    /// overlay only when the display number differs from the source).
    private func overlays(_ attrs: [StyledRange]) -> [(loc: Int, text: String)] {
        attrs.compactMap { entry in
            (entry.1[.orderedMarker] as? String).map { (entry.0.location, $0) }
        }
        .sorted { $0.0 < $1.0 }
    }

    private func overlays(in tv: NSTextView) -> [(loc: Int, text: String)] {
        guard let storage = tv.textStorage else { return [] }
        var out: [(Int, String)] = []
        storage.enumerateAttribute(.orderedMarker, in: NSRange(location: 0, length: storage.length)) { value, range, _ in
            if let text = value as? String { out.append((range.location, text)) }
        }
        return out.sorted { $0.0 < $1.0 }
    }

    private func style(_ text: String, caret: Int = -1, scoped: [NSRange]? = nil) -> [StyledRange] {
        MarkdownASTStyler.styleAttributes(
            text: text, fontName: fontName, fontSize: fontSize,
            caretLocation: caret, scopedRanges: scoped
        )
    }

    private func makeEditor(_ text: String) -> (NativeTextViewCoordinator, NativeTextView) {
        _ = NSApplication.shared
        let coordinator = NativeTextViewCoordinator(
            text: .constant(text), fontName: "SF Pro", fontSize: 16,
            isWikiLinkActive: .constant(false), onLinkClick: nil, onInlineSelectionChange: nil
        )
        let tv = NativeTextView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        tv.isEditable = true
        tv.delegate = coordinator
        coordinator.textView = tv
        coordinator.rebuildTextStorageAndStyle(tv, from: text)
        coordinator.lastSyncedText = text
        coordinator.lastComputedStorage = text
        coordinator.previousDisplayLength = (text as NSString).length
        return (coordinator, tv)
    }

    // MARK: Scope

    /// A two-region scope (caret paragraph + previous-caret paragraph — what
    /// every click builds) drops the prose between the lists from the block
    /// array. The count must not flow across that hole.
    @Test("prose between two lists still ends the run when the scope skips it")
    func disjointScopeDoesNotCarryTheCountIntoTheNextList() {
        let text = "1. one\n2. two\n\nProse paragraph here.\n\n1. alpha\n2. beta\n"
        let ns = text as NSString
        let alpha = ns.range(of: "1. alpha")
        let scoped = [ns.paragraphRange(for: NSRange(location: 0, length: 0)),
                      ns.paragraphRange(for: alpha)]

        let painted = overlays(style(text, scoped: scoped))
            .filter { NSLocationInRange($0.loc, ns.paragraphRange(for: alpha)) }

        // `1. alpha` is item 1 of its own list: display == literal, nothing to
        // paint. Before the fix it inherited the upper list's count and painted "3.".
        #expect(painted.isEmpty)
        #expect(overlays(style(text)).isEmpty)   // and the full pass agrees
    }

    /// The counterpart: a blank line is loose-list spacing, not a terminator,
    /// so a scope that only sees the tail must still continue the run above it.
    @Test("scoped tail of a blank-split list keeps counting")
    func scopedTailOfBlankSplitListStillContinues() {
        let text = "1. one\n\n1. two\n"
        let ns = text as NSString
        let tail = ns.range(of: "1. two")

        let painted = overlays(style(text, scoped: [ns.paragraphRange(for: tail)]))

        #expect(painted.map(\.text) == ["2."])
        #expect(painted.first?.loc == tail.location)
    }

    /// The seed scans BACKWARD from the item's marker — which for an indented
    /// item still sits inside its own line, so it used to count that item and
    /// every nested list rendered one too high with no gesture at all.
    @Test("a nested ordered list starts at its own number")
    func nestedListDoesNotCountItself() {
        #expect(overlays(style("- outer\n  1. a\n  2. b")).isEmpty)
        #expect(overlays(style("- outer\n\t1. a\n\t2. b")).isEmpty)
        #expect(overlays(style("  1. alpha")).isEmpty)
        #expect(overlays(style("1. top\n  1. nested\n  2. nested")).isEmpty)
    }

    /// A hole of blank lines between two scoped blocks is loose-list spacing,
    /// so the count carries; a hole holding another item re-seeds from the
    /// source and lands on the same number. Both must agree with a full pass.
    @Test("a scope with holes counts through a loose list")
    func scopeWithHolesCountsThroughLooseList() {
        let text = "1. one\n\n1. two\n\n1. three\n"
        let ns = text as NSString
        let scoped = [ns.paragraphRange(for: NSRange(location: 0, length: 0)),
                      ns.paragraphRange(for: ns.range(of: "1. three"))]

        let painted = overlays(style(text, scoped: scoped))

        #expect(painted.map(\.text) == ["3."])
        #expect(overlays(style(text)).map(\.text) == ["2.", "3."])   // full pass agrees
    }

    @Test("disjoint scopes inside one list reseed omitted items")
    func disjointScopesInsideOneListReseedOmittedItems() {
        let text = "1. one\n1. two\n1. three\n1. four\n"
        let ns = text as NSString
        let first = ns.lineRange(for: ns.range(of: "1. one"))
        let fourth = ns.lineRange(for: ns.range(of: "1. four"))

        let painted = overlays(style(text, scoped: [first, fourth]))

        #expect(painted.map(\.loc) == [fourth.location])
        #expect(painted.map(\.text) == ["4."])
    }

    // MARK: Caret

    /// The caret parked at the line start is where every whole-line delete and
    /// line-join leaves it — treating that as "editing the digits" is what made
    /// a 1./2./3. list read 1./1. after deleting item 2.
    @Test("caret at the line start keeps the display number")
    func caretAtTheLineStartKeepsTheDisplayNumber() {
        let painted = overlays(style("1. a\n1. b", caret: 5))

        #expect(painted.map(\.text) == ["2."])
        #expect(painted.first?.loc == 5)
    }

    /// The source digit is not something the reader authored — it is positional,
    /// and in a run written `1./1./1.` every item's source reads `1.`. Revealing
    /// it under the caret meant a plain click inside the marker flipped the
    /// number back to `1.`, so the caret leaves the painted number alone.
    @Test("caret on the digits keeps the display number")
    func caretOnTheDigitsKeepsTheDisplayNumber() {
        #expect(overlays(style("1. a\n1. b", caret: 6)).map(\.text) == ["2."])   // between `1` and `.`
        #expect(overlays(style("1. a\n1. b", caret: 7)).map(\.text) == ["2."])   // the space after `1.`
        #expect(overlays(style("1. a\n1. b", caret: 8)).map(\.text) == ["2."])   // content
    }

    /// Nor does a selection: ⌘A used to swap every marker back to its source
    /// digit, so a whole list read one lower than it renders while selected.
    @Test("a selection over the marker keeps the display number")
    func selectionOverTheMarkerKeepsTheDisplayNumber() {
        let text = "1. a\n1. b"
        for selection in [NSRange(location: 5, length: 3),                  // just the marker
                          NSRange(location: 0, length: (text as NSString).length)] {   // ⌘A
            let painted = MarkdownASTStyler.styleAttributes(
                text: text, fontName: fontName, fontSize: fontSize,
                caretLocation: -1, selection: selection
            )
            #expect(overlays(painted).map(\.text) == ["2."], "selection \(selection)")
        }
    }

    // MARK: Coordinator wiring

    @Test("ordered marker edits are classified as run-affecting")
    func orderedMarkerEditIsRunAffecting() {
        let (coordinator, tv) = makeEditor("3. a\n1. b\n1. c")
        coordinator.pendingListStructureEdit = false

        let accepted = coordinator.textView(
            tv,
            shouldChangeTextIn: NSRange(location: 0, length: 1),
            replacementString: "5"
        )

        #expect(accepted)
        #expect(coordinator.pendingListStructureEdit)
    }

    @Test("leading indentation edits are classified as run-affecting")
    func leadingIndentEditIsRunAffecting() {
        let (coordinator, tv) = makeEditor("1. a\n1. b\n1. c")
        coordinator.pendingListStructureEdit = false

        let accepted = coordinator.textView(
            tv,
            shouldChangeTextIn: NSRange(location: 5, length: 0),
            replacementString: "  "
        )

        #expect(accepted)
        #expect(coordinator.pendingListStructureEdit)
    }

    @Test("all leading list syntax transitions are run-affecting")
    func leadingListSyntaxTransitionsAreRunAffecting() {
        let cases: [(range: NSRange, replacement: String)] = [
            (NSRange(location: 1, length: 1), ")"),
            (NSRange(location: 0, length: 2), "-"),
            (NSRange(location: 2, length: 1), ""),
        ]

        for testCase in cases {
            let (coordinator, tv) = makeEditor("1. a\n1. b\n1. c")
            coordinator.pendingListStructureEdit = false

            let accepted = coordinator.textView(
                tv,
                shouldChangeTextIn: testCase.range,
                replacementString: testCase.replacement
            )

            #expect(accepted)
            #expect(coordinator.pendingListStructureEdit)
        }
    }

    @Test("programmatic marker edits remain run-affecting")
    func programmaticMarkerEditIsRunAffecting() {
        let (coordinator, tv) = makeEditor("1. a\n1. b\n1. c")
        coordinator.isProgrammaticEdit = true
        coordinator.pendingListStructureEdit = false

        let accepted = coordinator.textView(
            tv,
            shouldChangeTextIn: NSRange(location: 0, length: 1),
            replacementString: "3"
        )

        #expect(accepted)
        #expect(coordinator.pendingListStructureEdit)
    }

    @Test("list content edits stay paragraph-scoped")
    func listContentEditIsNotRunAffecting() {
        let (coordinator, tv) = makeEditor("1. a\n1. b\n1. c")
        coordinator.pendingListStructureEdit = false

        let accepted = coordinator.textView(
            tv,
            shouldChangeTextIn: NSRange(location: 8, length: 1),
            replacementString: "B"
        )

        #expect(accepted)
        #expect(!coordinator.pendingListStructureEdit)
    }

    /// The paint is caret-independent now, so moving in and out of the marker
    /// must leave the rendered number untouched — including the position every
    /// whole-line delete and line-join parks the caret at.
    @Test("moving the caret through the marker never changes the number")
    func caretThroughTheMarkerKeepsTheNumber() {
        let (_, tv) = makeEditor("1. a\n1. b")

        for caret in [5, 6, 7, 8, 2] {
            tv.setSelectedRange(NSRange(location: caret, length: 0))
            #expect(overlays(in: tv).map(\.text) == ["2."], "caret \(caret)")
        }
    }

    /// A content keystroke shifts no number, so it keeps the default paragraph
    /// scope instead of restyling the whole list block — the numbers below it
    /// must survive that narrower pass untouched.
    @Test("typing inside an item leaves the run's numbers alone")
    func contentEditKeepsTheNumbers() {
        let (_, tv) = makeEditor("1. a\n1. b\n1. c")
        #expect(overlays(in: tv).map(\.text) == ["2.", "3."])

        tv.insertText("x", replacementRange: NSRange(location: 9, length: 0))   // end of item 2's content

        #expect(tv.string == "1. a\n1. bx\n1. c")
        #expect(overlays(in: tv).map(\.text) == ["2.", "3."])
    }

    @Test("editing the run's starting number restyles following items")
    func editingRunStartNumberRestylesFollowingItems() {
        let (_, tv) = makeEditor("3. a\n1. b\n1. c")
        #expect(overlays(in: tv).map(\.text) == ["4.", "5."])

        tv.insertText("5", replacementRange: NSRange(location: 0, length: 1))

        #expect(tv.string == "5. a\n1. b\n1. c")
        #expect(overlays(in: tv).map(\.text) == ["6.", "7."])
    }

    @Test("undo and redo of a marker edit restyle following items")
    func undoRedoMarkerEditRestylesFollowingItems() throws {
        let (coordinator, tv) = makeEditor("3. a\n1. b\n1. c")
        tv.allowsUndo = true
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        window.contentView = tv
        window.makeFirstResponder(tv)
        defer { window.contentView = nil }

        let undoManager = try #require(coordinator.undoManager(for: tv))
        tv.insertText("5", replacementRange: NSRange(location: 0, length: 1))
        #expect(overlays(in: tv).map(\.text) == ["6.", "7."])
        #expect(tv.undoManager === undoManager)

        // AppKit's private text undo action bypasses delegate notifications in
        // a headless test process. Register an equivalent replacement action
        // so undo/redo still runs through the public text-view delegate path.
        undoManager.removeAllActions()
        undoManager.groupsByEvent = false
        var registerReplacement: ((String, String) -> Void)!
        registerReplacement = { replacement, inverse in
            undoManager.registerUndo(withTarget: tv) { textView in
                undoManager.disableUndoRegistration()
                textView.insertText(replacement, replacementRange: NSRange(location: 0, length: 1))
                undoManager.enableUndoRegistration()
                registerReplacement(inverse, replacement)
            }
        }
        undoManager.beginUndoGrouping()
        registerReplacement("3", "5")
        undoManager.endUndoGrouping()

        undoManager.undo()
        #expect(tv.string == "3. a\n1. b\n1. c")
        #expect(overlays(in: tv).map(\.text) == ["4.", "5."])

        undoManager.redo()
        #expect(tv.string == "5. a\n1. b\n1. c")
        #expect(overlays(in: tv).map(\.text) == ["6.", "7."])
    }

    /// End-to-end repro of the shipped-looking bug: delete the middle item and
    /// the survivor must renumber instead of showing its stale literal.
    @Test("deleting an item renumbers the survivor")
    func deletingAnItemRenumbersTheSurvivor() {
        let (_, tv) = makeEditor("1. a\n1. b\n1. c")
        #expect(overlays(in: tv).map(\.text) == ["2.", "3."])

        tv.insertText("", replacementRange: NSRange(location: 5, length: 5))   // remove "1. b\n"

        #expect(tv.string == "1. a\n1. c")
        #expect(overlays(in: tv).map(\.text) == ["2."])
    }

    // MARK: Scoped item runs

    /// A caret move restyles the paragraph it entered AND the one it left. Coming
    /// from the content block directly above the list, the scoped list node starts
    /// at a LATER item — with no item above it inside that node to count from, and
    /// with the preceding block having just cleared the seed flag. The number has
    /// to come back from the source, not from the item's own literal digits.
    @Test("clicking from the block above into a later item keeps the number")
    func clickFromBlockAboveKeepsTheNumber() {
        for above in ["# H", "> quote", "**bold** text"] {
            let (_, tv) = makeEditor("\(above)\n1. a\n1. b\n1. c\n")
            #expect(overlays(in: tv).map(\.text) == ["2.", "3."])

            let content = (tv.string as NSString).range(of: "c").location
            tv.setSelectedRange(NSRange(location: 1, length: 0))            // into the block above
            tv.setSelectedRange(NSRange(location: content, length: 0))      // into item 3's content

            #expect(overlays(in: tv).map(\.text) == ["2.", "3."], "block above: \(above)")
        }
    }

    /// The mirror image: a scope that keeps only the HEAD of a list block leaves
    /// its tail unbuilt. Those dropped lines are content, not the blank-line
    /// spacing of a loose list, so the next block must re-seed instead of
    /// continuing a count that stopped early.
    @Test("a scope truncating a list's tail does not miscount the next block")
    func truncatedTailDoesNotMiscountTheNextBlock() {
        let (_, tv) = makeEditor("1. one\n1. two\n\n1. three\n1. four\n")
        #expect(overlays(in: tv).map(\.text) == ["2.", "3.", "4."])

        // Off the digits of the second block's first item — the caret move that
        // forces the restyle — into the first block's first item, leaving that
        // block's remaining items outside the scope.
        tv.setSelectedRange(NSRange(location: 15, length: 0))
        tv.setSelectedRange(NSRange(location: 2, length: 0))

        #expect(overlays(in: tv).map(\.text) == ["2.", "3.", "4."])
    }
}
