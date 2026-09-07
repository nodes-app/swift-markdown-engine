#if os(macOS)
//
//  PasteStructureGuardTests.swift
//  MarkdownEngine
//
//  Created by Luca Chen on 09.07.26.
//
//  The block-structure guard decides whether a pasted HTML flavor converts to
//  Markdown (real structure / formatted prose) or falls through to the plain-
//  text flavor (code, casual inline copies). Table-driven: one case per
//  clipboard shape. The `paste(_:)` override itself needs a live NSTextView,
//  so its branch selection is exercised through this pure helper.
//

import Foundation
import Testing
@testable import MarkdownEngine

@Suite("Paste HTML structure guard")
struct PasteStructureGuardTests {

    @Test("structural HTML converts")
    func structural() {
        let cases: [(String, String)] = [
            ("ul", "<ul><li>One</li><li>Two</li></ul>"),
            ("ol", "<ol start=\"3\"><li>One</li></ol>"),
            ("bare li (Chromium strips the wrapper)", "<meta charset='utf-8'><li class=\"x\"><strong>A:</strong> one</li><li>two</li>"),
            ("heading", "<h2>Title</h2>"),
            ("table", "<table><tr><td>A</td></tr></table>"),
            ("blockquote", "<blockquote>Quoted</blockquote>"),
            ("pre", "<pre><code>let x = 1</code></pre>"),
            ("hr", "Above<hr>Below"),
            ("formatted prose, ≥2 paragraphs", "<p><strong>Term:</strong> definition</p><p>More <i>text</i>.</p>"),
            ("prose with links", "<p>See <a href=\"https://x.com\">spec</a>.</p><p>Then read on.</p>"),
        ]
        for (label, html) in cases {
            #expect(NativeTextView.htmlHasBlockStructure(html), "\(label) should convert")
        }
    }

    @Test("inline-only / plain HTML falls through to plain text")
    func plain() {
        let cases: [(String, String)] = [
            ("VS Code div code", "<div>func foo() {</div><div>    return 1</div><div>}</div>"),
            ("bold word", "a <b>bold</b> word"),
            ("lone link", "see <a href=\"https://example.com\">here</a>"),
            ("single formatted paragraph", "<p><strong>bold</strong> in one sentence</p>"),
            ("two plain paragraphs", "<p>First.</p><p>Second.</p>"),
            ("no tags", "just some words, no markup at all"),
            ("tag-prefix is not a tag", "<premium>x</premium><premium>y</premium><b>z</b>"),
        ]
        for (label, html) in cases {
            #expect(!NativeTextView.htmlHasBlockStructure(html), "\(label) should stay plain")
        }
    }
}
#endif
