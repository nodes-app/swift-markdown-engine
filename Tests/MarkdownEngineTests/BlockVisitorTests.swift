import Testing
import Foundation
@testable import MarkdownEngine

@Suite("BlockVisitor")
struct BlockVisitorTests {

    @Test func defaultWalkVisitsAllBlocksInOrder() {
        let result = BlockScanner.scan("# A\n\nBody\n\n```\ncode\n```")
        var visited: [BlockKind] = []
        struct Recorder: BlockVisitor {
            var collect: (BlockKind) -> Void
            func visit(_ span: BlockSpan, depth: Int) {
                collect(span.kind)
            }
        }
        var v = Recorder(collect: { visited.append($0) })
        v.walk(result.blocks)
        #expect(visited.count == result.blocks.count)
        // Top-level kinds must match block order.
        for (i, b) in result.blocks.enumerated() {
            #expect(visited[i] == b.kind)
        }
    }

    @Test func walkRecursesIntoChildren() {
        // Phase 1 spans never have children, but the default walk must already
        // recurse so Phase 2 nested blocks work without changes.
        let leaf = BlockSpan(kind: .paragraph,
                             range: NSRange(location: 10, length: 5),
                             contentRange: NSRange(location: 10, length: 5))
        let container = BlockSpan(kind: .blockquote,
                                  range: NSRange(location: 0, length: 20),
                                  contentRange: NSRange(location: 2, length: 18),
                                  children: [leaf])
        var visited: [BlockKind] = []
        struct Recorder: BlockVisitor {
            var collect: (BlockKind) -> Void
            func visit(_ span: BlockSpan, depth: Int) {
                collect(span.kind)
            }
        }
        var v = Recorder(collect: { visited.append($0) })
        v.walk([container])
        #expect(visited == [.blockquote, .paragraph])
    }
}
