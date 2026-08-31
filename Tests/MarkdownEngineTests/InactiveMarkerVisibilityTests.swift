//
//  InactiveMarkerVisibilityTests.swift
//  MarkdownEngineTests
//
//  `hidesInactiveMarkers`: a source-style pane keeps every syntax marker on
//  screen while the document stays fully styled. The distinction that matters
//  is against `rawSourceMode`, which drops styling altogether — here headings
//  stay large and code blocks keep their run, so the two are not interchangeable.
//  Markers that stand in for drawn content keep hiding regardless. Headless.
//

import AppKit
import Foundation
import Testing
@testable import MarkdownEngine

@Suite("hidesInactiveMarkers — a styled document that still shows its source")
struct InactiveMarkerVisibilityTests {

    private let base: CGFloat = 14
    private var fontName: String { NSFont.systemFont(ofSize: 14).fontName }

    private var revealing: MarkdownEditorConfiguration {
        var config = MarkdownEditorConfiguration.default
        config.hidesInactiveMarkers = false
        return config
    }

    private func style(
        _ text: String,
        configuration: MarkdownEditorConfiguration = .default
    ) -> [StyledRange] {
        MarkdownASTStyler.styleAttributes(
            text: text,
            fontName: fontName,
            fontSize: base,
            configuration: configuration
        )
    }

    /// Effective value for `key` at `pos`: the last styled range covering it that sets it.
    private func attribute(
        _ key: NSAttributedString.Key,
        in attrs: [StyledRange],
        at pos: Int
    ) -> Any? {
        var result: Any?
        for (range, a) in attrs where NSLocationInRange(pos, range) {
            if let value = a[key] { result = value }
        }
        return result
    }

    private func font(_ attrs: [StyledRange], at pos: Int) -> NSFont? {
        attribute(.font, in: attrs, at: pos) as? NSFont
    }

    private func color(_ attrs: [StyledRange], at pos: Int) -> NSColor? {
        attribute(.foregroundColor, in: attrs, at: pos) as? NSColor
    }

    // MARK: - The default is untouched

    @Test("default: an inactive heading marker still shrinks away")
    func defaultStillHidesHeadingMarker() {
        let attrs = style("# Title")
        #expect(
            font(attrs, at: 0)?.pointSize
                == MarkdownEditorConfiguration.default.markers.hiddenMarkerFontSize
        )
    }

    @Test("default: an inactive fence still renders clear")
    func defaultStillHidesCodeFence() {
        let attrs = style("```swift\nlet x = 1\n```\n")
        #expect(color(attrs, at: 0) == .clear)
    }

    // MARK: - Revealed

    @Test("revealed: a heading marker keeps the heading font instead of shrinking")
    func revealedHeadingMarkerKeepsHeadingFont() {
        let attrs = style("# Title", configuration: revealing)
        let marker = font(attrs, at: 0)?.pointSize
        let content = font(attrs, at: 2)?.pointSize

        #expect(marker == content)
        #expect((marker ?? 0) > base)
    }

    @Test("revealed: fence and quote markers take mutedText, never clear")
    func revealedBlockMarkersUseMutedText() {
        let text = "> quoted\n\n```swift\nlet x = 1\n```\n"
        let ns = text as NSString
        let attrs = style(text, configuration: revealing)
        let muted = MarkdownEditorTheme.default.mutedText

        #expect(color(attrs, at: 0) == muted)                              // `>`
        #expect(color(attrs, at: ns.range(of: "```").location) == muted)   // opening fence
    }

    @Test("revealed: an inline emphasis marker is never shrunk")
    func revealedEmphasisMarkerIsNotShrunk() {
        let hidden = style("a **bold** word")
        let shown = style("a **bold** word", configuration: revealing)

        #expect(
            font(hidden, at: 2)?.pointSize
                == MarkdownEditorConfiguration.default.markers.hiddenMarkerFontSize
        )
        // No font override at all: the marker inherits the body font it sits in.
        #expect(font(shown, at: 2) == nil)
    }

    // MARK: - Not rawSourceMode

    @Test("revealed: the document is still styled — headings and bold survive")
    func revealedDocumentIsStillStyled() {
        let attrs = style("# Title\n\nsome **bold** text\n", configuration: revealing)
        let ns = "# Title\n\nsome **bold** text\n" as NSString
        let boldContent = ns.range(of: "bold").location

        #expect((font(attrs, at: 2)?.pointSize ?? 0) > base)
        #expect(
            font(attrs, at: boldContent)?.fontDescriptor
                .symbolicTraits.contains(.bold) == true
        )
    }

    // MARK: - Drawn substitutes are not markers

    @Test("revealed: a thematic break still hides its source behind the drawn rule")
    func revealedThematicBreakStaysHidden() {
        let attrs = style("para\n\n---\n\npara\n", configuration: revealing)
        let pos = ("para\n\n---\n\npara\n" as NSString).range(of: "---").location

        #expect(attribute(.thematicBreak, in: attrs, at: pos) as? Bool == true)
        #expect(color(attrs, at: pos) == .clear)
    }

    @Test("revealed: a task checkbox still hides its source behind the drawn box")
    func revealedTaskCheckboxStaysHidden() {
        let attrs = style("- [x] done\n", configuration: revealing)
        #expect(color(attrs, at: 0) == .clear)   // the `-` the checkbox replaces
    }
}
