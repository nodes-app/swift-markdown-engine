//
//  DirectiveGlyphTests.swift
//  MarkdownEngineTests
//
//  Phase 3 — a self-contained directive draws a glyph in place of its
//  collapsed source, on the same mechanism inline LaTeX uses: the characters
//  stay in the text, the first one carries the image and enough kern to occupy
//  its width, and the rest collapse to nothing.
//
//  The failure mode worth guarding is a glyph that can't be produced: the
//  source must stay VISIBLE rather than collapsing to an empty gap the user
//  can't see, select, or fix.
//

import AppKit
import Foundation
import Testing
@testable import MarkdownEngine

@Suite("Directives — self-contained glyphs")
@MainActor
struct DirectiveGlyphTests {

    private let base: CGFloat = 14
    private var fontName: String { NSFont.systemFont(ofSize: 14).fontName }
    private var hiddenSize: CGFloat { MarkdownEditorConfiguration.default.markers.hiddenMarkerFontSize }

    /// A directive whose symbol name the system cannot resolve.
    private struct BrokenSymbolDirective: MarkdownDirective {
        var syntax: DirectiveSyntax { DirectiveSyntax(name: "broken", form: .selfContained) }
        func presentation(arguments: DirectiveArguments, context: DirectiveContext) -> DirectivePresentation {
            .symbol(name: "definitely.not.a.real.sf.symbol", tint: nil)
        }
    }

    /// A directive that declines to draw anything.
    private struct PlainDirective: MarkdownDirective {
        var syntax: DirectiveSyntax { DirectiveSyntax(name: "plain", form: .selfContained) }
    }

    private struct TextDirective: MarkdownDirective {
        var text = "ABC"
        var syntax: DirectiveSyntax { DirectiveSyntax(name: "text", form: .selfContained) }
        func presentation(arguments: DirectiveArguments, context: DirectiveContext) -> DirectivePresentation {
            .text(text)
        }
    }

    /// A directive supplying its own image, sized from an argument.
    private struct SwatchDirective: MarkdownDirective {
        var syntax: DirectiveSyntax {
            DirectiveSyntax(name: "swatch", form: .selfContained,
                            parameters: [.init(label: "size", kind: .number)])
        }
        func presentation(arguments: DirectiveArguments, context: DirectiveContext) -> DirectivePresentation {
            let side = arguments.number("size").map { CGFloat($0) } ?? 10
            return .image(NSImage(size: CGSize(width: side, height: side)), baselineOffset: 0)
        }
    }

    private var configuration: MarkdownEditorConfiguration {
        MarkdownEditorConfiguration(directives: [
            MarkerDirective(), BrokenSymbolDirective(), PlainDirective(), SwatchDirective(),
        ])
    }

    private func style(_ text: String, caret: Int = -1) -> [StyledRange] {
        MarkdownASTStyler.styleAttributes(
            text: text, fontName: fontName, fontSize: base,
            caretLocation: caret, configuration: configuration
        )
    }

    /// Attributes covering the first character of `needle`.
    private func firstCharAttributes(_ text: String, _ needle: String, caret: Int = -1)
        -> [NSAttributedString.Key: Any] {
        let position = (text as NSString).range(of: needle).location
        var merged: [NSAttributedString.Key: Any] = [:]
        for (range, attributes) in style(text, caret: caret)
        where NSLocationInRange(position, range) {
            merged.merge(attributes) { _, new in new }
        }
        return merged
    }

    // MARK: - Drawing

    @Test("the glyph rides on the call's first character")
    func glyphOnFirstCharacter() {
        let attributes = firstCharAttributes("a @marker b", "@marker")
        #expect(attributes[.latexImage] is NSImage)
        #expect(attributes[.latexBounds] is NSValue)
    }

    @Test("the glyph is sized to the inherited font")
    func glyphSizedToFont() {
        let small = firstCharAttributes("@marker", "@marker")[.latexImage] as? NSImage
        let attrs = MarkdownASTStyler.styleAttributes(
            text: "# @marker", fontName: fontName, fontSize: base,
            caretLocation: -1, configuration: configuration
        )
        let position = ("# @marker" as NSString).range(of: "@marker").location
        var large: NSImage?
        for (range, a) in attrs where NSLocationInRange(position, range) {
            if let image = a[.latexImage] as? NSImage { large = image }
        }
        // A heading's larger font must yield a larger glyph.
        #expect(small != nil && large != nil)
        #expect((large?.size.height ?? 0) > (small?.size.height ?? 0))
    }

    @Test("the first character carries kern for the glyph's width")
    func firstCharacterReservesWidth() {
        let attributes = firstCharAttributes("@marker", "@marker")
        let image = attributes[.latexImage] as? NSImage
        let kern = attributes[.kern] as? CGFloat ?? 0
        // Kern must account for most of the image width (minus the shrunk
        // character's own negligible advance).
        #expect(kern > 0)
        #expect(kern <= (image?.size.width ?? 0))
    }

    @Test("the remaining characters collapse")
    func remainderCollapses() {
        let text = "@marker"
        let tail = (text as NSString).range(of: "marker")
        var sawCollapse = false
        for (range, attributes) in style(text) where NSIntersectionRange(range, tail).length > 0 {
            if (attributes[.font] as? NSFont)?.pointSize == hiddenSize,
               (attributes[.kern] as? CGFloat ?? 0) < 0 {
                sawCollapse = true
            }
        }
        #expect(sawCollapse)
    }

    @Test("a directive-supplied image is used as given")
    func suppliedImageIsUsed() {
        let attributes = firstCharAttributes("@swatch(size: 24)", "@swatch")
        #expect((attributes[.latexImage] as? NSImage)?.size.width == 24)
    }

    @Test("arguments reach a self-contained presentation")
    func argumentsReachPresentation() {
        #expect((firstCharAttributes("@swatch(size: 8)", "@swatch")[.latexImage] as? NSImage)?.size.width == 8)
        #expect((firstCharAttributes("@swatch(size: 32)", "@swatch")[.latexImage] as? NSImage)?.size.width == 32)
    }

    // MARK: - Caret reveal

    @Test("the caret inside reveals the source and drops the glyph")
    func caretRevealsSource() {
        let attributes = firstCharAttributes("@marker", "@marker", caret: 3)
        #expect(attributes[.latexImage] == nil)
        #expect((attributes[.font] as? NSFont)?.pointSize != hiddenSize)
    }

    // MARK: - Degradation

    @Test("an unresolvable symbol leaves the source visible, not an empty gap")
    func brokenSymbolStaysVisible() {
        // The important failure mode: collapsing source we can't replace would
        // leave a blank the user can neither see nor fix.
        let attributes = firstCharAttributes("@broken", "@broken")
        #expect(attributes[.latexImage] == nil)
        #expect((attributes[.font] as? NSFont)?.pointSize != hiddenSize)
    }

    @Test("a directive declining to draw leaves its source visible")
    func literalPresentationStaysVisible() {
        let attributes = firstCharAttributes("@plain", "@plain")
        #expect(attributes[.latexImage] == nil)
        #expect((attributes[.font] as? NSFont)?.pointSize != hiddenSize)
    }

    @Test("spell-check is suppressed over a directive call")
    func spellCheckSuppressed() {
        #expect(firstCharAttributes("@marker", "@marker")[.spellingState] as? Int == 0)
    }

    // MARK: - Isolation

    @Test("a glyph does not disturb the surrounding text")
    func neighboursUnaffected() {
        let text = "before @marker after"
        let position = (text as NSString).range(of: "after").location
        for (range, attributes) in style(text) where NSLocationInRange(position, range) {
            #expect(attributes[.latexImage] == nil)
            #expect((attributes[.font] as? NSFont)?.pointSize != hiddenSize)
        }
    }

    // MARK: - GlyphDirective

    @Test("an icon draws the symbol named in its positional argument")
    func iconDrawsNamedSymbol() {
        let configuration = MarkdownEditorConfiguration(directives: [GlyphDirective()])
        func image(_ text: String) -> NSImage? {
            let position = (text as NSString).range(of: "@glyph").location
            var found: NSImage?
            for (range, attributes) in MarkdownASTStyler.styleAttributes(
                text: text, fontName: fontName, fontSize: base,
                caretLocation: -1, configuration: configuration
            ) where NSLocationInRange(position, range) {
                if let candidate = attributes[.latexImage] as? NSImage { found = candidate }
            }
            return found
        }
        #expect(image("@glyph(star.fill)") != nil)
        #expect(image("@glyph(checkmark.circle.fill, color: green)") != nil)
        // A dotted symbol name survives argument splitting.
        #expect(image("@glyph(arrow.down.to.line)") != nil)
        // An unknown symbol leaves the source visible.
        #expect(image("@glyph(not.a.symbol.at.all)") == nil)
    }

    // MARK: - Text presentation

    private func glyph(_ source: String, bodyColor: NSColor = .labelColor) throws -> NSImage {
        let configuration = MarkdownEditorConfiguration(
            theme: MarkdownEditorTheme(bodyText: bodyColor),
            directives: [TextDirective(), GlyphDirective(), RegionDirective()]
        )
        let attributes = MarkdownASTStyler.styleAttributes(
            text: source, fontName: fontName, fontSize: base,
            caretLocation: -1, configuration: configuration
        )
        return try #require(attributes.compactMap { $0.attributes[.latexImage] as? NSImage }.last)
    }

    /// Draw through the layout fragment's plain image path, excluding antialiased edges.
    private func opaquePixels(_ image: NSImage, appearance: NSAppearance) throws -> [NSColor] {
        let scale: CGFloat = 4
        let bitmap = try #require(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(ceil(image.size.width * scale)),
            pixelsHigh: Int(ceil(image.size.height * scale)), bitsPerSample: 8,
            samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ))
        bitmap.size = image.size
        let context = try #require(NSGraphicsContext(bitmapImageRep: bitmap))
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current = context
        appearance.performAsCurrentDrawingAppearance {
            NSColor.clear.setFill()
            NSRect(origin: .zero, size: image.size).fill(using: .copy)
            image.draw(in: NSRect(origin: .zero, size: image.size))
        }
        var pixels: [NSColor] = []
        for y in 0..<bitmap.pixelsHigh {
            for x in 0..<bitmap.pixelsWide {
                if let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB),
                   color.alphaComponent > 0 {
                    pixels.append(color)
                }
            }
        }
        // System label colors are translucent even in fully covered pixels.
        let maximumAlpha = pixels.map(\.alphaComponent).max() ?? 0
        let ink = pixels.filter { $0.alphaComponent >= maximumAlpha * 0.95 }
        #expect(ink.count >= 5)
        return ink
    }

    @Test("text and untinted symbols follow the drawing appearance across cache hits")
    func glyphsFollowAppearance() throws {
        let aqua = try #require(NSAppearance(named: .aqua))
        let dark = try #require(NSAppearance(named: .darkAqua))
        for source in ["@text", "@glyph(star.fill)"] {
            let image = try glyph(source)
            for appearance in [aqua, dark, aqua] {
                var cached: NSImage?
                appearance.performAsCurrentDrawingAppearance {
                    cached = try? glyph(source)
                }
                for candidate in [image, try #require(cached)] {
                    let pixels = try opaquePixels(candidate, appearance: appearance)
                    let brightness = pixels.reduce(0) {
                        $0 + ($1.redComponent + $1.greenComponent + $1.blueComponent) / 3
                    } / CGFloat(max(pixels.count, 1))
                    if appearance.name == .darkAqua {
                        #expect(brightness > 0.7)
                    } else {
                        #expect(brightness < 0.3)
                    }
                }
            }
        }
    }

    @Test("glyph caches preserve body colors and explicit symbol tints")
    func glyphColorsStayIsolated() throws {
        let colors = [NSColor(srgbRed: 0.8, green: 0.1, blue: 0.2, alpha: 1),
                      NSColor(srgbRed: 0.1, green: 0.2, blue: 0.8, alpha: 1)]
        for appearanceName in [NSAppearance.Name.aqua, .darkAqua] {
            let appearance = try #require(NSAppearance(named: appearanceName))
            for bodyColor in colors + colors {
                for source in ["@text", "@glyph(star.fill)", "@glyph(star.fill, color: green)"] {
                    let image = try glyph(source, bodyColor: bodyColor)
                    var expected: NSColor?
                    appearance.performAsCurrentDrawingAppearance {
                        expected = (source.contains("color:") ? NSColor.systemGreen : bodyColor)
                            .usingColorSpace(.sRGB)
                    }
                    let resolved = try #require(expected)
                    let pixels = try opaquePixels(image, appearance: appearance)
                    #expect(pixels.allSatisfy {
                        abs($0.redComponent - resolved.redComponent) < 0.08 &&
                        abs($0.greenComponent - resolved.greenComponent) < 0.08 &&
                        abs($0.blueComponent - resolved.blueComponent) < 0.08
                    })
                }
            }
        }
    }

    @Test("color emoji keep their intrinsic colors across appearances")
    func emojiColorsSurvive() throws {
        let image = try glyph("@region(JP)")
        for name in [NSAppearance.Name.aqua, .darkAqua, .aqua] {
            let pixels = try opaquePixels(image, appearance: #require(NSAppearance(named: name)))
            #expect(pixels.contains { $0.redComponent > 0.7 && $0.greenComponent < 0.4 })
            #expect(pixels.contains { $0.redComponent > 0.8 && $0.greenComponent > 0.8 && $0.blueComponent > 0.8 })
        }
    }

    @Test("an empty text presentation leaves its source visible")
    func emptyTextStaysVisible() {
        let configuration = MarkdownEditorConfiguration(directives: [TextDirective(text: "")])
        for (range, attributes) in MarkdownASTStyler.styleAttributes(
            text: "@text", fontName: fontName, fontSize: base,
            caretLocation: -1, configuration: configuration
        ) where NSLocationInRange(0, range) {
            #expect(attributes[.latexImage] == nil)
            #expect((attributes[.font] as? NSFont)?.pointSize != hiddenSize)
        }
    }

    @Test("a text presentation renders as a glyph, not a storage substitution")
    func textPresentationRenders() {
        let configuration = MarkdownEditorConfiguration(directives: [RegionDirective()])
        let text = "@region(JP)"
        var image: NSImage?
        for (range, attributes) in MarkdownASTStyler.styleAttributes(
            text: text, fontName: fontName, fontSize: base,
            caretLocation: -1, configuration: configuration
        ) where NSLocationInRange(0, range) {
            if let candidate = attributes[.latexImage] as? NSImage { image = candidate }
        }
        #expect(image != nil)
        // The source characters are still all there.
        #expect((text as NSString).length == 11)
    }

    @Test("an unresolvable argument leaves the source visible")
    func badFlagCodeStaysVisible() {
        let configuration = MarkdownEditorConfiguration(directives: [RegionDirective()])
        for (range, attributes) in MarkdownASTStyler.styleAttributes(
            text: "@region(ZZZZ)", fontName: fontName, fontSize: base,
            caretLocation: -1, configuration: configuration
        ) where NSLocationInRange(0, range) {
            #expect(attributes[.latexImage] == nil)
        }
    }


    @Test("scoped styling matches the full pass for a glyph-bearing paragraph")
    func scopedMatchesFull() {
        let text = "intro\n\nbefore @marker after\n\noutro"
        let ns = text as NSString
        let paragraph = ns.paragraphRange(for: ns.range(of: "@marker"))
        func digest(_ scoped: [NSRange]?) -> String {
            MarkdownASTStyler.styleAttributes(
                text: text, fontName: fontName, fontSize: base,
                scopedRanges: scoped, configuration: configuration
            )
            .filter { NSIntersectionRange($0.range, paragraph).length > 0 }
            .map { "\($0.range.location):\($0.range.length)[\($0.attributes.keys.map(\.rawValue).sorted().joined(separator: ","))]" }
            .sorted()
            .joined(separator: "\n")
        }
        #expect(digest([paragraph]) == digest(nil))
    }
}
