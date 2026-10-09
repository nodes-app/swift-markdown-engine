import Foundation
import Testing
@testable import MarkdownEngine

struct WikiLinkStorageRangeTests {
    @Test
    func displaySelectionsMapToRawUTF16OffsetsAndRejectAmbiguousLinkInteriors() {
        let source = "😀 before [[Old|opaque-id]] after"
        let state = WikiLinkService.makeDisplayState(from: source)
        let display = state.display as NSString
        let raw = source as NSString
        let displayLink = display.range(of: "[[Old]]")
        let rawLink = raw.range(of: "[[Old|opaque-id]]")
        let before = display.range(of: "before")

        #expect(WikiLinkService.storageRange(forDisplayRange: before, metadata: state.metadata)
            == raw.range(of: "before"))
        #expect(WikiLinkService.storageRange(forDisplayRange: displayLink, metadata: state.metadata) == rawLink)
        #expect(WikiLinkService.storageRange(
            forDisplayRange: NSRange(location: displayLink.location + 3, length: 1),
            metadata: state.metadata
        ) == nil)
    }

    @Test
    func rangesWithoutProjectedLinksStayUnchanged() {
        let range = NSRange(location: 3, length: 18)
        #expect(WikiLinkService.storageRange(forDisplayRange: range, metadata: [:]) == range)
    }

    @Test
    func rangesAfterMultipleRenamedLinksUseRawUTF16Offsets() {
        let source = "😀 [[Old|first-id]] [[Other|second-id]] [Note](../note.md) https://example.com"
        let state = WikiLinkService.makeDisplayState(from: source) { id in
            id == "first-id" ? "A much longer name 😀" : "X"
        }
        let display = state.display as NSString
        let raw = source as NSString
        for text in ["[Note](../note.md)", "../note.md", "https://example.com"] {
            #expect(WikiLinkService.storageRange(
                forDisplayRange: display.range(of: text), metadata: state.metadata
            ) == raw.range(of: text))
        }
        #expect(WikiLinkService.storageRange(
            forDisplayRange: NSRange(location: 0, length: display.length), metadata: state.metadata
        ) == NSRange(location: 0, length: raw.length))
    }

    @Test
    func tokenBoundariesMapExactlyButPartialLabelsAreAmbiguous() {
        let source = "before [[Old|opaque-id]] after"
        let state = WikiLinkService.makeDisplayState(from: source) { _ in "Renamed" }
        let displayLink = (state.display as NSString).range(of: "[[Renamed]]")
        let rawLink = (source as NSString).range(of: "[[Old|opaque-id]]")
        for (display, raw) in [(displayLink.location, rawLink.location),
                               (NSMaxRange(displayLink), NSMaxRange(rawLink))] {
            #expect(WikiLinkService.storageRange(
                forDisplayRange: NSRange(location: display, length: 0), metadata: state.metadata
            ) == NSRange(location: raw, length: 0))
        }
        #expect(WikiLinkService.storageRange(
            forDisplayRange: NSRange(location: 0, length: displayLink.location + 3),
            metadata: state.metadata
        ) == nil)
        #expect(WikiLinkService.storageRange(
            forDisplayRange: NSRange(location: displayLink.location + 3, length: 0),
            metadata: state.metadata
        ) == nil)
    }

    @Test
    func invalidRangesAreRejected() {
        for range in [NSRange(location: NSNotFound, length: 0),
                      NSRange(location: -1, length: 0), NSRange(location: 0, length: -1)] {
            #expect(WikiLinkService.storageRange(forDisplayRange: range, metadata: [:]) == nil)
        }
    }
}
