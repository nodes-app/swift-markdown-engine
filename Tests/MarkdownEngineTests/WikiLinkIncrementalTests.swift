#if os(macOS)
//
//  WikiLinkIncrementalTests.swift
//  MarkdownEngine
//
//  Created by Luca Chen on 07.07.26.
//

import Foundation
import Testing
@testable import MarkdownEngine

@Suite("WikiLink incremental storage state")
struct WikiLinkIncrementalTests {

    /// storage: "Hello [[Note|abc123]] world" → display: "Hello [[Note]] world"
    /// display link range {6, 8}, storage link range {6, 15}.
    private func seed() -> (display: String, storage: String,
                            meta: [WikiLinkService.RangeKey: WikiLinkService.LinkMetadata]) {
        let storage = "Hello [[Note|abc123]] world"
        let state = WikiLinkService.makeDisplayState(from: storage)
        return (state.display, storage, state.metadata)
    }

    @Test func appendAfterLinkSplicesStorage() throws {
        let (display, storage, meta) = seed()
        let newDisplay = display + "x"                       // typed "x" at the end
        let result = try #require(WikiLinkService.updatedStorageState(
            displayText: newDisplay,
            editedRange: NSRange(location: (display as NSString).length, length: 1),
            changeInLength: 1,
            previousStorage: storage,
            previousMetadata: meta
        ))
        #expect(result.storage == "Hello [[Note|abc123]] worldx")
        // Link before the edit: metadata unchanged.
        let key = try #require(result.metadata.keys.first)
        #expect(key.location == 6 && key.length == 8)
        #expect(result.metadata[key]?.id == "abc123")
        #expect(result.metadata[key]?.storageRange == NSRange(location: 6, length: 15))
    }

    @Test func insertBeforeLinkShiftsMetadata() throws {
        let (display, storage, meta) = seed()
        let newDisplay = "x" + display                       // typed "x" at position 0
        let result = try #require(WikiLinkService.updatedStorageState(
            displayText: newDisplay,
            editedRange: NSRange(location: 0, length: 1),
            changeInLength: 1,
            previousStorage: storage,
            previousMetadata: meta
        ))
        #expect(result.storage == "xHello [[Note|abc123]] world")
        let key = try #require(result.metadata.keys.first)
        #expect(key.location == 7 && key.length == 8)        // shifted by +1
        #expect(result.metadata[key]?.storageRange == NSRange(location: 7, length: 15))
        #expect(result.metadata[key]?.id == "abc123")
    }

    @Test func deletionInPlainTextWorks() throws {
        let (display, storage, meta) = seed()
        // Delete the "l" of "world" (display location 18 — far enough from the
        // link that neither the ±3 probe nor the metadata guard band trips).
        let ns = display as NSString
        let newDisplay = ns.replacingCharacters(in: NSRange(location: 18, length: 1), with: "")
        let result = try #require(WikiLinkService.updatedStorageState(
            displayText: newDisplay,
            editedRange: NSRange(location: 18, length: 0),
            changeInLength: -1,
            previousStorage: storage,
            previousMetadata: meta
        ))
        #expect(result.storage == "Hello [[Note|abc123]] word")
    }

    @Test func editTouchingLinkFallsBack() {
        let (display, storage, meta) = seed()
        // Typing directly after "]]" (display location 14) is inside the ±3 guard band.
        let result = WikiLinkService.updatedStorageState(
            displayText: display + " ",
            editedRange: NSRange(location: 14, length: 1),
            changeInLength: 1,
            previousStorage: storage,
            previousMetadata: meta
        )
        #expect(result == nil)
    }

    @Test func editCreatingLinkSyntaxFallsBack() {
        // "[[x]" + typed "]" completes a link → the new-text probe sees "]]" → bail.
        let display = "pre [[x] post"
        let ns = display as NSString
        let newDisplay = ns.replacingCharacters(in: NSRange(location: 8, length: 0), with: "]")
        let result = WikiLinkService.updatedStorageState(
            displayText: newDisplay,
            editedRange: NSRange(location: 8, length: 1),
            changeInLength: 1,
            previousStorage: display,
            previousMetadata: [:]
        )
        #expect(result == nil)
    }

    @Test func unknownDeltaFallsBack() {
        let (display, storage, meta) = seed()
        let result = WikiLinkService.updatedStorageState(
            displayText: display,
            editedRange: NSRange(location: 0, length: 0),
            changeInLength: Int.min,
            previousStorage: storage,
            previousMetadata: meta
        )
        #expect(result == nil)
    }

    /// Property sweep: inserting one char at every position that takes the fast
    /// path must yield a storage string that (a) round-trips back to exactly the
    /// new display text and (b) preserves every link id. (Comparing against a
    /// full `makeStorageState(textStorage: nil)` rebuild would be wrong here —
    /// the full rebuild loses ids when link ranges shift, which is precisely
    /// what the incremental path fixes.)
    @Test func spliceRoundTripsAtEverySafePosition() {
        let storage = "aaaa [[One|id1]] bbbb [[Two|id2]] cccc"
        let state = WikiLinkService.makeDisplayState(from: storage)
        let display = state.display as NSString
        var fastPathTaken = 0

        for position in 0...display.length {
            let newDisplay = display.replacingCharacters(in: NSRange(location: position, length: 0), with: "q")
            guard let fast = WikiLinkService.updatedStorageState(
                displayText: newDisplay,
                editedRange: NSRange(location: position, length: 1),
                changeInLength: 1,
                previousStorage: storage,
                previousMetadata: state.metadata
            ) else { continue }                              // guarded position → fallback, fine
            fastPathTaken += 1
            let roundTrip = WikiLinkService.makeDisplayState(from: fast.storage)
            #expect(roundTrip.display == newDisplay, "display round-trip diverged at position \(position)")
            #expect(fast.metadata.values.compactMap(\.id).sorted() == ["id1", "id2"],
                    "link id lost at position \(position)")
        }
        #expect(fastPathTaken > 0, "sweep was vacuous — no position took the fast path")
    }
}
#endif
