//
//  SelectedTextOnOpaqueFillTests.swift
//  MarkdownEngineTests
//
//  #215: AppKit repaints selected glyphs in `selectedTextColor` (white in
//  Dark Mode) to stand out against the selection highlight. An opaque
//  `.markdownBlockBackground` fill is painted over that highlight, so the
//  text on it has to keep its own colour - black ink on a white block came
//  out white on white. A translucent fill lets the highlight through and
//  keeps AppKit's colour. Rendered for real: the recolour happens in drawing.
//

import AppKit
import Testing
@testable import MarkdownEngine

@MainActor
@Suite("Selected text on opaque fills")
struct SelectedTextOnOpaqueFillTests {

    private static let text = "plain INK plain"
    private static let ink = NSRange(location: 6, length: 3)

    @MainActor
    private final class Stage {
        let window: NSWindow
        let textView: NativeTextView
        let delegate = MarkdownLayoutManagerDelegate()

        init(fill: NSColor, ink: NSColor = .black, appearance: NSAppearance.Name = .darkAqua) {
            _ = NSApplication.shared
            window = NSWindow(contentRect: NSRect(x: -30000, y: -30000, width: 400, height: 120),
                              styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.appearance = NSAppearance(named: appearance)
            textView = NativeTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 120))
            window.contentView = textView
            let font = NSFont.systemFont(ofSize: 40, weight: .bold)
            let storage = NSMutableAttributedString(string: SelectedTextOnOpaqueFillTests.text, attributes: [
                .font: font, .foregroundColor: NSColor.textColor,
            ])
            storage.addAttributes([.markdownBlockBackground: fill, .foregroundColor: ink],
                                  range: SelectedTextOnOpaqueFillTests.ink)
            textView.textStorage?.setAttributedString(storage)
            if let tlm = textView.textLayoutManager {
                tlm.delegate = delegate
                tlm.invalidateLayout(for: tlm.documentRange)
                tlm.ensureLayout(for: tlm.documentRange)
            }
            window.orderFrontRegardless()
        }

        /// The block's own fill rect, in view coordinates.
        var fillRect: CGRect? {
            guard let tlm = textView.textLayoutManager, let tcm = tlm.textContentManager else { return nil }
            var rect: CGRect?
            tlm.enumerateTextLayoutFragments(from: tcm.documentRange.location, options: [.ensuresLayout]) { fragment in
                rect = (fragment as? MarkdownTextLayoutFragment)?
                    .blockBackgroundFills(at: fragment.layoutFragmentFrame.origin).first?.rect
                return rect == nil
            }
            guard let rect else { return nil }
            let origin = textView.textContainerOrigin
            return rect.offsetBy(dx: origin.x, dy: origin.y)
        }

        /// RGB of every pixel inside `rect`, drawn the way the screen draws it.
        func pixels(in rect: CGRect, selecting range: NSRange) -> [UInt8] {
            textView.setSelectedRange(range)
            textView.display()
            let area = rect.insetBy(dx: 2, dy: 2).intersection(textView.bounds)
            guard let rep = textView.bitmapImageRepForCachingDisplay(in: area) else { return [] }
            textView.cacheDisplay(in: area, to: rep)
            var out: [UInt8] = []
            for y in 0..<rep.pixelsHigh {
                for x in 0..<rep.pixelsWide {
                    guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                    out += [c.redComponent, c.greenComponent, c.blueComponent].map { UInt8(($0 * 255).rounded()) }
                }
            }
            return out
        }

        func close() { window.orderOut(nil) }
    }

    /// Pixels darker than mid-grey: black ink, on a white block or anywhere.
    private static func darkPixels(_ rgb: [UInt8]) -> Int {
        stride(from: 0, to: rgb.count - 2, by: 3).filter { Int(rgb[$0]) + Int(rgb[$0 + 1]) + Int(rgb[$0 + 2]) < 3 * 100 }.count
    }

    private static var all: NSRange { NSRange(location: 0, length: (text as NSString).length) }

    @Test("ink on an opaque block stays its own colour under a selection")
    func opaqueFillKeepsInk() throws {
        let stage = Stage(fill: .white)
        defer { stage.close() }
        let rect = try #require(stage.fillRect)

        let unselected = stage.pixels(in: rect, selecting: NSRange(location: 0, length: 0))
        let selected = stage.pixels(in: rect, selecting: Self.all)

        #expect(Self.darkPixels(unselected) > 50, "sample must draw black ink on the block")
        #expect(Self.darkPixels(selected) > 50, "selected ink vanished: white on white")
        #expect(selected == unselected, "a selection must not change a single pixel on an opaque block")
    }

    @Test("a partial selection keeps the ink too")
    func partialSelectionKeepsInk() throws {
        let stage = Stage(fill: .white)
        defer { stage.close() }
        let rect = try #require(stage.fillRect)

        let unselected = stage.pixels(in: rect, selecting: NSRange(location: 0, length: 0))
        let selected = stage.pixels(in: rect, selecting: NSRange(location: 3, length: 5))

        #expect(Self.darkPixels(selected) > 50)
        #expect(selected == unselected)
    }

    /// An app's inverted highlight: the block takes the text colour, the ink the
    /// page colour, as dynamic colours resolved while drawing.
    @Test("an inverted highlight survives a selection in both appearances",
          arguments: [NSAppearance.Name.darkAqua, .aqua])
    func invertedHighlight(_ appearance: NSAppearance.Name) throws {
        func dynamic(dark: NSColor, light: NSColor) -> NSColor {
            NSColor(name: nil) { $0.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light }
        }
        let stage = Stage(fill: dynamic(dark: .white, light: .black),
                          ink: dynamic(dark: .black, light: .white),
                          appearance: appearance)
        defer { stage.close() }
        let rect = try #require(stage.fillRect)

        let unselected = stage.pixels(in: rect, selecting: NSRange(location: 0, length: 0))
        let selected = stage.pixels(in: rect, selecting: Self.all)
        #expect(selected == unselected, "\(appearance.rawValue): the selection repainted the highlight")
    }

    @Test("a translucent fill keeps AppKit's selected text colour")
    func translucentFillKeepsSelectionColour() throws {
        let stage = Stage(fill: NSColor.white.withAlphaComponent(0.3))
        defer { stage.close() }
        let rect = try #require(stage.fillRect)

        let selected = stage.pixels(in: rect, selecting: Self.all)
        // The highlight shows through, so the glyphs take the selection's white
        // like any selected text, and no black ink is left.
        #expect(Self.darkPixels(selected) == 0)
    }
}
