//
//  MarkdownCorpus.swift
//  MarkdownEngineTests
//
//  Handcrafted edge-case corpus for the Phase 0 characterization latch and
//  the Phase 1 parity tests. Each case name doubles as a snapshot file name,
//  so names must be stable and filesystem-safe (kebab-case, no slashes).
//
//  Deliberately includes the gnarly cross-construct cases that motivated the
//  regex→AST refactor: [[ / ![[ adjacency, links with parentheses in the URL,
//  code spans containing '$', nested emphasis, and "looks-like-X-inside-code".
//

import Foundation

struct MarkdownCase {
    let name: String
    let text: String
}

enum MarkdownCorpus {
    static let cases: [MarkdownCase] = [
        // — Headings —
        .init(name: "heading-levels",
              text: "# H1\n## H2\n### H3\n#### H4\n##### H5\n###### H6\n####### seven hashes"),
        .init(name: "heading-leading-space",
              text: "   # indented heading\n#nospace not a heading"),

        // — Asterisk emphasis (stack parser) —
        .init(name: "emphasis-basic",
              text: "*italic* **bold** ***bolditalic***"),
        .init(name: "emphasis-nested",
              text: "**bold with *italic* inside** and *italic with **bold** inside*"),
        .init(name: "emphasis-intraword",
              text: "a*b*c and foo**bar**baz"),
        .init(name: "emphasis-rule-of-three",
              text: "***strong em*** and *a**b** and **a*b***"),
        .init(name: "emphasis-unclosed",
              text: "*open without close and **two opens *one close*"),

        // — Underscore emphasis (regex) —
        .init(name: "underscore-emphasis",
              text: "_italic_ __bold__ ___bolditalic___"),
        .init(name: "underscore-intraword",
              text: "snake_case_identifier stays plain"),

        // — Strikethrough —
        .init(name: "strikethrough",
              text: "before ~~deleted~~ after, and ~~~not strike~~~"),

        // — Wiki links & image embeds (incl. [[ / ![[ adjacency) —
        .init(name: "wikilink-plain",
              text: "see [[My Note]] and [[Other|550e8400-e29b-41d4-a716-446655440000]]"),
        .init(name: "imageembed-vs-wikilink-adjacency",
              text: "![[Pic]][[Note]] and ![[A]] [[B]] and text![[C]]more"),
        .init(name: "wikilink-empty-and-pipe",
              text: "[[]] and [[|id]] and [[Name|]]"),

        // — Markdown & image links (incl. parens-in-URL) —
        .init(name: "markdown-link",
              text: "[text](https://example.com) and [a](b)"),
        .init(name: "link-with-parens",
              text: "[wiki](https://en.wikipedia.org/wiki/Foo_(bar)) and [f](g(x))"),
        .init(name: "image-link",
              text: "![alt](https://example.com/i.png) text"),
        .init(name: "image-then-link-adjacent",
              text: "![a](u)[b](v)"),

        // — Code (incl. code span containing '$') —
        .init(name: "inline-code-basic",
              text: "use `code` here and `` `tick` `` too"),
        .init(name: "inline-code-with-dollar",
              text: "the var `$price` and `a + $b` are code, not math"),
        .init(name: "fenced-code",
              text: "```swift\nlet x = 1\n*not italic* `not code`\n```\n"),
        .init(name: "fenced-code-hides-blocky-things",
              text: "```\n$$ not block latex $$\n> not a quote\n| not | table |\n# not heading\n```\n"),

        // — LaTeX —
        .init(name: "inline-latex",
              text: "math $a + b = c$ and currency $50 and simple $x$"),
        .init(name: "block-latex",
              text: "$$\n\\int_0^1 x^2 dx\n$$\n"),

        // — Blockquotes —
        .init(name: "blockquote",
              text: "> quote line one\n>> nested quote\n>>> deep\nplain"),

        // — Tables —
        .init(name: "table",
              text: "| a | b |\n| - | - |\n| 1 | 2 |\ntrailing"),

        // — Thematic breaks —
        .init(name: "thematic-breaks",
              text: "above\n\n---\n\n***\n\n___\n\nbelow"),

        // — Task lists —
        .init(name: "task-list",
              text: "- [ ] todo\n- [x] done\n* [X] also done\n1. [ ] numbered"),

        // — Backslash escapes —
        .init(name: "backslash-escape",
              text: #"\*not italic\* and \`not code\` and \\ literal backslash"#),
        .init(name: "backslash-before-wikilink",
              text: #"\[[not a wikilink]] but [[real]]"#),

        // — Empty & whitespace —
        .init(name: "empty", text: ""),
        .init(name: "whitespace-only", text: "   \n\n\t\n"),
        .init(name: "plain-text", text: "Just a plain sentence with no markdown at all."),

        // — Unicode (multi-byte → UTF-16 offset correctness) —
        .init(name: "unicode",
              text: "**粗体** and _斜体_ and `代码` and 🎉 then *italic*"),

        // — Kitchen sink —
        .init(name: "kitchen-sink", text: """
        # Title with *emphasis*

        A paragraph with **bold**, _underscore_, `code`, a [link](https://example.com/(p)),
        a [[WikiNote|abc-123]], an ![[Embed]], and inline math $E = mc^2$.

        > A blockquote with ~~strike~~ and **bold**.

        ```python
        # not a heading
        x = "*not italic*"
        ```

        - [ ] task with `code`
        - [x] done

        | col | val |
        | --- | --- |
        | a   | $5  |

        ---

        Final line with \\*escaped\\* stars.
        """),
    ]
}
