//
//  WideTableRevealTests.swift
//  MarkdownEngineTests
//
//  Created by Luca Chen on 27.11.26.
//
//  A wide table is turned into a bitmap only once it comes near the viewport
//  (#227). Its image view did that at mount for every wide table in the
//  document, on screen or not.
//

import AppKit
import SwiftUI
import Testing
@testable import MarkdownEngine

@MainActor
@Suite("Wide table reveal", .serialized)
struct WideTableRevealTests {

    private static func wideTable(_ n: Int) -> String {
        let cells = (0..<4).map { "Table\(n)IdentifierThatCannotBreakAcrossLines\($0)" }
        return "| " + cells.joined(separator: " | ") + " |\n|---|---|---|---|\n| "
            + cells.map { "Value\($0)" }.joined(separator: " | ") + " |"
    }

    /// Three wide tables, each a few screens below the one before.
    private static let document = (0..<3).map { n in
        "## Table \(n)\n\n" + wideTable(n) + "\n\n"
            + (1...30).map { "Line \($0) of prose between the tables." }.joined(separator: "\n\n")
    }.joined(separator: "\n\n")

    /// Whether each wide table has its image yet, top to bottom.
    private static func revealed(in window: NSWindow) -> [Bool] {
        guard let textView = findTextView(window.contentView) else { return [] }
        return textView.wideTableOverlays.values
            .sorted { $0.frame.minY < $1.frame.minY }
            .map { ($0.documentView as? NSImageView)?.image != nil }
    }

    private static func findTextView(_ root: NSView?) -> NativeTextView? {
        guard let root else { return nil }
        if let scrollView = root as? NSScrollView, let textView = scrollView.nativeTextView { return textView }
        for sub in root.subviews {
            if let found = findTextView(sub) { return found }
        }
        return nil
    }

    private static func show(height: CGFloat, configuration: MarkdownEditorConfiguration = .default) -> NSWindow {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: -30000, y: -30000, width: 700, height: height),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: NativeTextViewWrapper(
            text: .constant(document), configuration: configuration, documentId: "reveal"
        ))
        window.orderFrontRegardless()
        MainRunLoop.spin()
        return window
    }

    @Test("a wide table far below the viewport gets its image when it is scrolled to")
    func farTableWaitsForTheScroll() async {
        let (atMount, scrolledTo) = await MainRunLoop.callout {
            let window = Self.show(height: 500)
            defer { window.close() }
            let atMount = Self.revealed(in: window)
            guard let textView = Self.findTextView(window.contentView),
                  let clip = textView.enclosingScrollView?.contentView,
                  let last = textView.wideTableOverlays.values.max(by: { $0.frame.minY < $1.frame.minY }),
                  let host = last.superview else { return (atMount, [Bool]()) }
            let top = clip.convert(last.frame, from: host).minY
            clip.scroll(to: NSPoint(x: 0, y: clip.bounds.minY + top - 40))
            textView.enclosingScrollView?.reflectScrolledClipView(clip)
            return (atMount, Self.revealed(in: window))
        }
        #expect(atMount == [true, false, false], "only the table on screen is drawn")
        #expect(scrolledTo.last == true, "the last table has its image once it is in view")
    }

    @Test("a window grown taller reveals the tables it brings into view")
    func tallerWindowRevealsTables() async {
        let (atMount, grown) = await MainRunLoop.callout {
            let window = Self.show(height: 300)
            defer { window.close() }
            let atMount = Self.revealed(in: window)
            window.setContentSize(NSSize(width: 700, height: 3000))
            window.layoutIfNeeded()
            return (atMount, Self.revealed(in: window))
        }
        #expect(atMount.count == 3 && atMount.first == true)
        #expect(grown == [true, true, true])
    }

    @Test("a header band that grows moves a table into view and reveals it")
    func growingBandRevealsTables() async {
        let (passedOver, banded) = await MainRunLoop.callout { () -> ([Bool], [Bool]) in
            let window = Self.show(height: 500)
            defer { window.close() }
            guard let textView = Self.findTextView(window.contentView),
                  let container = textView.superview as? NativeTextViewContainer,
                  let clip = textView.enclosingScrollView?.contentView,
                  let middle = textView.wideTableOverlays.values.sorted(by: { $0.frame.minY < $1.frame.minY }).dropFirst().first,
                  let host = middle.superview else { return ([], []) }
            // One jump well past the middle table, which never came near the viewport.
            let middleTop = clip.convert(middle.frame, from: host).minY
            clip.scroll(to: NSPoint(x: 0, y: clip.bounds.minY + middleTop + 1500))
            textView.enclosingScrollView?.reflectScrolledClipView(clip)
            let passedOver = Self.revealed(in: window)
            container.headerHeight = 1500
            return (passedOver, Self.revealed(in: window))
        }
        #expect(passedOver.dropFirst().first == false)
        #expect(banded.dropFirst().first == true, "the band put the middle table on screen")
    }

    @Test("an editor that fits its content shows every wide table")
    func fitsContentRevealsEveryTable() async {
        let revealed = await MainRunLoop.callout {
            let window = Self.show(height: 500, configuration: .init(heightBehavior: .fitsContent))
            defer { window.close() }
            return Self.revealed(in: window)
        }
        #expect(revealed == [true, true, true], "no viewport of its own tells it what shows")
    }
}
