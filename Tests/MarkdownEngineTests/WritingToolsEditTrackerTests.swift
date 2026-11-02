//
//  WritingToolsEditTrackerTests.swift
//  MarkdownEngineTests
//
//  Created by Luca Chen on 18.10.26.
//
//  Drives UIFoundation's private NSWritingToolsEditTracker the way a proofread
//  steps through its suggestions (remove the edit, add it again) and checks each
//  suggestion's range against where it really is. Unfixed, the second sequence
//  throws inside UIFoundation and takes the process down, so it only runs with
//  `WritingToolsEditTrackerFix` in place.
//

import AppKit
import ObjectiveC
import Testing
@testable import MarkdownEngine

@MainActor
@Suite("Writing Tools edit tracker", .serialized)
struct WritingToolsEditTrackerTests {

    /// AppKit's own remove drops the first suggestion here, without a word.
    @Test(.enabled("no NSWritingToolsEditTracker in this process") { await Tracker.available })
    func steppingInOrderKeepsEverySuggestion() throws {
        let tracker = try #require(Tracker())
        let suggestions = [Suggestion(100, 1, +3), Suggestion(102, 1, 0), Suggestion(104, 1, +2)]
        tracker.apply(suggestions)
        for index in suggestions.indices {
            tracker.step(suggestions[index])
            #expect(tracker.ranges(of: suggestions) == Suggestion.expected(suggestions), "after stepping to suggestion \(index)")
        }
    }

    /// Unfixed: "attempting to add a suggestion that has already been invalidated by previous edits".
    @Test(.enabled("the tracker fix is not in place") { await Tracker.available && WritingToolsEditTrackerFix.isActive })
    func steppingInOrderDoesNotInvalidateTheNextSuggestion() throws {
        let tracker = try #require(Tracker())
        let suggestions = [Suggestion(100, 1, +3), Suggestion(102, 1, 0), Suggestion(104, 3, -2)]
        tracker.apply(suggestions)
        for suggestion in suggestions { tracker.step(suggestion) }
        #expect(tracker.ranges(of: suggestions) == Suggestion.expected(suggestions))
    }

    /// Browsing in order, jumping around, rejecting and restoring, over many sessions.
    @Test(.enabled("the tracker fix is not in place") { await Tracker.available && WritingToolsEditTrackerFix.isActive })
    func everyStepKeepsEveryRange() throws {
        var random = SeededRandom(seed: 0x5EED)
        for session in 0..<300 {
            let tracker = try #require(Tracker())
            var location = 100
            var suggestions: [Suggestion] = (0..<(3 + random.next(10))).map { _ in
                location += 1 + random.next(4)
                let length = 1 + random.next(8)
                defer { location += length }
                return Suggestion(location, length, max(1 - length, random.next(9) - 4))
            }
            let full = suggestions.map(\.delta)
            tracker.apply(suggestions)
            for step in 0..<(3 * suggestions.count) {
                let index = random.next(4) == 0 ? random.next(suggestions.count) : step % suggestions.count
                if random.next(6) == 0 { suggestions[index].delta = suggestions[index].delta == 0 ? full[index] : 0 }
                tracker.step(suggestions[index])
                let ranges = tracker.ranges(of: suggestions)
                guard ranges == Suggestion.expected(suggestions) else {
                    Issue.record("session \(session) step \(step): \(ranges) instead of \(Suggestion.expected(suggestions))")
                    return
                }
            }
        }
    }
}

// MARK: - Driving the tracker

private struct Suggestion {
    let uuid = NSUUID()
    let range: NSRange
    var delta: Int

    init(_ location: Int, _ length: Int, _ delta: Int) {
        range = NSRange(location: location, length: length)
        self.delta = delta
    }

    /// Where each suggestion sits once all of them are in: shifted by the ones before it.
    static func expected(_ suggestions: [Suggestion]) -> [NSRange] {
        var shift = 0
        return suggestions.map { suggestion in
            defer { shift += suggestion.delta }
            return NSRange(location: suggestion.range.location + shift, length: suggestion.range.length + suggestion.delta)
        }
    }
}

@MainActor
private final class Tracker {
    static var available: Bool {
        _ = NSTextView()
        WritingToolsEditTrackerFix.install()
        return NSClassFromString("NSWritingToolsEditTracker") != nil
    }

    private let object: NSObject

    init?() {
        let initSelector = NSSelectorFromString("initWithContextRange:")
        typealias Init = @convention(c) (AnyObject, Selector, NSRange) -> Unmanaged<NSObject>?
        guard let cls = NSClassFromString("NSWritingToolsEditTracker") as? NSObject.Type,
              let initIMP = class_getMethodImplementation(cls, initSelector),
              let allocated = cls.perform(NSSelectorFromString("alloc"))?.takeUnretainedValue(),
              let made = unsafeBitCast(initIMP, to: Init.self)(allocated, initSelector, NSRange(location: 0, length: 1000))?
                  .takeRetainedValue() else { return nil }
        object = made
    }

    /// Proofreading puts every suggestion in, in document order.
    func apply(_ suggestions: [Suggestion]) {
        suggestions.forEach(add)
    }

    /// What a state change does: AppKit removes the suggestion's edit and adds it again.
    func step(_ suggestion: Suggestion) {
        let selector = NSSelectorFromString("removeEditForSuggestionWithUUID:")
        typealias Remove = @convention(c) (AnyObject, Selector, AnyObject) -> Void
        unsafeBitCast(object.method(for: selector), to: Remove.self)(object, selector, suggestion.uuid)
        add(suggestion)
    }

    func ranges(of suggestions: [Suggestion]) -> [NSRange] {
        let selector = NSSelectorFromString("rangeOfSuggestionWithRange:UUID:applyDelta:")
        typealias Query = @convention(c) (AnyObject, Selector, NSRange, AnyObject, Bool) -> NSRange
        let query = unsafeBitCast(object.method(for: selector), to: Query.self)
        return suggestions.map { query(object, selector, $0.range, $0.uuid, true) }
    }

    private func add(_ suggestion: Suggestion) {
        let selector = NSSelectorFromString("addEditForSuggestionWithRange:lengthDelta:UUID:")
        typealias Add = @convention(c) (AnyObject, Selector, NSRange, Int, AnyObject) -> Void
        unsafeBitCast(object.method(for: selector), to: Add.self)(object, selector, suggestion.range, suggestion.delta, suggestion.uuid)
    }
}

/// A small LCG, so a failing session can be replayed.
private struct SeededRandom {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next(_ bound: Int) -> Int {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return Int((state >> 33) % UInt64(bound))
    }
}
