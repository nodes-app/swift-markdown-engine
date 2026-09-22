//
//  TableHiddenSourceGeometryTests.swift
//  MarkdownEngine
//
//  Created by Luca Chen on 18.08.26.
//
//  A collapsed block hides its raw source by shrinking it to a near-zero font
//  and kerning the rest of its width away. Getting that kern wrong does not
//  just leave a sliver behind — it can throw the whole document out of the
//  text container.
//

import AppKit
import Testing
@testable import MarkdownEngine

@Suite("Hidden source geometry")
@MainActor
struct TableHiddenSourceGeometryTests {

    // MARK: - Hidden-source geometry

    /// `.kern` applies to EVERY character in its range, so hiding a run with the
    /// run's FULL width made a long run `(n - 1)` widths too negative. Most such
    /// lines clamp to zero width; a line carrying `z` + U+0304 instead laid out
    /// at x = +1783 with width -1783 and poisoned the container's usage bounds,
    /// which is what made the note render blank.
    @Test func collapsedTableWithACombiningMarkStaysInsideTheContainer() throws {
        let viewport = NSSize(width: 700, height: 900)
        let source = """
        | Statement | Verdict |
        |---|---|
        | `P(k)` and `K(k)` do not depend on the measured values `z̄` | **TRUE** (linear KF) |
        | Detectability is implied by observability | **TRUE** |
        """
        let stack = HeightBehaviorStack(viewport: viewport)
        let tv = stack.textView
        tv.string = source
        let bridge = tv.textLayoutManager.map { LayoutBridge($0) }
        tv.layoutBridge = bridge
        let (font, style) = TextStylingService.makeBaseFontAndStyle(
            fontName: "Helvetica", fontSize: 15, configuration: .default
        )
        TextStylingService.restyle(
            textView: tv,
            layoutBridge: bridge,
            paragraphCandidates: [NSRange(location: 0, length: (source as NSString).length)],
            baseFont: font,
            paragraphStyle: style,
            caretLocation: (source as NSString).length,
            activeTokenIndices: [],
            wikiLinkIDProvider: { _ in nil }
        )
        let tlm = try #require(tv.textLayoutManager)
        let tcm = try #require(tlm.textContentManager)
        tlm.ensureLayout(for: tcm.documentRange)

        let usage = tlm.usageBoundsForTextContainer
        #expect(usage.minX >= -0.5)
        #expect(usage.width <= viewport.width + 0.5)
    }
}
