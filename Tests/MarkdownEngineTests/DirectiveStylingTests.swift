//
//  DirectiveStylingTests.swift
//  MarkdownEngineTests
//
//  STRUCTURAL styling behaviour for directives — what must hold regardless of
//  what any given directive does with its body:
//
//    * a container's syntax shrinks when the caret leaves and reveals when it
//      enters, and the shrink never bleeds into the body;
//    * a self-contained call collapses its source behind a glyph and reveals
//      it again under the caret, without the characters ever being removed;
//    * an unknown or unregistered directive id can't crash or restyle a
//      neighbour;
//    * a scoped restyle matches the full pass.
//
//  Font semantics — sizes, traits, composition — belong to
//  `DirectiveCompositionTests`.
//

import AppKit
import Foundation
import Testing
@testable import MarkdownEngine

@Suite("Directives — structural styling")
struct DirectiveStylingTests {

    private let base: CGFloat = 14
    private var fontName: String { NSFont.systemFont(ofSize: 14).fontName }

    private var configuration: MarkdownEditorConfiguration {
        MarkdownEditorConfiguration(directives: [FontDirective(), MarkerDirective()])
    }

    private func style(_ text: String, caret: Int = -1) -> [StyledRange] {
        MarkdownASTStyler.styleAttributes(
            text: text, fontName: fontName, fontSize: base,
            caretLocation: caret, configuration: configuration
        )
    }

    /// Effective font at `pos`: the last styled range covering it that sets `.font`.
    private func font(in attrs: [StyledRange], at pos: Int) -> NSFont? {
        var result: NSFont?
        for (range, a) in attrs where NSLocationInRange(pos, range) {
            if let f = a[.font] as? NSFont { result = f }
        }
        return result
    }

    private var hiddenSize: CGFloat { MarkdownEditorConfiguration.default.markers.hiddenMarkerFontSize }

    /// Canonical, order-independent digest of styled ranges, so two style runs
    /// can be compared. Local twin of the one in `MarkdownASTStylerTests`
    /// (that one is file-private).
    private func digest(_ ranges: [StyledRange]) -> String {
        ranges
            .map { entry in
                let keys = entry.attributes.keys.map(\.rawValue).sorted().joined(separator: ",")
                return "\(entry.range.location):\(entry.range.length)[\(keys)]"
            }
            .sorted()
            .joined(separator: "\n")
    }

    // MARK: - Container

    @Test("a container's syntax shrinks when the caret is elsewhere")
    func syntaxShrinksWhenInactive() {
        let attrs = style("@font(size: 18){hello} tail")
        // Inside the `@font(size: 18){` prefix.
        #expect(font(in: attrs, at: 2)?.pointSize == hiddenSize)
    }

    @Test("the body never picks up the shrunk marker font")
    func bodyIsNotShrunk() {
        // The body's SIZE is the directive's business (see
        // `DirectiveCompositionTests`); what must hold structurally is that the
        // shrink applied to the syntax never bleeds into the body.
        let text = "@font(size: 18){hello} tail"
        let attrs = style(text)
        let bodyStart = (text as NSString).range(of: "hello").location
        #expect(font(in: attrs, at: bodyStart)?.pointSize != hiddenSize)
    }

    @Test("the caret inside the call reveals its syntax")
    func syntaxRevealsWhenActive() {
        let attrs = style("@font(size: 18){hello}", caret: 3)
        #expect(font(in: attrs, at: 2)?.pointSize != hiddenSize)
    }

    @Test("markup inside the body still styles")
    func bodyMarkupStillStyles() {
        let text = "@font(size: 18){**bold**}"
        let attrs = style(text)
        let boldStart = (text as NSString).range(of: "bold").location
        let traits = font(in: attrs, at: boldStart)?.fontDescriptor.symbolicTraits
        #expect(traits?.contains(.bold) == true)
    }

    // MARK: - Self-contained

    @Test("a self-contained call collapses its source and reveals it under the caret")
    func selfContainedFlips() {
        let text = "before @marker after"
        let location = (text as NSString).range(of: "@marker").location
        func fonts(caret: Int) -> [CGFloat] {
            style(text, caret: caret)
                .filter { NSIntersectionRange($0.range, NSRange(location: location, length: 7)).length > 0 }
                .compactMap { ($0.attributes[.font] as? NSFont)?.pointSize }
        }
        #expect(fonts(caret: -1).contains(hiddenSize))              // collapsed
        #expect(!fonts(caret: location + 2).contains(hiddenSize))   // revealed
    }

    @Test("the collapsed source is never removed from the text")
    func collapsedSourceSurvives() {
        // The whole point of collapsing rather than deleting: selection, find,
        // copy, and undo still see the real characters.
        let text = "before @marker after"
        let covered = style(text)
            .filter { NSIntersectionRange($0.range, (text as NSString).range(of: "@marker")).length > 0 }
        #expect(!covered.isEmpty)
        #expect((text as NSString).range(of: "@marker").length == 7)
    }

    // MARK: - Isolation

    @Test("text after a directive is unaffected")
    func neighbourUnaffected() {
        let text = "@font(size: 18){hello} plain tail"
        let attrs = style(text)
        let tail = (text as NSString).range(of: "plain tail").location
        let tailFont = font(in: attrs, at: tail)
        #expect(tailFont == nil || tailFont?.pointSize == base)
    }

    @Test("an unregistered directive styles as ordinary text")
    func unregisteredIsPlain() {
        let attrs = MarkdownASTStyler.styleAttributes(
            text: "@font(size: 18){hello}", fontName: fontName, fontSize: base,
            caretLocation: -1, configuration: .default
        )
        #expect(font(in: attrs, at: 2)?.pointSize != hiddenSize)
    }

    @Test("styling a directive-bearing document scoped to one paragraph matches the full pass")
    func scopedMatchesFull() {
        let text = "intro line\n\n@font(size: 18){hello} tail\n\noutro"
        let ns = text as NSString
        let paragraph = ns.paragraphRange(for: ns.range(of: "@font"))
        func keys(_ scoped: [NSRange]?) -> String {
            let ranges = MarkdownASTStyler.styleAttributes(
                text: text, fontName: fontName, fontSize: base,
                scopedRanges: scoped, configuration: configuration
            ).filter { NSIntersectionRange($0.range, paragraph).length > 0 }
            return digest(ranges)
        }
        #expect(keys([paragraph]) == keys(nil))
    }
}
