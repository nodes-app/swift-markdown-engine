//
//  ThematicBreakMarkTests.swift
//  MarkdownEngineTests
//
//  `---`, `***` and `___` are one construct with one meaning, and the engine
//  drew one rule for all three. `ThematicBreakStyle` lets an embedder give a
//  marker its own look — a centred star divider on `***` while `---` stays a
//  rule — without inventing syntax or touching the source text.
//
//  Two layers are worth pinning, and neither had ANY coverage before: the
//  styler decides (marker -> configured mark -> attribute) and the fragment
//  positions (rule spans the container, mark centres in it). The attribute
//  layer especially — every reader of `.thematicBreak` type-tests it as Bool
//  off `Any`, so a wrong value type there compiles clean and silently draws
//  nothing at all.
//

import AppKit
import Foundation
import Testing
@testable import MarkdownEngine

@MainActor
@Suite("Thematic break marks")
struct ThematicBreakMarkTests {

    private let fontSize: CGFloat = 14
    private var fontName: String { NSFont.systemFont(ofSize: 14).fontName }

    /// `(location, mark)` for every styled thematic break. `mark == nil` is the
    /// default full-width rule; a non-nil mark is drawn centred instead.
    private func breaks(_ attrs: [StyledRange]) -> [(loc: Int, mark: String?)] {
        attrs.compactMap { entry -> (Int, String?)? in
            guard entry.1[.thematicBreak] as? Bool == true else { return nil }
            return (entry.0.location, entry.1[.thematicBreakMark] as? String)
        }
        .sorted { $0.0 < $1.0 }
    }

    private func style(
        _ text: String,
        caret: Int = -1,
        configuration: MarkdownEditorConfiguration = .default
    ) -> [StyledRange] {
        MarkdownASTStyler.styleAttributes(
            text: text, fontName: fontName, fontSize: fontSize,
            caretLocation: caret, configuration: configuration
        )
    }

    private func starConfiguration(
        _ mark: String = "* * *",
        scale: CGFloat = 1
    ) -> MarkdownEditorConfiguration {
        var config = MarkdownEditorConfiguration.default
        config.thematicBreak.asteriskMark = ThematicBreakStyle.Mark(mark, scale: scale)
        return config
    }

    // MARK: - Styling

    @Test("by default every marker is a rule and carries no mark")
    func defaultsAreRules() {
        for source in ["---", "***", "___"] {
            let found = breaks(style("a\n\n\(source)\n\nb"))
            #expect(found.count == 1, "\(source) should style one thematic break")
            #expect(found.first?.mark == nil, "\(source) should carry no mark by default")
        }
    }

    @Test("a configured mark applies to its own marker only")
    func markAppliesToConfiguredMarkerOnly() {
        let config = starConfiguration()
        #expect(breaks(style("a\n\n***\n\nb", configuration: config)).first?.mark == "* * *")
        #expect(breaks(style("a\n\n---\n\nb", configuration: config)).first?.mark == nil)
        #expect(breaks(style("a\n\n___\n\nb", configuration: config)).first?.mark == nil)
    }

    @Test("each marker maps to its own slot")
    func everyMarkerHasItsOwnSlot() {
        var config = MarkdownEditorConfiguration.default
        config.thematicBreak.dashMark = "dash"
        config.thematicBreak.asteriskMark = "star"
        config.thematicBreak.underscoreMark = "under"
        #expect(breaks(style("---", configuration: config)).first?.mark == "dash")
        #expect(breaks(style("***", configuration: config)).first?.mark == "star")
        #expect(breaks(style("___", configuration: config)).first?.mark == "under")
    }

    @Test("a longer run is the same break — the mark does not repeat")
    func longerRunsResolveIdentically() {
        let config = starConfiguration()
        #expect(breaks(style("*****", configuration: config)).first?.mark == "* * *")
        #expect(breaks(style("**********", configuration: config)).first?.mark == "* * *")
    }

    /// The block range keeps its leading indent — only trailing newlines are
    /// trimmed — so the marker scan has to skip whitespace to find it.
    @Test("an indented break still resolves its marker")
    func indentedBreakResolvesMarker() {
        let config = starConfiguration()
        #expect(breaks(style("  ***", configuration: config)).first?.mark == "* * *")
        #expect(breaks(style("\t***", configuration: config)).first?.mark == "* * *")
        #expect(breaks(style(" \t ***", configuration: config)).first?.mark == "* * *")
    }

    @Test("the caret still reveals the raw source, mark or no mark")
    func caretSuppressionSurvives() {
        let text = "a\n\n***\n\nb"
        // The break occupies locations 3...5.
        #expect(breaks(style(text, caret: 4, configuration: starConfiguration())).isEmpty)
        #expect(breaks(style(text, caret: 4)).isEmpty)
    }

    @Test("the trailing newline stays outside both attributes")
    func trailingNewlineIsNotDecorated() throws {
        let attrs = style("***\n\nb", configuration: starConfiguration())
        let entry = try #require(attrs.first { $0.1[.thematicBreak] as? Bool == true })
        #expect(entry.0 == NSRange(location: 0, length: 3),
                "decoration should stop before the newline, got \(entry.0)")
    }

    /// Every other custom attribute value in the engine is an ObjC-bridgeable
    /// primitive. A boxed Swift enum here would break `as? Bool` at three call
    /// sites with no compiler diagnostic, so the types are pinned deliberately.
    @Test("attribute values stay ObjC-bridgeable")
    func attributeValuesAreBridgeable() throws {
        let attrs = style("***", configuration: starConfiguration())
        let entry = try #require(attrs.first { $0.1[.thematicBreak] != nil })
        #expect(entry.1[.thematicBreak] is Bool)
        #expect(entry.1[.thematicBreakMark] is String)
    }

    // MARK: - Geometry

    /// A laid-out editor whose storage carries the styler's own attributes.
    private func makeTextView(
        _ text: String,
        configuration: MarkdownEditorConfiguration,
        width: CGFloat = 320
    ) -> NativeTextView {
        _ = NSApplication.shared
        let tv = NativeTextView(frame: NSRect(x: 0, y: 0, width: width, height: 400))
        tv.configuration = configuration
        let (font, style) = TextStylingService.makeBaseFontAndStyle(
            fontName: fontName,
            fontSize: fontSize,
            layoutBridge: tv.layoutBridge,
            configuration: configuration
        )
        tv.baseFont = font
        tv.textContainer?.size = NSSize(width: width, height: .greatestFiniteMagnitude)
        let storage = NSMutableAttributedString(
            string: text,
            attributes: [.font: font, .paragraphStyle: style]
        )
        for (range, attributes) in MarkdownASTStyler.styleAttributes(
            text: text, fontName: fontName, fontSize: fontSize,
            caretLocation: -1, configuration: configuration
        ) {
            storage.addAttributes(attributes, range: range)
        }
        tv.textStorage?.setAttributedString(storage)
        return tv
    }

    private func decorations(in tv: NativeTextView) -> [MarkdownTextLayoutFragment.ThematicBreakDecoration] {
        guard let tlm = tv.textLayoutManager, let tcm = tlm.textContentManager else { return [] }
        let delegate = MarkdownLayoutManagerDelegate()
        tlm.delegate = delegate
        tlm.invalidateLayout(for: tlm.documentRange)
        tlm.ensureLayout(for: tlm.documentRange)

        var out: [MarkdownTextLayoutFragment.ThematicBreakDecoration] = []
        tlm.enumerateTextLayoutFragments(from: tcm.documentRange.location, options: [.ensuresLayout]) { fragment in
            guard let fragment = fragment as? MarkdownTextLayoutFragment else { return true }
            out += fragment.thematicBreakDecorations(at: fragment.layoutFragmentFrame.origin)
            return true
        }
        return out
    }

    @Test("the default rule spans the whole container, 1pt tall")
    func ruleSpansContainer() throws {
        let width: CGFloat = 320
        let tv = makeTextView("a\n\n---\n\nb", configuration: .default, width: width)
        let found = decorations(in: tv)
        #expect(found.count == 1)
        let rule = try #require(found.first)
        #expect(rule.mark == nil)
        #expect(abs(rule.rect.width - width) < 0.01, "rule should span \(width), got \(rule.rect.width)")
        #expect(abs(rule.rect.height - 1) < 0.01)
        #expect(abs(rule.rect.minX) < 0.01, "rule should start at the container edge")
    }

    @Test("a mark is narrower than the container and centred in it")
    func markIsCentredInContainer() throws {
        let width: CGFloat = 320
        let tv = makeTextView("a\n\n***\n\nb", configuration: starConfiguration(), width: width)
        let found = decorations(in: tv)
        #expect(found.count == 1)
        let decoration = try #require(found.first)
        #expect(decoration.mark == "* * *")
        #expect(decoration.rect.width > 0)
        #expect(decoration.rect.width < width, "mark should not span the container")
        let leading = decoration.rect.minX
        let trailing = width - decoration.rect.maxX
        #expect(abs(leading - trailing) < 0.01,
                "mark should be centred: \(leading)pt leading vs \(trailing)pt trailing")
    }

    @Test("the mark sits inside its line box, so it cannot be clipped")
    func markFitsTheLineBox() throws {
        let tv = makeTextView("a\n\n***\n\nb", configuration: starConfiguration())
        let decoration = try #require(decorations(in: tv).first)
        let rule = try #require(decorations(in: makeTextView("a\n\n---\n\nb", configuration: .default)).first)
        // Both breaks occupy the same line box; the rule's band is centred in
        // it, so the mark's box must straddle that same centre line.
        let ruleCentre = rule.rect.midY
        #expect(abs(decoration.rect.midY - ruleCentre) < 0.51,
                "mark centre \(decoration.rect.midY) should match the rule's \(ruleCentre)")
    }

    @Test("no thematic break, no decoration")
    func plainTextIsNotDecorated() {
        let tv = makeTextView("just a paragraph", configuration: starConfiguration())
        #expect(decorations(in: tv).isEmpty)
    }

    // MARK: - Size

    @Test("a string literal is still a mark, at body size")
    func stringLiteralIsScaleOne() {
        var config = MarkdownEditorConfiguration.default
        config.thematicBreak.asteriskMark = "* * *"
        #expect(config.thematicBreak.asteriskMark?.text == "* * *")
        #expect(config.thematicBreak.asteriskMark?.scale == 1)
    }

    @Test("a scaled mark draws bigger")
    func scaledMarkIsBigger() throws {
        let small = try #require(decorations(in: makeTextView(
            "***", configuration: starConfiguration(scale: 1))).first)
        let large = try #require(decorations(in: makeTextView(
            "***", configuration: starConfiguration(scale: 2))).first)
        #expect(large.font.pointSize > small.font.pointSize)
        #expect(large.rect.height > small.rect.height,
                "scale 2 ink \(large.rect.height) should exceed scale 1 ink \(small.rect.height)")
    }

    /// The whole reason marks are ink-centred: `*` is drawn high in its em, so
    /// box-centring would let the mark climb toward the top of the line as it
    /// grew. The drawn ink must stay centred on the line at every scale.
    @Test("a mark stays optically centred as it grows")
    func markStaysCentredAtEveryScale() throws {
        for scale in [1.0, 1.5, 2.0, 3.0] as [CGFloat] {
            let tv = makeTextView("a\n\n***\n\nb", configuration: starConfiguration(scale: scale))
            let decoration = try #require(decorations(in: tv).first)
            let rule = try #require(decorations(in: makeTextView(
                "a\n\n---\n\nb", configuration: .default)).first)
            _ = rule
            // Compare against the line box the mark actually occupies.
            let lineCentre = lineCentreOfBreak(in: tv)
            #expect(abs(decoration.rect.midY - lineCentre) < 0.51,
                    "scale \(scale): ink centre \(decoration.rect.midY) vs line centre \(lineCentre)")
        }
    }

    @Test("a scaled mark grows its line instead of overlapping neighbours")
    func scaledMarkGrowsTheLine() throws {
        let plain = lineHeightOfBreak(in: makeTextView("a\n\n***\n\nb", configuration: starConfiguration(scale: 1)))
        let big = lineHeightOfBreak(in: makeTextView("a\n\n***\n\nb", configuration: starConfiguration(scale: 3)))
        #expect(big > plain * 2, "line should grow with the mark (\(plain) -> \(big))")
    }

    /// Line box of the thematic-break line, in the same space the decorations use.
    private func breakLineBounds(in tv: NativeTextView) -> CGRect {
        guard let tlm = tv.textLayoutManager, let tcm = tlm.textContentManager else { return .zero }
        let delegate = MarkdownLayoutManagerDelegate()
        tlm.delegate = delegate
        tlm.invalidateLayout(for: tlm.documentRange)
        tlm.ensureLayout(for: tlm.documentRange)

        var out = CGRect.zero
        tlm.enumerateTextLayoutFragments(from: tcm.documentRange.location, options: [.ensuresLayout]) { fragment in
            guard let md = fragment as? MarkdownTextLayoutFragment,
                  !md.thematicBreakDecorations(at: md.layoutFragmentFrame.origin).isEmpty,
                  let lineFragment = md.textLineFragments.first else { return true }
            let origin = md.layoutFragmentFrame.origin
            let tb = lineFragment.typographicBounds
            out = CGRect(x: origin.x, y: origin.y + tb.origin.y, width: tb.width, height: tb.height)
            return false
        }
        return out
    }

    private func lineCentreOfBreak(in tv: NativeTextView) -> CGFloat {
        breakLineBounds(in: tv).midY
    }

    private func lineHeightOfBreak(in tv: NativeTextView) -> CGFloat {
        breakLineBounds(in: tv).height
    }
}
