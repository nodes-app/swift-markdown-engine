//
//  CorrectionUnderlineTests.swift
//  MarkdownEngineTests
//
//  Created by Luca Chen on 09.10.26.
//
//  An autocorrection's underline does not survive a note switch. AppKit's
//  correction machinery is private, so the underline is put up through it here
//  and a missing selector skips rather than fails.
//

import AppKit
import Testing
@testable import MarkdownEngine

@MainActor
@Suite("Autocorrection underline")
struct CorrectionUnderlineTests {

    private func spin(_ seconds: TimeInterval) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }

    /// The underline views AppKit has drawn in `view`.
    private func underlines(in view: NSView) -> [NSView] {
        let found = String(describing: type(of: view)) == "NSCorrectionIndicatorUnderlineView" ? [view] : []
        return found + view.subviews.flatMap { underlines(in: $0) }
    }

    private typealias Ask = @convention(c) (AnyObject, Selector) -> Bool

    @Test("A note switch drops the outgoing note's autocorrection underline")
    func switchDropsTheUnderline() throws {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: -4000, y: -4000, width: 600, height: 400),
                              styleMask: [.titled], backing: .buffered, defer: false)
        let textView = NativeTextView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        textView.configuration = .default
        window.contentView = textView
        window.orderFront(nil)
        defer { window.orderOut(nil) }
        textView.string = "hello wrld and more text\nsecond line of the outgoing note"
        spin(0.2)

        // What AppKit does after it corrects "wrld": the range, then its line.
        let controllerKey = NSSelectorFromString("textCheckingController")
        let add = NSSelectorFromString("_addCorrectionIndicatorUnderlineIndexes:")
        let show = NSSelectorFromString("showCorrectionIndicatorUnderlines")
        let tracks = NSSelectorFromString("hasCorrectionIndicatorUnderlines")
        guard textView.responds(to: controllerKey),
              let controller = textView.perform(controllerKey)?.takeUnretainedValue() as? NSObject,
              controller.responds(to: add), controller.responds(to: show), controller.responds(to: tracks)
        else { return }
        controller.perform(add, with: NSIndexSet(indexesIn: NSRange(location: 6, length: 4)))
        controller.perform(show)
        spin(0.5)
        try #require(!underlines(in: textView).isEmpty, "AppKit drew no underline")

        textView.removeCorrectionUnderlines()
        textView.textStorage?.setAttributedString(NSAttributedString(string:
            "an incoming note with entirely different words\nand a second line of its own"))
        spin(1.0)

        #expect(underlines(in: textView).isEmpty, "the outgoing note's underline stood over the incoming one")
        #expect(!unsafeBitCast(controller.method(for: tracks), to: Ask.self)(controller, tracks),
                "the underline's range moved into the incoming note")
    }
}
