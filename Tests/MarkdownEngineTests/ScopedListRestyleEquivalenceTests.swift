//
//  ScopedListRestyleEquivalenceTests.swift
//  MarkdownEngineTests
//
//  Created by Luca Chen on 12.08.26.
//
//  A scoped restyle builds only the list items its scope reached, but
//  `TextStylingService.restyle` hands the SAME ranges to the styler and to
//  `applyStyledRanges` — so every paragraph it resets to base attributes is a
//  paragraph the styler must fully re-emit. That makes scoped-vs-full an
//  equivalence, not an approximation, and ordered display numbers are the part
//  that breaks first: they are positional, so an item cut off from the items
//  above it has nothing left to count from.
//
//  Hand-written expectations cannot cover the shapes that go wrong (they are
//  combinations: which block precedes the list, which items the scope kept,
//  where the run ends), so this sweeps a corpus against the full pass instead —
//  every line as its own scope, and every pair of lines as the two-region scope
//  a caret move produces.
//

import AppKit
import Testing
@testable import MarkdownEngine

@MainActor
@Suite("Scoped list restyle equivalence")
struct ScopedListRestyleEquivalenceTests {

    private let fontSize: CGFloat = 14
    private var fontName: String { NSFont.systemFont(ofSize: 14).fontName }

    /// Shapes chosen for what precedes the list (nothing / content block / blank
    /// separator), how it nests, and where a scope can truncate the item run.
    private static let corpus: [(name: String, text: String)] = [
        ("flat-ordered", "1. one\n1. two\n1. three\n1. four\n1. five\n"),
        ("ordered-start-3", "3. a\n1. b\n1. c\n1. d\n"),
        ("nested-ordered", "1. a\n    1. a1\n    1. a2\n1. b\n    1. b1\n1. c\n"),
        ("mixed-markers", "1. a\n- b\n1. c\n* d\n1) e\n"),
        ("task-list", "- [ ] a **bold**\n- [x] b `code`\n- [ ] c [l](a.md)\n- [x] d\n"),
        ("loose-ordered", "1. a\n\n1. b\n\n1. c\n"),
        ("prose-split", "1. a\n1. b\n\ntext between\n\n1. c\n1. d\n"),
        ("list-then-heading", "1. a\n1. b\n# H\n1. c\n1. d\n"),
        ("inline-heavy", "1. *i* **b** `c` [l](a.md) ~~s~~\n1. plain\n1. *x* **y**\n"),
        ("indent-jumps", "1. a\n        1. deep\n1. b\n    1. mid\n1. c\n"),
        ("no-trailing-newline", "1. a\n1. b\n1. c"),
        ("blockquote-and-list", "> quote\n1. a\n1. b\n> more\n1. c\n"),
        ("heading-then-nested", "# H\n1. a\n    1. a1\n    1. a2\n1. b\n"),
        ("indented-list-start", "    1. a\n    1. b\n    1. c\n"),
        ("prose-then-deep", "text\n1. a\n        1. deep1\n        1. deep2\n1. b\n"),
        ("code-then-list", "```\nx\n```\n1. a\n1. b\n1. c\n"),
        ("table-then-list", "| a | b |\n| - | - |\n1. a\n1. b\n1. c\n"),
        ("two-runs", "1. a\n1. b\n# H\n1. c\n1. d\n# H2\n1. e\n1. f\n"),
        ("loose-tail", "1. one\n1. two\n\n1. three\n1. four\n"),
        ("loose-tail-numbered", "1. one\n2. two\n\n3. three\n4. four\n"),
        ("loose-tail-long", "1. a\n1. b\n1. c\n\n1. d\n1. e\n\n1. f\n1. g\n"),
    ]

    /// Through the real apply loop, so the comparison sees what storage sees.
    private func applied(_ text: String, paragraphs: [NSRange], caret: Int, scoped: [NSRange]?) -> NSAttributedString {
        let storage = NSMutableAttributedString(string: text)
        TextStylingService.applyStyledRanges(
            MarkdownASTStyler.styleAttributes(
                text: text, fontName: fontName, fontSize: fontSize,
                caretLocation: caret, scopedRanges: scoped
            ),
            paragraphs: paragraphs,
            baseAttributes: [.font: NSFont(name: fontName, size: fontSize) ?? NSFont.systemFont(ofSize: fontSize)],
            to: storage
        )
        return storage
    }

    private func lines(of text: String) -> [NSRange] {
        let ns = text as NSString
        var out: [NSRange] = []
        var cursor = 0
        while cursor < ns.length {
            let line = ns.lineRange(for: NSRange(location: cursor, length: 0))
            out.append(line)
            cursor = NSMaxRange(line)
        }
        return out
    }

    @Test("every single-line scope matches the full pass inside that line")
    func singleLineScopesMatchFullPass() {
        _ = NSApplication.shared
        for entry in Self.corpus {
            for line in lines(of: entry.text) {
                for caret in [-1, line.location + min(2, max(line.length - 1, 0))] {
                    let full = applied(entry.text, paragraphs: [line], caret: caret, scoped: nil)
                    let scoped = applied(entry.text, paragraphs: [line], caret: caret, scoped: [line])
                    #expect(full.attributedSubstring(from: line).isEqual(to: scoped.attributedSubstring(from: line)),
                            "\(entry.name) line \(line) caret \(caret)")
                }
            }
        }
    }

    /// The shape every caret move produces: the paragraph the caret entered plus
    /// the one it left. Both ends of the resulting item run can be truncated.
    @Test("two-region scopes match the full pass inside both regions")
    func disjointScopesMatchFullPass() {
        _ = NSApplication.shared
        for entry in Self.corpus {
            let all = lines(of: entry.text)
            guard all.count >= 3 else { continue }
            for i in all.indices {
                for j in all.indices where j > i + 1 {
                    let scope = [all[i], all[j]]
                    let full = applied(entry.text, paragraphs: scope, caret: -1, scoped: nil)
                    let scoped = applied(entry.text, paragraphs: scope, caret: -1, scoped: scope)
                    for region in scope {
                        #expect(full.attributedSubstring(from: region).isEqual(to: scoped.attributedSubstring(from: region)),
                                "\(entry.name) scope \(scope) region \(region)")
                    }
                }
            }
        }
    }
}
