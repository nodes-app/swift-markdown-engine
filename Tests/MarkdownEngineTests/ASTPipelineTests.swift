//
//  ASTPipelineTests.swift
//  MarkdownEngineTests
//
//  Phase 2.5 — end-to-end checks that the full AST pipeline (BlockParser +
//  InlineParser + adapter) fixes the bugs the characterization latch pinned.
//

import Foundation
import Testing
@testable import MarkdownEngine

@Suite("Phase 2.5 — AST pipeline end-to-end")
struct ASTPipelineTests {

    @Test("scoped list AST contains only intersecting physical items")
    func scopedListContainsOnlyIntersectingItems() throws {
        let lines = (0..<2_000).map { "- [x] item \($0)\n" }
        let text = lines.joined()
        let ns = text as NSString
        let target = ns.range(of: "- [x] item 1500")
        let targetLine = ns.lineRange(for: target)

        let nodes = DocumentAST.parse(text, scopedRanges: [targetLine])
        let list = try #require(nodes.first)
        guard case .list(_, let items) = list else {
            Issue.record("Expected one scoped list node")
            return
        }

        #expect(items.map(\.range) == [targetLine])
    }

    @Test("scoped list AST normalizes overlapping and unordered scopes")
    func scopedListNormalizesScopes() throws {
        let text = "- one\n- two\n- three\n- four\n"
        let ns = text as NSString
        let second = ns.lineRange(for: ns.range(of: "- two"))
        let fourth = ns.lineRange(for: ns.range(of: "- four"))
        let overlappingSecond = NSRange(
            location: second.location + 1,
            length: second.length - 1
        )

        let nodes = DocumentAST.parse(
            text,
            scopedRanges: [
                fourth,
                NSRange(location: ns.length + 1, length: 1),
                overlappingSecond,
                second,
                NSRange(location: 0, length: 0),
            ]
        )
        let list = try #require(nodes.first)
        guard case .list(_, let items) = list else {
            Issue.record("Expected one scoped list node")
            return
        }

        #expect(items.map(\.range) == [second, fourth])
    }

    @Test("scoped list AST rejects malformed UTF-16 ranges")
    func scopedListRejectsMalformedRanges() throws {
        let text = "- one\n- two\n- three\n"
        let ns = text as NSString
        let second = ns.lineRange(for: ns.range(of: "- two"))

        let nodes = DocumentAST.parse(
            text,
            scopedRanges: [
                NSRange(location: -1, length: 1),
                NSRange(location: Int.max - 1, length: 4),
                NSRange(location: ns.length, length: 1),
                second,
            ]
        )
        let list = try #require(nodes.first)
        guard case .list(_, let items) = list else {
            Issue.record("Expected one scoped list node")
            return
        }

        #expect(items.map(\.range) == [second])
    }

    @Test("bug 2: no inline markup tokens inside a fenced code block")
    func bug2InlineInsideCode() {
        let text = "```swift\n*not italic* `not code`\n```\n"
        let tokens = MarkdownTokenizer.parseTokensViaAST(in: text)
        #expect(!tokens.isEmpty)
        #expect(tokens.allSatisfy { $0.kind == .codeBlock })
    }

    @Test("bug 4: a link with balanced parens in the URL is one whole link token")
    func bug4LinkParens() {
        let tokens = MarkdownTokenizer.parseTokensViaAST(in: "see [w](a(b)) end")
        let link = tokens.first { $0.kind == .link }
        #expect(link?.range == NSRange(location: 4, length: 9))
    }

    @Test("bug 3: no spurious latex token across code spans")
    func bug3CrossCodeLatex() {
        let tokens = MarkdownTokenizer.parseTokensViaAST(in: "the `$a` and `$b` vars")
        #expect(!tokens.contains { $0.kind == .inlineLatex })
        #expect(tokens.filter { $0.kind == .inlineCode }.count == 2)
    }

    @Test("block-level tokens are preserved (heading + emphasis in the title)")
    func headingPlusInline() {
        let tokens = MarkdownTokenizer.parseTokensViaAST(in: "# Title *x*")
        #expect(tokens.contains { $0.kind == .heading })
        #expect(tokens.contains { $0.kind == .italic })
    }
}
