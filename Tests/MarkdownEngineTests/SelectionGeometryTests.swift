import AppKit
import Testing
@testable import MarkdownEngine

@Suite("Selection geometry")
struct SelectionGeometryTests {
    @Test("wrapped-line selection rectangles stay line-local")
    func wrappedLineSelectionStaysLineLocal() {
        let fragmentFrame = CGRect(x: 20, y: 100, width: 300, height: 60)
        let drawPoint = CGPoint(x: 5, y: 10)
        let firstSegment = CGRect(x: 40, y: 105, width: 120, height: 18)
        let secondSegment = CGRect(x: 60, y: 125, width: 90, height: 18)

        let first = MarkdownTextLayoutFragment.selectionDrawRect(
            segmentFrame: firstSegment,
            drawPoint: drawPoint,
            fragmentFrame: fragmentFrame,
            scale: 2
        )
        let second = MarkdownTextLayoutFragment.selectionDrawRect(
            segmentFrame: secondSegment,
            drawPoint: drawPoint,
            fragmentFrame: fragmentFrame,
            scale: 2
        )

        #expect(first.maxY <= second.minY)
        #expect(first.height == 18)
        #expect(second.height == 18)
    }
}
