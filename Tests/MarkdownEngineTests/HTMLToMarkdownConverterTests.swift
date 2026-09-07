#if os(macOS)
//
//  HTMLToMarkdownConverterTests.swift
//  MarkdownEngineTests
//
//  Test-first specification for the lenient HTML→Markdown converter used by
//  the editor's smart-paste path. Asserts the exact Markdown produced for each
//  representative construct, including messy real-world clipboard HTML.
//

import Foundation
import Testing
@testable import MarkdownEngine

@Suite("HTML → Markdown converter")
struct HTMLToMarkdownConverterTests {

    private func md(_ html: String) -> String? {
        HTMLToMarkdownConverter.markdown(fromHTML: html)
    }

    @Test("core element mapping — headings, emphasis, link, code, blockquote, hr")
    func coreElementMapping() {
        #expect(md("<h1>Title</h1>") == "# Title")
        #expect(md("<p><strong>bold</strong> and <em>italic</em></p>") == "**bold** and *italic*")
        #expect(md("<a href=\"https://example.com\">link</a>") == "[link](https://example.com)")
        #expect(md("<p>Use <code>let x</code> here</p>") == "Use `let x` here")
        #expect(md("<pre><code class=\"language-swift\">let x = 1</code></pre>") == "```swift\nlet x = 1\n```")
        #expect(md("<blockquote>quoted</blockquote>") == "> quoted")
        #expect(md("<hr>") == "----")
    }

    // MARK: - The headline case: lists → "- " / "1. " lines

    @Test("unordered and ordered lists")
    func unorderedList() {
        #expect(md("<ul><li>One</li><li>Two</li><li>Three</li></ul>") == "- One\n- Two\n- Three")
        #expect(md("<ol><li>Alpha</li><li>Beta</li><li>Gamma</li></ol>") == "1. Alpha\n2. Beta\n3. Gamma")
    }

    @Test("nested ul inside an li indents by two spaces")
    func nestedList() {
        let html = "<ul><li>Parent<ul><li>Child</li></ul></li></ul>"
        #expect(md(html) == "- Parent\n\t- Child")
    }

    @Test("checkbox li becomes GFM task item")
    func taskList() {
        let html = "<ul>"
            + "<li><input type=\"checkbox\">Todo</li>"
            + "<li><input type=\"checkbox\" checked>Done</li>"
            + "</ul>"
        #expect(md(html) == "- [ ] Todo\n- [x] Done")
        // Chat UIs (Claude) emit task lists as literal "[ ] text" in plain
        // <li>s; the escaped brackets must be reclaimed as a task marker.
        #expect(md("<ul><li>[ ] Task one</li><li>[x] Done task</li></ul>")
            == "- [ ] Task one\n- [x] Done task")
        // …but brackets elsewhere stay escaped (no accidental checkboxes).
        #expect(md("<ol><li>[ ] not a task</li></ol>") == "1. \\[ \\] not a task")
    }

    // MARK: - Messy real-world clipboard HTML

    @Test("messy inline styles and meta are unwrapped; non-HTML returns nil")
    func messyClipboardHTML() {
        let html = "<meta charset=\"utf-8\">"
            + "<ul>"
            + "<li><span style=\"color:red\">Live-Neuberechnung</span></li>"
            + "<li>Inline-Rendering</li>"
            + "</ul>"
        #expect(md(html) == "- Live-Neuberechnung\n- Inline-Rendering")
        #expect(md("just text") == nil)
    }

    @Test("regression fixes: entities, ol start, breaks, hrefs, escaping")
    func converterFixes() {
        #expect(md("<p>&#123;a&#125; &#x1F600;</p>") == "{a} 😀")
        #expect(md("<ol start=\"5\"><li>a</li><li>b</li></ol>") == "5. a\n6. b")
        #expect(md("<p>a<br>b</p>") == "a  \nb")
        #expect(md("<ul><li>a<br>b</li></ul>") == "- a  \n  b")
        #expect(md("<a href=\"/my file.md\">doc</a>") == "[doc](</my file.md>)")
        #expect(md("<p>1. First</p>") == "1\\. First")
        #expect(md("<p># not a heading</p>") == "\\# not a heading")
        #expect(md("<p>*stars*</p>") == "\\*stars\\*")
        #expect(md("<p><em>x</em></p>") == "*x*")
    }

    @Test("block children inside li stay in the item")
    func listItemBlocks() {
        #expect(md("<li><p>First</p><p>Second</p></li>") == "- First\n\n  Second")
        #expect(md("<ul><li>Parent<div><ul><li>Child</li></ul></div></li></ul>") == "- Parent\n\t- Child")
    }

    // Chromium strips the ul/ol wrapper on within-list copies (Claude/ChatGPT):
    // consecutive bare <li> become one tight bullet list, whitespace between
    // siblings must not split the run.
    @Test("full-document wrapper (html/head/body) still converts its blocks")
    func fullDocumentWrapper() {
        // GPT / CF_HTML exporters put a whole document on the clipboard; the
        // wrapper tags must be transparent, head/style must not leak as text.
        let html = "<meta charset='utf-8'><html><head><style>td{}</style></head><body>"
            + "<table>\n<thead>\n<tr>\n<th>Feld</th>\n<th>Wert</th>\n</tr>\n</thead>\n"
            + "<tbody>\n<tr>\n<td>Arbeitgeber</td>\n<td>CF GmbH</td>\n</tr>\n</tbody>\n</table></body></html>"
        #expect(md(html) == "| Feld | Wert |\n|---|---|\n| Arbeitgeber | CF GmbH |")
    }

    @Test("bare li fragments become one tight bullet list")
    func bareListItems() {
        #expect(md("<meta charset='utf-8'><li class=\"x\"><strong>A:</strong> one</li>\n  <li>two</li>")
            == "- **A:** one\n- two")
    }
}
#endif
