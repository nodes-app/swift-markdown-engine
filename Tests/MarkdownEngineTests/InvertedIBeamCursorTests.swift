#if os(macOS)
//
//  InvertedIBeamCursorTests.swift
//  MarkdownEngineTests
//
//  Created by Luca Chen on 30.07.26.
//
//  The system I-beam is recolored — core → the span's ink, halo → its block —
//  so the pointer stays visible inside an inverted highlight.
//

import AppKit
import Testing
@testable import MarkdownEngine

@MainActor
@Suite("Inverted I-beam cursor")
struct InvertedIBeamCursorTests {

    init() { _ = NSApplication.shared }

    /// Every opaque pixel of the largest representation, bucketed by hue.
    private func pixelCounts(_ image: NSImage) -> (ink: Int, block: Int, other: Int) {
        guard let rep = image.representations.compactMap({ $0 as? NSBitmapImageRep })
            .max(by: { $0.pixelsWide < $1.pixelsWide }) else { return (0, 0, 0) }
        var ink = 0, block = 0, other = 0
        for x in 0..<rep.pixelsWide {
            for y in 0..<rep.pixelsHigh {
                guard let px = rep.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB),
                      px.alphaComponent > 0.5 else { continue }
                if px.redComponent > 0.8, px.greenComponent < 0.2 { ink += 1 }
                else if px.greenComponent > 0.8, px.redComponent < 0.2 { block += 1 }
                else { other += 1 }
            }
        }
        return (ink, block, other)
    }

    @Test("the glyph is repainted in exactly the two given colors")
    func recolorsCoreAndHalo() throws {
        let cursor = try #require(InvertedIBeamCursor.cursor(ink: .red, block: .green))

        let counts = pixelCounts(cursor.image)

        #expect(counts.ink > 0)                       // the core carries the shape
        #expect(counts.block > counts.ink)            // the halo is the wider ring
        #expect(counts.other == 0)                    // nothing of the system's own colors left
        #expect(cursor.hotSpot == NSCursor.iBeam.hotSpot)
        #expect(cursor.image.size == NSCursor.iBeam.image.size)
    }

    /// Recoloring walks ~65k pixels across the 1x–10x representations, which is
    /// once per color pair and must never land on the mouse-move path.
    @Test("same colors reuse the built cursor")
    func cachesPerColorPair() throws {
        let first = try #require(InvertedIBeamCursor.cursor(ink: .black, block: .white))
        let second = try #require(InvertedIBeamCursor.cursor(ink: .black, block: .white))
        let different = try #require(InvertedIBeamCursor.cursor(ink: .white, block: .black))

        #expect(first === second)
        #expect(first !== different)
    }
}
#endif
