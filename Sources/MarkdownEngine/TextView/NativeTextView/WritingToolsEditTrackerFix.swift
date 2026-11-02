//
//  WritingToolsEditTrackerFix.swift
//  MarkdownEngine
//
//  Created by Luca Chen on 18.10.26.
//
//  Stepping through a proofread crashes AppKit ("attempting to add a suggestion that
//  has already been invalidated by previous edits"), in a plain NSTextView too
//  (measured on 27.0.1). Each step removes the suggestion's edit from UIFoundation's
//  private NSWritingToolsEditTracker and appends it again. The tracker stores every
//  edit relative to the ones before it, and its remove shifts the later edits by
//  comparing ranges taken at different points of that sequence: once a step has
//  moved an edit that changes the text's length behind one further down, the next
//  remove shifts the wrong edits. Then an add asserts, or a suggestion silently
//  lands on other characters or drops out.
//
//  The fix replaces that remove with a rebuild: the remaining suggestions are added
//  again from their original ranges, in document order. It only takes over trackers
//  that hold nothing but suggestions, and only if the class looks as measured;
//  everything else still runs AppKit's own code.
//

import AppKit
import ObjectiveC

enum WritingToolsEditTrackerFix {
    /// Whether the fix is in place (the tracker exists and matches the measured shape).
    static var isActive: Bool { installed }

    /// Process-wide and idempotent; called wherever inline Writing Tools get enabled.
    static func install() { _ = installed }

    private static let installed: Bool = {
        guard let cls = NSClassFromString("NSWritingToolsEditTracker"), shapeMatches(cls),
              let add = class_getInstanceMethod(cls, addSuggestionSelector),
              let addPlain = class_getInstanceMethod(cls, addPlainSelector),
              let remove = class_getInstanceMethod(cls, removeSelector) else { return false }
        let originalAdd = unsafeBitCast(method_getImplementation(add), to: AddSuggestion.self)
        let originalAddPlain = unsafeBitCast(method_getImplementation(addPlain), to: AddPlain.self)
        let originalRemove = unsafeBitCast(method_getImplementation(remove), to: Remove.self)

        let addBlock: @convention(block) (NSObject, NSRange, Int, NSObject) -> Void = { tracker, range, delta, uuid in
            originalAdd(tracker, addSuggestionSelector, range, delta, uuid)
            history(of: tracker).record(uuid, range, delta)
        }
        let addPlainBlock: @convention(block) (NSObject, NSRange, Int) -> Void = { tracker, range, delta in
            originalAddPlain(tracker, addPlainSelector, range, delta)
            history(of: tracker).hasPlainEdits = true
        }
        let removeBlock: @convention(block) (NSObject, NSObject) -> Void = { tracker, uuid in
            let history = history(of: tracker)
            guard !history.hasPlainEdits, history.suggestions[uuid] != nil else {
                originalRemove(tracker, removeSelector, uuid)
                history.suggestions[uuid] = nil
                return
            }
            history.suggestions[uuid] = nil
            (tracker.value(forKey: "_edits") as? NSMutableArray)?.removeAllObjects()
            (tracker.value(forKey: "_uuidToEdit") as? NSMapTable<AnyObject, AnyObject>)?.removeAllObjects()
            tracker.setValue(tracker.value(forKey: "_contextRange"), forKey: "_currentContextRange")
            for (uuid, entry) in history.suggestions.sorted(by: { ($0.value.range.location, $0.value.order) < ($1.value.range.location, $1.value.order) }) {
                originalAdd(tracker, addSuggestionSelector, entry.range, entry.delta, uuid)
            }
        }
        method_setImplementation(add, imp_implementationWithBlock(addBlock))
        method_setImplementation(addPlain, imp_implementationWithBlock(addPlainBlock))
        method_setImplementation(remove, imp_implementationWithBlock(removeBlock))
        return true
    }()

    private typealias AddSuggestion = @convention(c) (NSObject, Selector, NSRange, Int, NSObject) -> Void
    private typealias AddPlain = @convention(c) (NSObject, Selector, NSRange, Int) -> Void
    private typealias Remove = @convention(c) (NSObject, Selector, NSObject) -> Void
    private static let addSuggestionSelector = NSSelectorFromString("addEditForSuggestionWithRange:lengthDelta:UUID:")
    private static let addPlainSelector = NSSelectorFromString("addEditForRange:lengthDelta:")
    private static let removeSelector = NSSelectorFromString("removeEditForSuggestionWithUUID:")

    /// The ivars the rebuild touches and the methods it replaces, as on macOS 27.0.1.
    private static func shapeMatches(_ cls: AnyClass) -> Bool {
        let range = "{_NSRange=\"location\"Q\"length\"Q}"
        let ivars = ["_edits": "@\"NSMutableArray\"", "_uuidToEdit": "@\"NSMapTable\"",
                     "_contextRange": range, "_currentContextRange": range]
        let methods = [addSuggestionSelector: "v48@0:8{_NSRange=QQ}16q32@40",
                       addPlainSelector: "v40@0:8{_NSRange=QQ}16q32",
                       removeSelector: "v24@0:8@16"]
        return ivars.allSatisfy { name, type in
            class_getInstanceVariable(cls, name).flatMap(ivar_getTypeEncoding).map { String(cString: $0) } == type
        } && methods.allSatisfy { selector, type in
            class_getInstanceMethod(cls, selector).flatMap(method_getTypeEncoding).map { String(cString: $0) } == type
        }
    }

    /// Every suggestion a tracker was given, with its original range and delta.
    private final class History {
        var suggestions: [NSObject: (range: NSRange, delta: Int, order: Int)] = [:]
        var hasPlainEdits = false
        private var next = 0

        func record(_ uuid: NSObject, _ range: NSRange, _ delta: Int) {
            suggestions[uuid] = (range, delta, next)
            next += 1
        }
    }

    // Trackers live and die on the main thread with their Writing Tools session.
    nonisolated(unsafe) private static let histories = NSMapTable<NSObject, History>.weakToStrongObjects()

    private static func history(of tracker: NSObject) -> History {
        if let history = histories.object(forKey: tracker) { return history }
        let history = History()
        histories.setObject(history, forKey: tracker)
        return history
    }
}
