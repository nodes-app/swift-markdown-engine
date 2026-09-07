#if os(iOS)
import Testing
import UIKit
@testable import MarkdownEngine

@Suite("UIKit live Markdown styling")
struct UIKitMarkdownStylerTests {
    private let source = "# Heading\n\n**bold and *italic***\n\n[link](https://example.com)\n"

    @Test("Styling preserves the source string and UTF-16 coordinates")
    func preservesSource() {
        let styled = makeStyled(selection: NSRange(location: 0, length: 0))

        #expect(styled.string == source)
        #expect(styled.length == (source as NSString).length)
    }

    @Test("Heading and nested emphasis use the shared parser")
    func stylesParsedConstructs() {
        let styled = makeStyled(selection: NSRange(location: (source as NSString).length, length: 0))
        let ns = source as NSString
        let heading = ns.range(of: "Heading")
        let bold = ns.range(of: "bold and *italic*")
        let italic = ns.range(of: "italic")
        let headingFont = styled.attribute(.font, at: heading.location, effectiveRange: nil) as? UIFont
        let boldFont = styled.attribute(.font, at: bold.location, effectiveRange: nil) as? UIFont
        let italicFont = styled.attribute(.font, at: italic.location, effectiveRange: nil) as? UIFont

        #expect((headingFont?.pointSize ?? 0) > 16)
        #expect(boldFont?.fontDescriptor.symbolicTraits.contains(.traitBold) == true)
        #expect(italicFont?.fontDescriptor.symbolicTraits.contains(.traitBold) == true)
        #expect(italicFont?.fontDescriptor.symbolicTraits.contains(.traitItalic) == true)
    }

    @Test("Markers hide outside the active construct and reveal at the caret")
    func markerVisibilityFollowsSelection() {
        let ns = source as NSString
        let marker = ns.range(of: "**")
        let hidden = makeStyled(selection: NSRange(location: ns.length, length: 0))
        let revealed = makeStyled(selection: NSRange(location: marker.location, length: 0))
        let hiddenFont = hidden.attribute(.font, at: marker.location, effectiveRange: nil) as? UIFont
        let revealedFont = revealed.attribute(.font, at: marker.location, effectiveRange: nil) as? UIFont

        #expect((hiddenFont?.pointSize ?? 1) < 0.1)
        #expect((revealedFont?.pointSize ?? 0) >= 16)
    }

    @Test("Task checkbox is rendered without changing its Markdown source")
    func taskCheckboxRenderingPreservesSource() {
        let task = "- [x] completed\n"
        let range = (task as NSString).range(of: "[x]")
        let styled = makeStyled(task, selection: NSRange(location: (task as NSString).length, length: 0))
        let checkbox = styled.attribute(.taskCheckbox, at: range.location, effectiveRange: nil) as? Bool
        let hiddenFont = styled.attribute(.font, at: range.location, effectiveRange: nil) as? UIFont

        #expect(styled.string == task)
        #expect(checkbox == true)
        #expect((hiddenFont?.pointSize ?? 1) < 0.1)
    }

    @Test("Task source is revealed while its syntax is edited")
    func taskCheckboxSourceRevealsAtCaret() {
        let task = "- [ ] pending\n"
        let range = (task as NSString).range(of: "[ ]")
        let styled = makeStyled(task, selection: NSRange(location: range.location + 1, length: 0))
        let checkbox = styled.attribute(.taskCheckbox, at: range.location, effectiveRange: nil) as? Bool
        let revealedFont = styled.attribute(.font, at: range.location, effectiveRange: nil) as? UIFont

        #expect(styled.string == task)
        #expect(checkbox == nil)
        #expect((revealedFont?.pointSize ?? 0) >= 16)
    }

    private func makeStyled(selection: NSRange) -> NSAttributedString {
        makeStyled(source, selection: selection)
    }

    private func makeStyled(_ markdown: String, selection: NSRange) -> NSAttributedString {
        UIKitMarkdownStyler(
            configuration: .default,
            fontName: "SF Pro",
            fontSize: 16
        ).attributedString(for: markdown, selection: selection)
    }
}
#endif
