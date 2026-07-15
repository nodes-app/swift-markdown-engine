//
//  BlockExtensionTests.swift
//  MarkdownEngineTests
//
//  Created by Luca Chen on 15.07.26.
//
//  The block half of the extension seam: fenced extension blocks
//  (`::: … :::`) parse, style, render, and splice incrementally — and stay
//  literal text without a registered extension.
//

import AppKit
import Foundation
import Testing
@testable import MarkdownEngine

@Suite("Block extensions — fenced blocks")
struct BlockExtensionTests {

    private var registry: ExtensionRegistry {
        ExtensionRegistry(extensions: [ContainerExtension()])
    }

    private func kinds(_ text: String, _ registry: ExtensionRegistry = .empty) -> [BlockKind] {
        BlockParser.computeBlocks(text, registry: registry).map(\.kind)
    }

    // MARK: - Recognition

    @Test("without a registered extension, ::: lines stay paragraphs")
    func unregisteredStaysLiteral() {
        #expect(kinds("::: note\nBody\n:::") == [.paragraph])
    }

    @Test("a closed fenced block parses as one ext block")
    func closedBlock() {
        let text = "before\n\n::: note\nBody\n:::\nafter"
        #expect(kinds(text, registry) == [.paragraph, .blank, .ext("container"), .paragraph])
    }

    @Test("an unclosed fence runs to the end of the document")
    func unclosedRunsToEOF() {
        #expect(kinds("::: note\nBody one\nBody two", registry) == [.ext("container")])
    }

    @Test("an extension fence interrupts a paragraph")
    func fenceInterruptsParagraph() {
        let text = "prose line\n::: note\nBody\n:::"
        #expect(kinds(text, registry) == [.paragraph, .ext("container")])
    }

    @Test("a fence inside a code block stays code (built-ins win)")
    func fenceInsideCodeStaysCode() {
        let text = "```\n::: not a callout\n```"
        #expect(kinds(text, registry) == [.fencedCode])
    }

    @Test("blocks tile the document gap-free with an ext block present")
    func tilingHolds() {
        let text = "# H\n\n::: note\nBody\n:::\n\n- item\n"
        let blocks = BlockParser.computeBlocks(text, registry: registry)
        var cursor = 0
        for b in blocks {
            #expect(b.range.location == cursor, "gap before \(b.kind)")
            cursor = NSMaxRange(b.range)
        }
        #expect(cursor == (text as NSString).length)
    }

    // MARK: - AST geometry + inline content

    @Test("the AST node carries fences, content, and inline-parsed children")
    func astNodeGeometry() throws {
        let text = "::: note\nBody with **bold**\n:::"
        let ns = text as NSString
        let nodes = DocumentAST.parse(text, registry: registry)
        guard case .ext(let node) = try #require(nodes.first) else {
            Issue.record("expected .ext, got \(nodes)"); return
        }
        #expect(node.extensionID == "container")
        #expect(ns.substring(with: node.openFence) == "::: note\n")
        #expect(ns.substring(with: try #require(node.closeFence)) == ":::")
        #expect(ns.substring(with: node.contentRange) == "Body with **bold**\n")
        // Inline content parsed: the ** span is an emphasis child.
        #expect(node.inlines.contains { if case .emphasis = $0 { return true }; return false })
    }

    @Test("an unclosed block has no close fence and content to EOF")
    func unclosedGeometry() throws {
        let text = "::: note\nBody"
        let nodes = DocumentAST.parse(text, registry: registry)
        guard case .ext(let node) = try #require(nodes.first) else {
            Issue.record("expected .ext"); return
        }
        #expect(node.closeFence == nil)
        #expect((text as NSString).substring(with: node.contentRange) == "Body")
    }

    // MARK: - Styling

    @Test("content gets the extension attributes; hidden fences when caret is outside")
    func stylingAppliesAttributes() {
        let text = "::: note\nBody\n:::"
        let config = MarkdownEditorConfiguration(extensions: [ContainerExtension()])
        let attrs = MarkdownASTStyler.styleAttributes(
            text: text, fontName: "Helvetica", fontSize: 14, caretLocation: -1,
            configuration: config
        )
        // Content line carries the container background.
        let contentPos = (text as NSString).range(of: "Body").location
        let background = attrs.contains { range, a in
            NSLocationInRange(contentPos, range) && a[.backgroundColor] != nil
        }
        #expect(background, "content line must carry the container background")
        // The fence line is hidden (clear foreground) while the caret is outside.
        let fenceHidden = attrs.contains { range, a in
            NSLocationInRange(0, range) && (a[.foregroundColor] as? NSColor) == NSColor.clear
        }
        #expect(fenceHidden, "fence must hide while inactive")
    }

    @Test("fences reveal muted while the caret is inside the block")
    func fencesRevealWhenActive() {
        let text = "::: note\nBody\n:::"
        let config = MarkdownEditorConfiguration(extensions: [ContainerExtension()])
        let attrs = MarkdownASTStyler.styleAttributes(
            text: text, fontName: "Helvetica", fontSize: 14, caretLocation: 12,
            configuration: config
        )
        let fenceMuted = attrs.contains { range, a in
            NSLocationInRange(0, range)
                && (a[.foregroundColor] as? NSColor) == MarkdownEditorTheme.default.mutedText
        }
        #expect(fenceMuted, "fence must show muted while active")
    }

    // MARK: - HTML (clean copy)

    @Test("HTML wraps the content; unregistered stays literal")
    func htmlRendering() {
        let md = "::: note\nBody with **bold**\n:::"
        let with = MarkdownHTMLRenderer.html(from: md, extensions: [ContainerExtension()])
        #expect(with.contains("<blockquote>"))
        #expect(with.contains("<strong>bold</strong>"))
        let without = MarkdownHTMLRenderer.html(from: md)
        #expect(!without.contains("<blockquote>"))
    }

    // MARK: - Tokens

    @Test("the block projects one extensionBlock token with fence markers")
    func tokenProjection() throws {
        let text = "::: note\nBody\n:::"
        let tokens = MarkdownTokenizer.parseTokensViaAST(in: text, registry: registry)
        let block = try #require(tokens.first { $0.kind == .extensionBlock("container") })
        #expect(block.range == NSRange(location: 0, length: (text as NSString).length))
        #expect(block.markerRanges.count == 2)
        #expect((text as NSString).substring(with: block.contentRange) == "Body\n")
    }

    // MARK: - Incremental parity

    @Test("an interior edit splices to the same blocks as a full parse")
    func interiorEditSplices() throws {
        // The edit sits mid-line, > 3 chars from both line ends — inside the
        // delimiter guard's line-expanded window nothing but the content line
        // is visible, so the splice path must engage.
        let old = "before\n\n::: note\nBody middle content here\n:::\n\nafter"
        let new = "before\n\n::: note\nBody middleX content here\n:::\n\nafter"
        let oldChars = Array((old as NSString).substring(with: NSRange(location: 0, length: (old as NSString).length)).utf16)
        let newChars = Array((new as NSString).substring(with: NSRange(location: 0, length: (new as NSString).length)).utf16)
        let oldBlocks = BlockParser.computeBlocks(old, registry: registry)
        let diff = try #require(BlockParser.scanDiff(old: oldChars, new: newChars))
        let spliced = BlockParser.incrementalParse(
            oldChars: oldChars, oldBlocks: oldBlocks,
            newChars: newChars, newNS: new as NSString, diff: diff, registry: registry
        )?.blocks
        #expect(spliced != nil, "interior edit must take the splice path")
        #expect(spliced == BlockParser.computeBlocks(new, registry: registry))
    }

    @Test("an edit touching a fence line bails to the full reparse (delimiter guard)")
    func fenceEditBails() throws {
        // Typing the closing fence: incremental must refuse (fences pair at a distance).
        let old = "::: note\nBody\n::"
        let new = "::: note\nBody\n:::"
        let oldChars = Array(old.utf16)
        let newChars = Array(new.utf16)
        let oldBlocks = BlockParser.computeBlocks(old, registry: registry)
        let diff = try #require(BlockParser.scanDiff(old: oldChars, new: newChars))
        let spliced = BlockParser.incrementalParse(
            oldChars: oldChars, oldBlocks: oldBlocks,
            newChars: newChars, newNS: new as NSString, diff: diff, registry: registry
        )
        #expect(spliced == nil, "a fence edit must force the full reparse")
        // And the full parse is correct either way.
        #expect(kinds(new, registry) == [.ext("container")])
    }

    @Test("backspace-joining two paragraphs bails to the full reparse (splice can't merge across the cut)")
    func paragraphJoinBails() throws {
        // Pre-existing splice gap surfaced by the seam review: deleting the
        // separator between two paragraphs left them as two adjacent
        // .paragraph blocks (a full parse always merges them). The trailing
        // guard must fall back to the full reparse instead. Registry-free —
        // the bug class is independent of extensions.
        let old = "ab \n\nc"
        let new = "ab\nc"
        let oldChars = Array(old.utf16)
        let newChars = Array(new.utf16)
        let oldBlocks = BlockParser.computeBlocks(old)
        let diff = try #require(BlockParser.scanDiff(old: oldChars, new: newChars))
        let spliced = BlockParser.incrementalParse(
            oldChars: oldChars, oldBlocks: oldBlocks,
            newChars: newChars, newNS: new as NSString, diff: diff
        )
        if let spliced {
            // If a splice IS produced it must equal the full parse.
            #expect(spliced.blocks == BlockParser.computeBlocks(new))
        }
        #expect(BlockParser.computeBlocks(new).map(\.kind) == [.paragraph])
    }

    @Test("fence/content split agrees with block tiling on U+2028 line separators")
    func unicodeLineSeparatorGeometry() throws {
        // NSString.lineRange treats U+2028 as a terminator, so the block's
        // first "line" ends there — the AST fence split must agree instead of
        // swallowing the next physical line into the fence.
        let text = ":::note\u{2028}body\n:::"
        let ns = text as NSString
        let nodes = DocumentAST.parse(text, registry: registry)
        guard case .ext(let node) = try #require(nodes.first) else {
            Issue.record("expected .ext, got \(nodes)"); return
        }
        #expect(ns.substring(with: node.openFence) == ":::note\u{2028}")
        #expect(ns.substring(with: node.contentRange) == "body\n")
    }

    @Test("without block extensions the delimiter guard is unchanged")
    func guardNoopWithoutFences() {
        let buf = Array("::: note".utf16)
        #expect(!BlockParser.hasBlockDelimiter(buf, 0, buf.count))
        #expect(BlockParser.hasBlockDelimiter(buf, 0, buf.count, fences: [Array(":::".utf16)]))
    }
}
