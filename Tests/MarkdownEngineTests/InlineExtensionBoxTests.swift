//
//  InlineExtensionBoxTests.swift
//  MarkdownEngineTests
//
//  `InlineSyntax.inlineBoxWidth`: a span laid out as a fixed-width box the
//  embedder draws into, instead of as text. The engine's job is the space —
//  reserved on one character, kept whatever the caret is doing, and never
//  reclaimed by the marker-shrink pass.
//

import AppKit
import Foundation
import Testing
@testable import MarkdownEngine

@Suite("Inline extension boxes")
struct InlineExtensionBoxTests {

    private let base: CGFloat = 14
    private var fontName: String { NSFont.systemFont(ofSize: 14).fontName }

    /// A span rendered as a control: opaque content, no reveal, 26pt wide.
    private struct BoxExtension: MarkdownExtension {
        var width: CGFloat = 26

        var id: String { "box" }
        var inline: InlineSyntax? {
            InlineSyntax(open: "[t=", close: "]", parsesContent: false, inlineBoxWidth: width)
        }

        func contentAttributes(theme _: MarkdownEditorTheme) -> [NSAttributedString.Key: Any] {
            [.foregroundColor: NSColor.systemPink]
        }

        func html(childrenHTML _: String) -> String { "" }
    }

    /// Same syntax without a box, so the difference under test is the knob.
    private struct PlainExtension: MarkdownExtension {
        var id: String { "box" }
        var inline: InlineSyntax? {
            InlineSyntax(open: "[t=", close: "]", parsesContent: false)
        }

        func contentAttributes(theme _: MarkdownEditorTheme) -> [NSAttributedString.Key: Any] {
            [.foregroundColor: NSColor.systemPink]
        }

        func html(childrenHTML _: String) -> String { "" }
    }

    private func attributes(
        _ text: String,
        extensions: [any MarkdownExtension],
        caret: Int = 0
    ) -> [StyledRange] {
        var configuration = MarkdownEditorConfiguration.default
        configuration.extensions = extensions
        return MarkdownASTStyler.styleAttributes(
            text: text,
            fontName: fontName,
            fontSize: base,
            caretLocation: caret,
            configuration: configuration
        )
    }

    /// Order-independent digest of the styled ranges touching the span under
    /// test, so two style runs can be compared for equality. Scoped to the span
    /// because the caret also drives line-level chrome (the bullet marker).
    private func snapshot(_ ranges: [StyledRange]) -> String {
        ranges
            .filter { NSIntersectionRange($0.range, NSRange(location: boxStart, length: 17)).length > 0 }
            .map { range, values in
                let keys = values.keys
                    .map { "\($0.rawValue)=\(String(describing: values[$0]!))" }
                    .sorted()
                return "\(range.location)+\(range.length):\(keys.joined(separator: ","))"
            }
            .sorted()
            .joined(separator: "\n")
    }

    /// Effective value of `key` at `position`: the last styled range wins, the
    /// same way the text storage applies them.
    private func effective(
        _ key: NSAttributedString.Key,
        in attrs: [StyledRange],
        at position: Int
    ) -> Any? {
        var result: Any?
        for (range, values) in attrs where NSLocationInRange(position, range) {
            if let value = values[key] { result = value }
        }
        return result
    }

    private let document = "- Team agreed to postpone the launch [t=1284.3-1291.7]"
    /// Offset of the span's `[`, and of a digit inside its content.
    private var boxStart: Int { (document as NSString).range(of: "[t=").location }
    private var contentPosition: Int { boxStart + 4 }

    @Test("the box's width is reserved on the span's first character")
    func boxWidthRidesOnTheFirstCharacter() {
        let attrs = attributes(document, extensions: [BoxExtension()])
        let hidden = MarkdownEditorConfiguration.default.markers.hiddenMarkerFontSize

        let kern = effective(.kern, in: attrs, at: boxStart) as? CGFloat
        #expect(kern == 26 - hidden)
        #expect((effective(.font, in: attrs, at: boxStart) as? NSFont)?.pointSize == hidden)
    }

    @Test("every other character of the span collapses to nothing")
    func remainingCharactersCollapse() {
        let attrs = attributes(document, extensions: [BoxExtension()])
        let hidden = MarkdownEditorConfiguration.default.markers.hiddenMarkerFontSize

        #expect((effective(.kern, in: attrs, at: contentPosition) as? CGFloat) == -hidden)
        #expect((effective(.font, in: attrs, at: contentPosition) as? NSFont)?.pointSize == hidden)
        #expect((effective(.foregroundColor, in: attrs, at: contentPosition) as? NSColor) == .clear)
    }

    /// The point of the knob: the box holds its shape while the user types in
    /// the line it sits on. Revealing the delimiters would shove the box aside.
    @Test("a caret inside the span neither reveals it nor moves the box")
    func caretInsideTheSpanChangesNothing() {
        let resting = attributes(document, extensions: [BoxExtension()])
        let caretInside = attributes(document, extensions: [BoxExtension()], caret: contentPosition)
        let hidden = MarkdownEditorConfiguration.default.markers.hiddenMarkerFontSize

        #expect((effective(.kern, in: caretInside, at: boxStart) as? CGFloat) == 26 - hidden)
        #expect((effective(.foregroundColor, in: caretInside, at: boxStart) as? NSColor) == .clear)
        #expect(snapshot(resting) == snapshot(caretInside))
    }

    @Test("without the knob the span still lays out as text and reveals at the caret")
    func plainSpanKeepsUpstreamBehavior() {
        let resting = attributes(document, extensions: [PlainExtension()])
        let caretInside = attributes(document, extensions: [PlainExtension()], caret: contentPosition)
        let hidden = MarkdownEditorConfiguration.default.markers.hiddenMarkerFontSize

        // The content keeps the view's own font and advance: nothing collapses
        // it, which is exactly what a box changes.
        #expect(effective(.font, in: resting, at: contentPosition) == nil)
        #expect(effective(.kern, in: resting, at: contentPosition) == nil)
        #expect((effective(.font, in: resting, at: boxStart) as? NSFont)?.pointSize == hidden)
        #expect(
            effective(.font, in: caretInside, at: boxStart) == nil,
            "the caret drops the shrink, so a plain span's delimiters return to the body font"
        )
        #expect(snapshot(resting) != snapshot(caretInside))
    }

    /// The attribute tests above say what the styler asks for; this one says
    /// TextKit grants it. Two widths of the same document differ by exactly the
    /// difference in widths, so a reserved point is a laid-out point.
    @Test("the reserved width is the width the line gains")
    func reservedSpaceBecomesLaidOutSpace() {
        let wide = laidOutWidth(document, extensions: [BoxExtension(width: 26)])
        let narrow = laidOutWidth(document, extensions: [BoxExtension(width: 6)])
        #expect(abs((wide - narrow) - 20) < 0.01)
    }

    /// Width of the document's single line once the styler's attributes are on
    /// it, measured by TextKit rather than derived from the attributes.
    private func laidOutWidth(_ text: String, extensions: [any MarkdownExtension]) -> CGFloat {
        let storage = NSTextStorage(string: text)
        let full = NSRange(location: 0, length: storage.length)
        storage.addAttribute(.font, value: NSFont(name: fontName, size: base) ?? .systemFont(ofSize: base), range: full)
        for (range, values) in attributes(text, extensions: extensions) {
            storage.addAttributes(values, range: range)
        }
        let container = NSTextContainer(size: CGSize(width: 10_000, height: 10_000))
        container.lineFragmentPadding = 0
        let layoutManager = NSLayoutManager()
        layoutManager.addTextContainer(container)
        storage.addLayoutManager(layoutManager)
        layoutManager.ensureLayout(for: container)
        return layoutManager.usedRect(for: container).width
    }

    @Test("two registries differing only in the box width parse under distinct keys")
    func fingerprintCoversTheBoxWidth() {
        let boxed = ExtensionRegistry(extensions: [BoxExtension()])
        let plain = ExtensionRegistry(extensions: [PlainExtension()])
        #expect(boxed.fingerprint != plain.fingerprint)
    }
}
