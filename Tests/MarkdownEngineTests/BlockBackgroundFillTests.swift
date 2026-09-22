//
//  BlockBackgroundFillTests.swift
//  MarkdownEngineTests
//
//  `.markdownBlockBackground` fills the LINE BOX, not the glyph box: a
//  highlight that wraps over several lines has to come out as one block with
//  no seam between the lines, at any font size and any line-height extra
//  spacing. Headless — the fills are geometry, no window needed.
//

import AppKit
import Testing
@testable import MarkdownEngine

@MainActor
@Suite("Block background fills")
struct BlockBackgroundFillTests {

    /// Text view laid out in a narrow container so the sample text wraps.
    private func makeTextView(
        _ text: String,
        width: CGFloat = 160,
        fontSize: CGFloat = 16,
        extraLineSpacing: CGFloat = 2
    ) -> NativeTextView {
        let tv = NativeTextView(frame: NSRect(x: 0, y: 0, width: width, height: 400))
        var config = MarkdownEditorConfiguration.default
        config.paragraph.lineHeightExtraSpacing = extraLineSpacing
        tv.configuration = config
        let (font, style) = TextStylingService.makeBaseFontAndStyle(
            fontName: NSFont.systemFont(ofSize: fontSize).fontName,
            fontSize: fontSize,
            layoutBridge: tv.layoutBridge,
            configuration: config
        )
        tv.baseFont = font
        tv.textContainer?.size = NSSize(width: width, height: .greatestFiniteMagnitude)
        tv.textStorage?.setAttributedString(NSAttributedString(
            string: text,
            attributes: [.font: font, .paragraphStyle: style]
        ))
        return tv
    }

    /// Every fill in the document, in layout order, plus the line boxes they
    /// were painted over.
    private func fills(in tv: NativeTextView) -> [(rect: CGRect, color: NSColor)] {
        guard let tlm = tv.textLayoutManager, let tcm = tlm.textContentManager else { return [] }
        let delegate = MarkdownLayoutManagerDelegate()
        tlm.delegate = delegate
        tlm.invalidateLayout(for: tlm.documentRange)
        tlm.ensureLayout(for: tlm.documentRange)

        var result: [(rect: CGRect, color: NSColor)] = []
        tlm.enumerateTextLayoutFragments(from: tcm.documentRange.location, options: [.ensuresLayout]) { fragment in
            guard let fragment = fragment as? MarkdownTextLayoutFragment else { return true }
            // Fragment-local rects lifted into document space, the way the
            // fragment's own draw origin does it.
            let origin = fragment.layoutFragmentFrame.origin
            result += fragment.blockBackgroundFills(at: origin).map {
                (rect: $0.rect, color: $0.color)
            }
            return true
        }
        return result
    }

    private func lineHeight(of tv: NativeTextView) -> CGFloat {
        guard let tlm = tv.textLayoutManager, let tcm = tlm.textContentManager else { return 0 }
        tlm.ensureLayout(for: tlm.documentRange)
        var height: CGFloat = 0
        tlm.enumerateTextLayoutFragments(from: tcm.documentRange.location, options: [.ensuresLayout]) { fragment in
            height = fragment.textLineFragments.first?.typographicBounds.height ?? 0
            return false
        }
        return height
    }

    private static let wrapping = "one two three four five six seven eight nine ten eleven twelve"

    @Test("a wrapped run fills every line box, seamlessly")
    func wrappedRunIsOneBlock() throws {
        let tv = makeTextView(Self.wrapping)
        let full = NSRange(location: 0, length: (Self.wrapping as NSString).length)
        tv.textStorage?.addAttribute(.markdownBlockBackground, value: NSColor.systemOrange, range: full)

        let rects = fills(in: tv).map(\.rect)
        #expect(rects.count >= 3, "sample must wrap over several lines, got \(rects.count)")

        let box = lineHeight(of: tv)
        for rect in rects {
            #expect(abs(rect.height - box) < 0.01, "fill \(rect) should span the \(box)pt line box")
        }
        for (upper, lower) in zip(rects, rects.dropFirst()) {
            #expect(abs(lower.minY - upper.maxY) < 0.01, "seam between \(upper) and \(lower)")
        }
    }

    @Test("the line box is followed even with extra line spacing")
    func extraLineSpacingIsCovered() throws {
        let tight = makeTextView(Self.wrapping, extraLineSpacing: 0)
        let loose = makeTextView(Self.wrapping, extraLineSpacing: 12)
        let full = NSRange(location: 0, length: (Self.wrapping as NSString).length)
        tight.textStorage?.addAttribute(.markdownBlockBackground, value: NSColor.systemOrange, range: full)
        loose.textStorage?.addAttribute(.markdownBlockBackground, value: NSColor.systemOrange, range: full)

        let tightHeight = try #require(fills(in: tight).first?.rect.height)
        let looseHeight = try #require(fills(in: loose).first?.rect.height)
        #expect(abs((looseHeight - tightHeight) - 12) < 0.01,
                "12pt of extra line spacing must land inside the fill (\(tightHeight) -> \(looseHeight))")

        // And the loose fills still meet: the spacing is inside the boxes, not between them.
        let rects = fills(in: loose).map(\.rect)
        for (upper, lower) in zip(rects, rects.dropFirst()) {
            #expect(abs(lower.minY - upper.maxY) < 0.01, "seam between \(upper) and \(lower)")
        }
    }

    @Test("a partial run stops at its own characters")
    func partialRunIsClipped() throws {
        let text = "alpha beta"
        let tv = makeTextView(text, width: 400)
        tv.textStorage?.addAttribute(.markdownBlockBackground, value: NSColor.systemOrange,
                                     range: NSRange(location: 0, length: 5))

        let rects = fills(in: tv).map(\.rect)
        #expect(rects.count == 1)
        let fill = try #require(rects.first)
        let whole = ("alpha beta" as NSString).size(withAttributes: [.font: tv.baseFont]).width
        #expect(fill.width < whole, "fill \(fill.width) should stop before the full \(whole)pt line")
        #expect(fill.width > 0)
    }

    @Test("no attribute, no fill")
    func plainTextDoesNotFill() {
        let tv = makeTextView("plain text", width: 400)
        #expect(fills(in: tv).isEmpty)
    }
}
