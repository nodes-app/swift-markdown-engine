//
//  ImageEmbedIDInSourceTests.swift
//  MarkdownEngine
//
//  `ImageEmbedStyle.keepsIDInSource`: the embed's `|id` stays in the editor's own
//  text instead of the `.wikiLinkID` side-channel. Display IS storage, so the id
//  cannot be lost to an edit that breaks the syntax for one keystroke.
//

import AppKit
import SwiftUI
import Testing
@testable import MarkdownEngine

@MainActor
@Suite("Image embeds keep their id in the source")
struct ImageEmbedIDInSourceTests {

    private static let id = "965F1077-2BA6-4685-AB4D-E1A00F7A2634"
    private static let doc = "Cover\n\n![[a.png|\(id)]]\n"

    private func makeEditor(
        _ storage: String = doc, keepsIDInSource: Bool = true
    ) -> (NativeTextView, NativeTextViewCoordinator) {
        _ = NSApplication.shared
        var configuration = MarkdownEditorConfiguration.default
        configuration.imageEmbed.keepsIDInSource = keepsIDInSource
        let textView = NativeTextView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        textView.isEditable = true
        textView.configuration = configuration
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
        coordinator.configuration = configuration
        coordinator.rebuildTextStorageAndStyle(textView, from: storage)
        return (textView, coordinator)
    }

    // MARK: The source line shows the id

    @Test func theBufferKeepsTheSuffix() {
        let (tv, coord) = makeEditor()
        #expect(tv.string == Self.doc)
        #expect(coord.lastComputedStorage == Self.doc)
    }

    @Test func noAttributeIsParkedOnTheName() {
        let (tv, _) = makeEditor()
        let name = (tv.string as NSString).range(of: "a.png")
        #expect(tv.textStorage?.attribute(.wikiLinkID, at: name.location, effectiveRange: nil) == nil)
    }

    /// Node links are unaffected — they still hide their id.
    @Test func nodeLinksStillUseTheSideChannel() {
        let (tv, coord) = makeEditor("see [[Note|abc123]] here")
        #expect(tv.string == "see [[Note]] here")
        #expect(coord.lastComputedStorage == "see [[Note|abc123]] here")
    }

    // MARK: Nothing can lose the id any more

    /// The case the side-channel could never survive: break the syntax, then
    /// restore it. The id is in the text, so it simply stays there.
    @Test func breakingAndRestoringTheBracketsKeepsTheID() {
        let (tv, coord) = makeEditor()
        let embed = (tv.string as NSString).range(of: "![[a.png|\(Self.id)]]")
        tv.setSelectedRange(NSRange(location: NSMaxRange(embed), length: 0))
        tv.deleteBackward(nil)                                   // "]]" → "]"
        #expect(coord.lastComputedStorage.contains(Self.id))
        tv.insertText("]", replacementRange: tv.selectedRange())  // back to "]]"
        #expect(coord.lastComputedStorage == Self.doc)
    }

    @Test func retypingTheNameKeepsTheID() {
        let (tv, coord) = makeEditor()
        let name = (tv.string as NSString).range(of: "a.png")
        tv.setSelectedRange(name)
        tv.insertText("zzz", replacementRange: name)
        #expect(coord.lastComputedStorage == "Cover\n\n![[zzz|\(Self.id)]]\n")
    }

    @Test func insertingAtTheStartOfTheNameKeepsTheID() {
        let (tv, coord) = makeEditor()
        let name = (tv.string as NSString).range(of: "a.png")
        tv.setSelectedRange(NSRange(location: name.location, length: 0))
        tv.insertText("Z", replacementRange: NSRange(location: name.location, length: 0))
        #expect(coord.lastComputedStorage == "Cover\n\n![[Za.png|\(Self.id)]]\n")
    }

    /// Every flavor carries the id now, so the line survives a trip through any
    /// editor — not just an in-app paste.
    @Test func copyCarriesTheIDOnEveryFlavor() {
        let (tv, _) = makeEditor()
        let embed = (tv.string as NSString).range(of: "![[a.png|\(Self.id)]]")
        tv.setSelectedRange(embed)
        tv.copy(nil)

        let pasteboard = NSPasteboard.general
        #expect(pasteboard.string(forType: .string) == "![[a.png|\(Self.id)]]")
        #expect(pasteboard.string(forType: MarkdownPasteboardWriter.markdownType)
                == "![[a.png|\(Self.id)]]")
    }

    @Test func aHandTypedEmbedRoundTrips() {
        let (tv, coord) = makeEditor("Cover\n")
        tv.setSelectedRange(NSRange(location: (tv.string as NSString).length, length: 0))
        tv.insertText("![[b.png|\(Self.id)]]", replacementRange: tv.selectedRange())
        #expect(coord.lastComputedStorage == "Cover\n![[b.png|\(Self.id)]]")
    }

    // MARK: Off by default

    @Test func theOptionIsOffByDefault() {
        #expect(MarkdownEditorConfiguration.default.imageEmbed.keepsIDInSource == false)
        let (tv, _) = makeEditor(keepsIDInSource: false)
        #expect(tv.string == "Cover\n\n![[a.png]]\n")
    }
}
