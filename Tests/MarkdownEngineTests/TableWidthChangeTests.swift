//
//  TableWidthChangeTests.swift
//  MarkdownEngineTests
//
//  Rendered tables cache an image whose cell wrapping depends on the current
//  text-container width. Resizing must restyle those table paragraphs so the
//  cached attachment cannot keep an obsolete, wider layout.
//

import AppKit
import SwiftUI
import Testing
@testable import MarkdownEngine

@MainActor
@Suite("Table width changes")
struct TableWidthChangeTests {

    @Test func wrappedTableReflowsAfterRapidViewportShrink() async throws {
        let wrapper = NativeTextViewWrapper(
            text: .constant(Self.wideSource),
            isEditable: false
        )
        let host = NSHostingController(rootView: wrapper)
        let window = NSWindow(contentViewController: host)
        window.minSize = NSSize(width: 680, height: 440)
        window.styleMask.insert(.fullSizeContentView)
        window.setContentSize(NSSize(width: 900, height: 680))
        window.layoutIfNeeded()
        await nextMainQueueTurn()

        let textView = try await nativeTextView(in: host.view)
        let tableRange = (Self.wideSource as NSString).range(of: "| Rechtsform")
        let initialBounds = try await renderedTableBounds(
            in: textView,
            tableRange: tableRange
        )
        let initialContainerWidth = try #require(textView.textContainer?.size.width)

        for width in [820.0, 760.0, 700.0, 680.0] {
            window.setContentSize(NSSize(width: width, height: 680))
            window.layoutIfNeeded()
        }
        await nextMainQueueTurn()

        let resizedBounds = try await renderedTableBounds(
            in: textView,
            tableRange: tableRange
        )
        let finalContainerWidth = try #require(textView.textContainer?.size.width)

        #expect(finalContainerWidth < initialContainerWidth)
        #expect(resizedBounds.width <= finalContainerWidth + 0.5)
        #expect(resizedBounds.width < initialBounds.width - 20)
        _ = window
    }

    private func nativeTextView(in rootView: NSView) async throws -> NativeTextView {
        for _ in 0..<20 {
            if let textView = descendantViews(in: rootView)
                .compactMap({ $0 as? NativeTextView })
                .first {
                return textView
            }
            await nextMainQueueTurn()
        }
        Issue.record("NativeTextView was not attached")
        throw TestFailure.missingTextView
    }

    private func renderedTableBounds(
        in textView: NativeTextView,
        tableRange: NSRange
    ) async throws -> CGRect {
        for _ in 0..<20 {
            var bounds: CGRect?
            textView.textStorage?.enumerateAttribute(
                .latexBounds,
                in: tableRange,
                options: []
            ) { value, _, stop in
                guard let value = value as? NSValue else { return }
                bounds = value.rectValue
                stop.pointee = true
            }
            if let bounds { return bounds }
            await nextMainQueueTurn()
        }
        Issue.record("Rendered table bounds were not available")
        throw TestFailure.missingTableBounds
    }

    private func nextMainQueueTurn() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async {
                continuation.resume()
            }
        }
    }

    private func descendantViews(in view: NSView) -> [NSView] {
        view.subviews.flatMap { child in
            [child] + descendantViews(in: child)
        }
    }

    private enum TestFailure: Error {
        case missingTextView
        case missingTableBounds
    }

    private static let wideSource = """
    | Rechtsform | Gründungskosten | Laufende Kosten |
    |---|---|---|
    | Einzelunternehmen (Kleingewerbe) | 20–60€ Gewerbeanmeldung, jeder Gesellschafter meldet einzeln an | ~0€, nur Steuerberater optional, dreihundert bis achthundert Euro |
    | GbR | Notar und Handelsregister etwa dreihundert bis fünfhundert Euro | Gesellschaftervertrag empfohlen, Anwalt fünfhundert bis eintausendfünfhundert |
    """
}
