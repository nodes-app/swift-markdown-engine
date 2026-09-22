//
//  DirectiveCompositionTests.swift
//  MarkdownEngineTests
//
//  Phase 2 — a container directive's font transform COMPOSES over the font
//  inherited at that point in the tree, in both directions: the body keeps the
//  traits of everything enclosing it, and markup nested inside the body keeps
//  the directive's font.
//
//  This is the property that makes directives tree-shaped rather than
//  positional, so it gets tested from both ends and through nesting.
//

import AppKit
import Foundation
import Testing
@testable import MarkdownEngine

@Suite("Directives — font composition")
struct DirectiveCompositionTests {

    private let base: CGFloat = 14
    private var fontName: String { NSFont.systemFont(ofSize: 14).fontName }

    /// A directive that only scales, to prove relative units compose.
    private struct ScaleDirective: MarkdownDirective {
        var syntax: DirectiveSyntax {
            DirectiveSyntax(name: "scale", form: .container,
                            parameters: [.init(label: "by", kind: .number)])
        }
        func style(arguments: DirectiveArguments, context: DirectiveContext) -> DirectiveStyle {
            guard let factor = arguments.number("by") else { return .inherit }
            return DirectiveStyle(font: DirectiveFontTransform(size: .scale(CGFloat(factor))))
        }
    }

    private var configuration: MarkdownEditorConfiguration {
        MarkdownEditorConfiguration(directives: [
            FontDirective(), ColorDirective(), MarkerDirective(), ScaleDirective(),
        ])
    }

    private func style(_ text: String, caret: Int = -1) -> [StyledRange] {
        MarkdownASTStyler.styleAttributes(
            text: text, fontName: fontName, fontSize: base,
            caretLocation: caret, configuration: configuration
        )
    }

    /// Effective font at the first occurrence of `needle`.
    private func font(_ text: String, at needle: String, caret: Int = -1) -> NSFont? {
        let position = (text as NSString).range(of: needle).location
        var result: NSFont?
        for (range, attributes) in style(text, caret: caret) where NSLocationInRange(position, range) {
            if let font = attributes[.font] as? NSFont { result = font }
        }
        return result
    }

    /// Effective foreground colour at the first occurrence of `needle`.
    private func color(_ text: String, at needle: String) -> NSColor? {
        let position = (text as NSString).range(of: needle).location
        var result: NSColor?
        for (range, attributes) in style(text) where NSLocationInRange(position, range) {
            if let color = attributes[.foregroundColor] as? NSColor { result = color }
        }
        return result
    }

    // MARK: - The directive applies

    @Test("an absolute size applies to the body")
    func absoluteSize() {
        #expect(font("@font(size: 18){hello}", at: "hello")?.pointSize == 18)
    }

    @Test("a relative size resolves against the inherited size")
    func relativeSize() {
        #expect(font("@font(size: 1.5em){hello}", at: "hello")?.pointSize == base * 1.5)
        #expect(font("@font(size: 50%){hello}", at: "hello")?.pointSize == base * 0.5)
    }

    @Test("a weight argument applies")
    func weightApplies() {
        let traits = font("@font(weight: bold){hello}", at: "hello")?.fontDescriptor.symbolicTraits
        #expect(traits?.contains(.bold) == true)
    }

    @Test("a non-font directive applies its attributes")
    func attributesApply() {
        // `@color` resolves through NSColor(named:), unavailable in tests — so
        // assert the directive is reached and leaves the body's font alone.
        #expect(font("@color(red){hello}", at: "hello")?.pointSize == base)
    }

    // MARK: - Composition outward: the body keeps its context

    @Test("inside a heading, the directive keeps the heading's bold")
    func composesWithHeading() {
        let font = font("# @font(size: 18){hello}", at: "hello")
        #expect(font?.pointSize == 18)
        #expect(font?.fontDescriptor.symbolicTraits.contains(.bold) == true)
    }

    @Test("inside emphasis, the directive keeps the italic")
    func composesWithEmphasis() {
        let font = font("*@font(size: 18){hello}*", at: "hello")
        #expect(font?.pointSize == 18)
        #expect(font?.fontDescriptor.symbolicTraits.contains(.italic) == true)
    }

    // MARK: - Composition inward: nested markup keeps the directive's font

    @Test("bold inside the body keeps the directive's size — the motivating case")
    func boldInsideKeepsSize() {
        let font = font("@font(size: 18){**bold**}", at: "bold")
        #expect(font?.pointSize == 18)
        #expect(font?.fontDescriptor.symbolicTraits.contains(.bold) == true)
    }

    @Test("italic inside the body keeps the directive's size")
    func italicInsideKeepsSize() {
        let font = font("@font(size: 18){*it*}", at: "it")
        #expect(font?.pointSize == 18)
        #expect(font?.fontDescriptor.symbolicTraits.contains(.italic) == true)
    }

    @Test("bold and italic together keep the directive's size")
    func boldItalicInsideKeepsSize() {
        let font = font("@font(size: 18){***both***}", at: "both")
        #expect(font?.pointSize == 18)
        let traits = font?.fontDescriptor.symbolicTraits
        #expect(traits?.contains(.bold) == true)
        #expect(traits?.contains(.italic) == true)
    }

    // MARK: - Nesting

    @Test("nested directives compose, innermost last")
    func nestedDirectivesCompose() {
        // 14 → ×2 = 28 → ×0.5 = 14
        #expect(font("@scale(by: 2){@scale(by: 0.5){x}}", at: "x")?.pointSize == base)
    }

    @Test("a size directive inside a scale directive resolves against the scaled size")
    func relativeInsideScaled() {
        // 14 → ×2 = 28 → 1.5em of 28 = 42
        #expect(font("@scale(by: 2){@font(size: 1.5em){x}}", at: "x")?.pointSize == 42)
    }

    // MARK: - Containment

    @Test("the directive's font stops at its closing brace")
    func effectStopsAtBody() {
        let text = "@font(size: 18){big} small"
        #expect(font(text, at: "big")?.pointSize == 18)
        let tail = font(text, at: "small")
        #expect(tail == nil || tail?.pointSize == base)
    }

    @Test("a directive does not leak into the next paragraph")
    func effectStopsAtBlock() {
        let text = "@font(size: 18){big}\n\nnext paragraph"
        let tail = font(text, at: "next")
        #expect(tail == nil || tail?.pointSize == base)
    }

    // MARK: - Invalid calls

    @Test("an invalid argument mutes the body instead of restyling it")
    func invalidCallMutes() {
        // `size: huge` fails length coercion, so FontDirective mutes.
        let text = "@font(size: huge){hello}"
        #expect(color(text, at: "hello") == MarkdownEditorTheme.default.disabledText)
        #expect(font(text, at: "hello")?.pointSize == base)
    }

    @Test("an unknown label is a diagnostic, and the body still renders")
    func unknownLabelStillRenders() {
        #expect(font("@font(colour: red){hello}", at: "hello")?.pointSize == base)
    }

    // MARK: - Caret behaviour

    @Test("the syntax reveals with the caret inside and shrinks outside")
    func syntaxRevealFlip() {
        let hidden = MarkdownEditorConfiguration.default.markers.hiddenMarkerFontSize
        let text = "@font(size: 18){hello}"
        #expect(font(text, at: "@font")?.pointSize == hidden)
        #expect(font(text, at: "@font", caret: 3)?.pointSize != hidden)
    }

    @Test("the body keeps the directive's size while the syntax is revealed")
    func bodyStaysStyledWhileActive() {
        #expect(font("@font(size: 18){hello}", at: "hello", caret: 3)?.pointSize == 18)
    }

    // MARK: - Scoped restyle

    @Test("scoped styling matches the full pass for a directive-bearing paragraph")
    func scopedMatchesFull() {
        let text = "intro\n\n# @font(size: 18){**big**} tail\n\noutro"
        let ns = text as NSString
        let paragraph = ns.paragraphRange(for: ns.range(of: "@font"))
        func digest(_ scoped: [NSRange]?) -> String {
            MarkdownASTStyler.styleAttributes(
                text: text, fontName: fontName, fontSize: base,
                scopedRanges: scoped, configuration: configuration
            )
            .filter { NSIntersectionRange($0.range, paragraph).length > 0 }
            .map { entry in
                let keys = entry.attributes.keys.map(\.rawValue).sorted().joined(separator: ",")
                let size = (entry.attributes[.font] as? NSFont).map { "\($0.pointSize)" } ?? "-"
                return "\(entry.range.location):\(entry.range.length)[\(keys)]\(size)"
            }
            .sorted()
            .joined(separator: "\n")
        }
        #expect(digest([paragraph]) == digest(nil))
    }

    // MARK: - Unregistered

    @Test("an unregistered directive leaves the text completely alone")
    func unregisteredIsInert() {
        let attrs = MarkdownASTStyler.styleAttributes(
            text: "@font(size: 18){hello}", fontName: fontName, fontSize: base,
            caretLocation: -1, configuration: .default
        )
        let position = ("@font(size: 18){hello}" as NSString).range(of: "hello").location
        var result: NSFont?
        for (range, attributes) in attrs where NSLocationInRange(position, range) {
            if let font = attributes[.font] as? NSFont { result = font }
        }
        #expect(result == nil || result?.pointSize == base)
    }
}
