//
//  GoldenCorpusTests.swift
//  MarkdownEngineTests
//
//  Created by Luca Chen on 15.07.26.
//
//  Golden corpus: one fixture per construct, snapshotting the HTML renderer
//  output. `baselineHTML` was recorded on the PRE-extension-seam engine
//  (commit 917370e) with highlight still built in — so these tests prove the
//  seam changed NOTHING: with a registered `HighlightExtension` the output is
//  byte-identical to the old engine, and without one only the highlight
//  fixtures change (== stays literal), every other construct untouched.
//

import Foundation
import Testing
@testable import MarkdownEngine

struct GoldenEntry {
    let name: String
    let markdown: String
    let baselineHTML: String
}

@Suite("Golden corpus — HTML per construct")
struct GoldenCorpusTests {

    static let corpus: [GoldenEntry] = [
        GoldenEntry(
            name: "heading",
            markdown: #"""
# Titel *kursiv* und **fett**
"""#,
            baselineHTML: #"""
<h1>Titel <em>kursiv</em> und <strong>fett</strong></h1>
"""#
        ),
        GoldenEntry(
            name: "paragraph-emphasis",
            markdown: #"""
Normal *kursiv* **fett** ***beides*** Ende.
"""#,
            baselineHTML: #"""
<p>Normal <em>kursiv</em> <strong>fett</strong> <strong><em>beides</em></strong> Ende.</p>
"""#
        ),
        GoldenEntry(
            name: "blockquote",
            markdown: #"""
> Zitat Zeile eins
> Zeile *zwei*
"""#,
            baselineHTML: #"""
<blockquote>Zitat Zeile eins
Zeile <em>zwei</em></blockquote>
"""#
        ),
        GoldenEntry(
            name: "unordered-list",
            markdown: #"""
- eins
- zwei *kursiv*
- drei
"""#,
            baselineHTML: #"""
<ul>
<li>eins</li>
<li>zwei <em>kursiv</em></li>
<li>drei</li>
</ul>
"""#
        ),
        GoldenEntry(
            name: "ordered-list",
            markdown: #"""
1. erster
2. zweiter
"""#,
            baselineHTML: #"""
<ol>
<li>erster</li>
<li>zweiter</li>
</ol>
"""#
        ),
        GoldenEntry(
            name: "task-list",
            markdown: #"""
- [ ] offen
- [x] erledigt
"""#,
            baselineHTML: #"""
<ul>
<li><input type="checkbox" disabled> offen</li>
<li><input type="checkbox" checked disabled> erledigt</li>
</ul>
"""#
        ),
        GoldenEntry(
            name: "fenced-code",
            markdown: #"""
```swift
let x = 1 < 2
```
"""#,
            baselineHTML: #"""
<pre><code class="language-swift">let x = 1 &lt; 2</code></pre>
"""#
        ),
        GoldenEntry(
            name: "inline-code",
            markdown: #"""
Der Wert `x < y` gilt.
"""#,
            baselineHTML: #"""
<p>Der Wert <code>x &lt; y</code> gilt.</p>
"""#
        ),
        GoldenEntry(
            name: "link",
            markdown: #"""
Siehe [Anthropic](https://anthropic.com) hier.
"""#,
            baselineHTML: #"""
<p>Siehe <a href="https://anthropic.com">Anthropic</a> hier.</p>
"""#
        ),
        GoldenEntry(
            name: "image",
            markdown: #"""
![Alt Text](https://example.com/a.png)
"""#,
            baselineHTML: #"""
<p><img src="https://example.com/a.png" alt="Alt Text"></p>
"""#
        ),
        GoldenEntry(
            name: "wiki-link",
            markdown: #"""
Verweis auf [[Mein Node|ABC-123]] fertig.
"""#,
            baselineHTML: #"""
<p>Verweis auf Mein Node fertig.</p>
"""#
        ),
        GoldenEntry(
            name: "image-embed",
            markdown: #"""
![[bild.png|ABC|300]]
"""#,
            baselineHTML: #"""
<p><img src="bild.png|ABC|300" alt="bild.png|ABC|300"></p>
"""#
        ),
        GoldenEntry(
            name: "strikethrough",
            markdown: #"""
Alt ~~gestrichen~~ neu.
"""#,
            baselineHTML: #"""
<p>Alt <del>gestrichen</del> neu.</p>
"""#
        ),
        GoldenEntry(
            name: "highlight",
            markdown: #"""
Wichtig ==markiert== Ende.
"""#,
            baselineHTML: #"""
<p>Wichtig <mark>markiert</mark> Ende.</p>
"""#
        ),
        GoldenEntry(
            name: "highlight-wraps-emphasis",
            markdown: #"""
==mit *kursiv* innen==
"""#,
            baselineHTML: #"""
<p><mark>mit <em>kursiv</em> innen</mark></p>
"""#
        ),
        GoldenEntry(
            name: "emphasis-wraps-highlight",
            markdown: #"""
*außen ==innen== Ende*
"""#,
            baselineHTML: #"""
<p><em>außen <mark>innen</mark> Ende</em></p>
"""#
        ),
        GoldenEntry(
            name: "highlight-in-heading",
            markdown: #"""
## Kopf ==markiert==
"""#,
            baselineHTML: #"""
<h2>Kopf <mark>markiert</mark></h2>
"""#
        ),
        GoldenEntry(
            name: "highlight-in-list",
            markdown: #"""
- Punkt ==eins==
- Punkt zwei
"""#,
            baselineHTML: #"""
<ul>
<li>Punkt <mark>eins</mark></li>
<li>Punkt zwei</li>
</ul>
"""#
        ),
        GoldenEntry(
            name: "highlight-adjacent-code",
            markdown: #"""
`code` und ==mark== und `mehr`
"""#,
            baselineHTML: #"""
<p><code>code</code> und <mark>mark</mark> und <code>mehr</code></p>
"""#
        ),
        GoldenEntry(
            name: "triple-equals-literal",
            markdown: #"""
a ===kein Highlight=== b
"""#,
            baselineHTML: #"""
<p>a ===kein Highlight=== b</p>
"""#
        ),
        GoldenEntry(
            name: "inline-latex",
            markdown: #"""
Formel $x^2 + y$ im Text.
"""#,
            baselineHTML: #"""
<p>Formel $x^2 + y$ im Text.</p>
"""#
        ),
        GoldenEntry(
            name: "block-latex",
            markdown: #"""
$$
E = mc^2
$$
"""#,
            baselineHTML: #"""
<pre>$$
E = mc^2
$$</pre>
"""#
        ),
        GoldenEntry(
            name: "table",
            markdown: #"""
| A | B |
|---|---|
| 1 | ==x== |
| 3 | 4 |
"""#,
            baselineHTML: #"""
<table><thead><tr><th>A</th><th>B</th></tr></thead><tbody><tr><td>1</td><td>==x==</td></tr><tr><td>3</td><td>4</td></tr></tbody></table>
"""#
        ),
        GoldenEntry(
            name: "thematic-break",
            markdown: #"""
oben

---

unten
"""#,
            baselineHTML: #"""
<p>oben
</p>
<hr>
<p>unten</p>
"""#
        ),
        GoldenEntry(
            name: "escape",
            markdown: #"""
Literal \*kein kursiv\* hier.
"""#,
            baselineHTML: #"""
<p>Literal *kein kursiv* hier.</p>
"""#
        ),
        GoldenEntry(
            name: "mixed-document",
            markdown: #"""
# Doc

Text mit ==mark== und ~~strike~~.

- [ ] task ==hi==

```
raw ==nicht== markiert
```

> quote ==auch==

"""#,
            baselineHTML: #"""
<h1>Doc</h1>
<p>Text mit <mark>mark</mark> und <del>strike</del>.
</p>
<ul>
<li><input type="checkbox" disabled> task <mark>hi</mark></li>
</ul>
<pre><code>raw ==nicht== markiert</code></pre>
<blockquote>quote <mark>auch</mark></blockquote>
"""#
        ),
    ]

    /// Fixture names whose baseline contains extension-rendered output
    /// (highlight `<mark>` and/or strikethrough `<del>`).
    private static let extensionFixtures: Set<String> = [
        "highlight", "highlight-wraps-emphasis", "emphasis-wraps-highlight",
        "highlight-in-heading", "highlight-in-list", "highlight-adjacent-code",
        "strikethrough", "mixed-document",
    ]

    @Test("with both extensions the output matches the pre-seam baseline",
          arguments: corpus.map(\.name))
    func matchesBaseline(name: String) throws {
        let entry = try #require(Self.corpus.first { $0.name == name })
        let html = MarkdownHTMLRenderer.html(from: entry.markdown,
                                             extensions: [HighlightExtension(), StrikethroughExtension()])
        #expect(html == entry.baselineHTML, "construct \(name) diverged from baseline")
    }

    @Test("without extensions, ==/~~ stay literal and nothing else moves",
          arguments: corpus.map(\.name))
    func pureCoreBehavior(name: String) throws {
        let entry = try #require(Self.corpus.first { $0.name == name })
        let html = MarkdownHTMLRenderer.html(from: entry.markdown)
        if Self.extensionFixtures.contains(name) {
            #expect(!html.contains("<mark>") && !html.contains("<del>"),
                    "unregistered extension syntax must stay literal in \(name)")
        } else {
            #expect(html == entry.baselineHTML, "non-highlight construct \(name) must not depend on extensions")
        }
    }
}
