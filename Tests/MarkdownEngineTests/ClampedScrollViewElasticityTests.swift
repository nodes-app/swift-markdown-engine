//
//  ClampedScrollViewElasticityTests.swift
//  MarkdownEngineTests
//
//  A trackpad pushed past an edge must never COMMIT a position past it.
//
//  AppKit applies a scroll on the next display refresh, not inside
//  `scrollWheel(with:)`, so `clampToInsets()` (run right after `super`) only
//  ever corrects the PREVIOUS event's movement. With the rubber band allowed,
//  every refresh committed a fresh overshoot and every event pulled it back:
//  the content flickered between the edge and 12–24pt past it while held.
//
//  Needs a window and a running main run loop — the scroll is applied by
//  AppKit's display-refresh animator, so headless calls never see it.
//

import AppKit
import Testing
@testable import MarkdownEngine

@MainActor
@Suite("ClampedScrollView — no overshoot past an edge")
struct ClampedScrollViewElasticityTests {

    /// Synthesized continuous (trackpad) scroll event. `phase` / `momentum` are
    /// the raw CGEvent scroll-phase values (began 1, changed 2, ended 4,
    /// mayBegin 128; momentum begin 1, continue 2, end 3).
    private func trackpadEvent(dy: Int32, phase: Int64, momentum: Int64 = 0) -> NSEvent {
        let event = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1,
                            wheel1: dy, wheel2: 0, wheel3: 0)!
        event.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
        event.setIntegerValueField(.scrollWheelEventPointDeltaAxis1, value: Int64(dy))
        event.setIntegerValueField(.scrollWheelEventFixedPtDeltaAxis1, value: Int64(dy) * 65536)
        event.setIntegerValueField(CGEventField(rawValue: 99)!, value: phase)
        event.setIntegerValueField(CGEventField(rawValue: 123)!, value: momentum)
        return NSEvent(cgEvent: event)!
    }

    /// Every bounds origin the clip view commits, in order.
    private final class BoundsRecorder: NSObject {
        private(set) var origins: [CGFloat] = []
        init(_ clip: NSClipView) {
            super.init()
            clip.postsBoundsChangedNotifications = true
            NotificationCenter.default.addObserver(
                self, selector: #selector(changed(_:)),
                name: NSView.boundsDidChangeNotification, object: clip
            )
        }
        @objc private func changed(_ note: Notification) {
            guard let clip = note.object as? NSClipView else { return }
            origins.append(clip.bounds.origin.y)
        }
    }

    /// Push past the edge with a held gesture and then a momentum flick,
    /// feeding events at trackpad cadence while the run loop keeps turning.
    /// Returns the furthest any committed position got past the edge.
    private func worstOvershoot(atBottom: Bool) -> CGFloat {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 400),
                              styleMask: [.titled], backing: .buffered, defer: false)
        let scrollView = ClampedScrollView(frame: NSRect(x: 0, y: 0, width: 500, height: 400))
        scrollView.documentView = NSView(frame: NSRect(x: 0, y: 0, width: 500, height: 3000))
        window.contentView = scrollView
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }

        let clip = scrollView.contentView
        let maxY = 3000 - clip.bounds.height
        clip.scroll(to: NSPoint(x: 0, y: atBottom ? maxY : 0))
        scrollView.reflectScrolledClipView(clip)

        let recorder = BoundsRecorder(clip)
        let sign: Int32 = atBottom ? 1 : -1
        var events = [trackpadEvent(dy: 0, phase: 128), trackpadEvent(dy: 12 * sign, phase: 1)]
        for _ in 0..<12 { events.append(trackpadEvent(dy: 12 * sign, phase: 2)) }
        events.append(trackpadEvent(dy: 0, phase: 4))
        events.append(trackpadEvent(dy: 40 * sign, phase: 0, momentum: 1))
        for v in stride(from: 36, to: 2, by: -4) { events.append(trackpadEvent(dy: Int32(v) * sign, phase: 0, momentum: 2)) }
        events.append(trackpadEvent(dy: 0, phase: 0, momentum: 3))

        for event in events {
            scrollView.scrollWheel(with: event)
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.008))
        }
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.5))

        return recorder.origins
            .map { atBottom ? $0 - maxY : -$0 }
            .max() ?? 0
    }

    @Test("pushing past the top never commits a position above it")
    func noOvershootAtTop() {
        #expect(worstOvershoot(atBottom: false) <= 0.5)
    }

    @Test("pushing past the bottom never commits a position below it")
    func noOvershootAtBottom() {
        #expect(worstOvershoot(atBottom: true) <= 0.5)
    }
}
