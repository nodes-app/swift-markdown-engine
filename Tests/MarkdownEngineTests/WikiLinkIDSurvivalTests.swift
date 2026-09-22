//
//  WikiLinkIDSurvivalTests.swift
//  MarkdownEngine
//
//  A link's opaque id lives on the `.wikiLinkID` side-channel, not in the
//  buffer: the buffer holds `[[Name]]` / `![[Name]]` and `makeStorageState`
//  re-attaches `|id` on every writeback. Three ordinary edits used to take the
//  attribute away with nothing left to read it from, and the id then left the
//  document permanently — for an image embed that means the picture is gone and
//  its stored bytes are orphaned. These are those three edits.
//

import AppKit
import SwiftUI
import Testing
@testable import MarkdownEngine

@MainActor
@Suite("Opaque link ids survive ordinary edits")
struct WikiLinkIDSurvivalTests {

    private static let id = "965F1077-2BA6-4685-AB4D-E1A00F7A2634"
    private static let doc = "Cover\n\n![[a.png|\(id)]]\n"

    /// Editor wired like production, loaded through the real rebuild so the
    /// display form and its `.wikiLinkID` attributes come from the engine.
    private func makeEditor(storage: String = doc) -> (NativeTextView, NativeTextViewCoordinator) {
        _ = NSApplication.shared   // the selection path reads NSApp.currentEvent
        let textView = NativeTextView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        textView.isEditable = true
        textView.configuration = .default
        let coordinator = NativeTextViewCoordinator(
            text: .constant(storage),
            fontName: "SF Pro Text",
            fontSize: 14,
            isWikiLinkActive: .constant(false),
            onLinkClick: nil,
            onInlineSelectionChange: nil
        )
        coordinator.textView = textView
        textView.delegate = coordinator
        coordinator.configuration = .default
        coordinator.rebuildTextStorageAndStyle(textView, from: storage)
        return (textView, coordinator)
    }

    private func nameRange(_ tv: NativeTextView) -> NSRange {
        (tv.string as NSString).range(of: "a.png")
    }

    // MARK: The buffer really is the display form

    @Test func loadStripsTheSuffixFromTheBuffer() {
        let (tv, coord) = makeEditor()
        #expect(tv.string == "Cover\n\n![[a.png]]\n")
        #expect(coord.lastComputedStorage == Self.doc)
    }

    // MARK: 1 — insert at the start of a name

    /// Typed text takes the base typing attributes, so the character inserted at
    /// `contentRange.location` carries no id. Probing only that position read nil
    /// and wrote a suffix-less `![[Za.png]]`.
    @Test func insertingAtTheStartOfANameKeepsTheID() {
        let (tv, coord) = makeEditor()
        let name = nameRange(tv)
        tv.setSelectedRange(NSRange(location: name.location, length: 0))
        tv.insertText("Z", replacementRange: NSRange(location: name.location, length: 0))
        #expect(coord.lastComputedStorage == "Cover\n\n![[Za.png|\(Self.id)]]\n")
    }

    @Test func insertingAtTheEndOfANameKeepsTheID() {
        let (tv, coord) = makeEditor()
        let name = nameRange(tv)
        tv.setSelectedRange(NSRange(location: NSMaxRange(name), length: 0))
        tv.insertText("Z", replacementRange: NSRange(location: NSMaxRange(name), length: 0))
        #expect(coord.lastComputedStorage == "Cover\n\n![[a.pngZ|\(Self.id)]]\n")
    }

    @Test func deletingInsideANameKeepsTheID() {
        let (tv, coord) = makeEditor()
        let name = nameRange(tv)
        tv.setSelectedRange(NSRange(location: NSMaxRange(name), length: 0))
        tv.deleteBackward(nil)
        #expect(coord.lastComputedStorage == "Cover\n\n![[a.pn|\(Self.id)]]\n")
    }

    // MARK: 2 — replace a whole name

    /// Clicking a rendered embed selects its whole name, so the next keystroke
    /// replaces every character the attribute sat on. The edit is confined to the
    /// name, so the id carries across.
    @Test func replacingAWholeNameKeepsTheID() {
        let (tv, coord) = makeEditor()
        let name = nameRange(tv)
        tv.setSelectedRange(name)
        tv.insertText("zzz", replacementRange: name)
        #expect(coord.lastComputedStorage == "Cover\n\n![[zzz|\(Self.id)]]\n")
    }

    /// …but only when the edit stays inside one name: a selection reaching into
    /// the markers is destroying the embed, not renaming it.
    @Test func anEditOverrunningTheNameDropsTheID() {
        let (tv, coord) = makeEditor()
        let name = nameRange(tv)
        let overrun = NSRange(location: name.location, length: name.length + 2)   // "a.png]]"
        tv.setSelectedRange(overrun)
        tv.insertText("q", replacementRange: overrun)
        #expect(!coord.lastComputedStorage.contains(Self.id))
    }

    /// A fresh embed typed where an old one stood must not inherit its id.
    @Test func aNewEmbedInThePlaceOfAnOldOneDoesNotInheritTheID() {
        let (tv, coord) = makeEditor()
        let embed = (tv.string as NSString).range(of: "![[a.png]]")
        tv.setSelectedRange(embed)
        tv.delete(nil)
        tv.insertText("![[c.png]]", replacementRange: tv.selectedRange())
        #expect(!coord.lastComputedStorage.contains(Self.id))
    }

    // MARK: 3 — copy

    /// The private flavor carries the storage form, so an in-app copy → paste
    /// round-trips the id; the public flavors keep the display form, so no id
    /// leaks into another app.
    @Test func copyCarriesTheStorageFormOnThePrivateFlavorOnly() {
        let (tv, _) = makeEditor()
        let embed = (tv.string as NSString).range(of: "![[a.png]]")
        tv.setSelectedRange(embed)
        tv.copy(nil)

        let pasteboard = NSPasteboard.general
        #expect(pasteboard.string(forType: .string) == "![[a.png]]")
        #expect(pasteboard.string(forType: MarkdownPasteboardWriter.markdownType)
                == "![[a.png|\(Self.id)]]")
    }

    @Test func cutThenPasteRoundTripsTheID() {
        let (tv, coord) = makeEditor()
        let embed = (tv.string as NSString).range(of: "![[a.png]]")
        tv.setSelectedRange(embed)
        tv.cut(nil)
        tv.paste(nil)
        #expect(coord.lastComputedStorage.contains("![[a.png|\(Self.id)]]"))
    }

    /// Node links use the same side-channel and the same copy path.
    @Test func copyCarriesTheStorageFormForNodeLinksToo() {
        let (tv, _) = makeEditor(storage: "see [[Note|abc123]] here")
        #expect(tv.string == "see [[Note]] here")
        tv.setSelectedRange((tv.string as NSString).range(of: "[[Note]]"))
        tv.copy(nil)

        let pasteboard = NSPasteboard.general
        #expect(pasteboard.string(forType: .string) == "[[Note]]")
        #expect(pasteboard.string(forType: MarkdownPasteboardWriter.markdownType) == "[[Note|abc123]]")
    }
}
