#if os(macOS)
//
//  HTMLToMarkdownConverter.swift
//  MarkdownEngine
//
//  Created by Luca Chen on 09.07.26.
//

import Foundation

/// A lenient HTML→Markdown converter for the editor's smart-paste path.
///
/// Real-world clipboard HTML (from Claude, browsers, Word, Notion) is messy:
/// inline styles, stray `<span>`/`<div>`/`<meta>` wrappers, mixed-case tags,
/// and sometimes unclosed elements. This converter does NOT assume well-formed
/// XML — it runs a tolerant tag scanner with a small nesting stack, unwraps
/// unknown/styling-only tags, decodes entities, and collapses insignificant
/// whitespace. It prefers robustness over completeness.
///
/// Returns `nil` when the input has no convertible structure (no tags), so the
/// caller can fall back to the plain-text flavor.
enum HTMLToMarkdownConverter {

    static func markdown(fromHTML html: String) -> String? {
        var sawTag = false
        let root = parse(html, sawTag: &sawTag)
        guard sawTag else { return nil }
        let rendered = renderBlocks(root.children).htmlTrimmed
        return rendered.isEmpty ? nil : rendered
    }

    // MARK: - DOM

    private final class Node {
        let name: String            // "" for a text node, "#root" for the root
        var attrs: [String: String]
        var children: [Node] = []
        var text: String

        init(name: String, attrs: [String: String] = [:], text: String = "") {
            self.name = name
            self.attrs = attrs
            self.text = text
        }

        var isText: Bool { name.isEmpty }
    }

    private static let voidElements: Set<String> = [
        "br", "hr", "img", "input", "meta", "link", "source",
        "col", "area", "base", "wbr", "embed", "param", "track"
    ]

    // MARK: - Lenient parse

    private static func parse(_ html: String, sawTag: inout Bool) -> Node {
        let root = Node(name: "#root")
        var stack = [root]
        let chars = Array(html)
        let n = chars.count
        var i = 0

        func top() -> Node { stack[stack.count - 1] }
        func appendText(_ s: String) {
            if !s.isEmpty { top().children.append(Node(name: "", text: s)) }
        }

        while i < n {
            if chars[i] == "<" {
                // HTML comment: skip through "-->"
                if hasPrefix(chars, at: i, "<!--") {
                    var j = i + 4
                    while j + 2 < n, !(chars[j] == "-" && chars[j + 1] == "-" && chars[j + 2] == ">") {
                        j += 1
                    }
                    i = (j + 2 < n) ? j + 3 : n
                    continue
                }
                // Doctype / processing instruction: skip to ">"
                if i + 1 < n, chars[i + 1] == "!" || chars[i + 1] == "?" {
                    var j = i + 1
                    while j < n, chars[j] != ">" { j += 1 }
                    i = (j < n) ? j + 1 : n
                    continue
                }
                // Generic tag: read to the next ">"
                var j = i + 1
                while j < n, chars[j] != ">" { j += 1 }
                if j >= n {
                    // Unclosed "<": treat the remainder as literal text.
                    appendText(decodeHTMLEntities(String(chars[i..<n])))
                    break
                }
                let inner = String(chars[(i + 1)..<j])
                i = j + 1
                sawTag = true

                if inner.hasPrefix("/") {
                    let name = tagName(String(inner.dropFirst()))
                    if let idx = stack.lastIndex(where: { $0.name == name }), idx >= 1 {
                        stack.removeSubrange(idx...)
                    }
                } else {
                    let selfClose = inner.hasSuffix("/")
                    let body = selfClose ? String(inner.dropLast()) : inner
                    let name = tagName(body)
                    let node = Node(name: name, attrs: parseAttrs(body, name: name))
                    top().children.append(node)
                    if !selfClose && !voidElements.contains(name) {
                        stack.append(node)
                    }
                }
            } else {
                var j = i
                while j < n, chars[j] != "<" { j += 1 }
                appendText(decodeHTMLEntities(String(chars[i..<j])))
                i = j
            }
        }
        return root
    }

    private static func hasPrefix(_ chars: [Character], at i: Int, _ prefix: String) -> Bool {
        let p = Array(prefix)
        guard i + p.count <= chars.count else { return false }
        for k in 0..<p.count where chars[i + k] != p[k] { return false }
        return true
    }

    /// Leading tag name (letters/digits until whitespace or "/"), lowercased.
    private static func tagName(_ body: String) -> String {
        var name = ""
        for ch in body {
            if ch.isWhitespace || ch == "/" { break }
            name.append(ch)
        }
        return name.lowercased()
    }

    private static let attrRegex = try! NSRegularExpression(
        pattern: #"([a-zA-Z_:][-a-zA-Z0-9_:.]*)\s*(?:=\s*(?:"([^"]*)"|'([^']*)'|([^\s>]+)))?"#
    )

    private static func parseAttrs(_ body: String, name: String) -> [String: String] {
        let rest = String(body.dropFirst(name.count))
        guard !rest.isEmpty else { return [:] }
        let ns = rest as NSString
        var attrs: [String: String] = [:]
        for m in attrRegex.matches(in: rest, range: NSRange(location: 0, length: ns.length)) {
            let key = ns.substring(with: m.range(at: 1)).lowercased()
            var value = ""
            for group in 2...4 where m.range(at: group).location != NSNotFound {
                value = ns.substring(with: m.range(at: group))
                break
            }
            attrs[key] = decodeHTMLEntities(value)
        }
        return attrs
    }

    // MARK: - Block rendering

    private static func renderBlocks(_ children: [Node]) -> String {
        var blocks: [String] = []
        var inlineBuffer = ""
        // Consecutive bare <li> siblings (Chromium strips the ul/ol wrapper on
        // within-list copies) — collected into ONE tight list, not \n\n-spaced.
        var looseItems: [String] = []

        func flushInline() {
            let trimmed = inlineBuffer.htmlTrimmed
            if !trimmed.isEmpty { blocks.append(trimmed) }
            inlineBuffer = ""
        }
        func flushItems() {
            if !looseItems.isEmpty {
                blocks.append(looseItems.joined(separator: "\n"))
                looseItems = []
            }
        }

        for child in children {
            if child.isText {
                // Whitespace between bare <li> siblings must not split the run.
                if !looseItems.isEmpty,
                   child.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    continue
                }
                flushItems()
                inlineBuffer += renderInlineNode(child)
                continue
            }
            if child.name == "li" {
                flushInline()
                looseItems.append(renderListItem(child, ordered: false, number: 1, depth: 0))
                continue
            }
            flushItems()
            if let block = renderBlock(child) {
                flushInline()
                if !block.isEmpty { blocks.append(block) }
            } else {
                inlineBuffer += renderInlineNode(child)
            }
        }
        flushInline()
        flushItems()
        return blocks.joined(separator: "\n\n")
    }

    /// Renders a block-level element, or returns `nil` when `node` is not a
    /// block (so the caller folds it into the surrounding inline paragraph).
    private static func renderBlock(_ node: Node) -> String? {
        switch node.name {
        case "h1", "h2", "h3", "h4", "h5", "h6":
            let level = Int(node.name.dropFirst()) ?? 1
            return String(repeating: "#", count: level) + " "
                + renderInlineChildren(node.children).htmlTrimmed
        case "p":
            return renderInlineChildren(node.children).htmlTrimmed
        case "hr":
            return "----"
        case "ul":
            return renderList(node, ordered: false, depth: 0)
        case "ol":
            return renderList(node, ordered: true, depth: 0)
        case "blockquote":
            let inner = renderBlocks(node.children)
            let lines = inner.components(separatedBy: "\n").map { $0.isEmpty ? ">" : "> " + $0 }
            return lines.joined(separator: "\n")
        case "pre":
            return renderPre(node)
        case "table":
            return renderTable(node)
        case "div":
            return renderBlocks(node.children)
        case "html", "body":
            // Some sources (GPT, CF_HTML exporters) put a full document on the
            // clipboard; without these cases the wrapper fell into the inline
            // unwrap and glued every block's text into one run.
            return renderBlocks(node.children)
        case "head", "style", "script", "title":
            return ""   // metadata / code-for-the-browser — never content
        default:
            return nil
        }
    }

    private static func renderList(_ node: Node, ordered: Bool, depth: Int) -> String {
        var items: [String] = []
        var number = 0
        if ordered, let start = node.attrs["start"], let seed = Int(start) {
            number = seed - 1
        }
        for child in node.children where child.name == "li" {
            number += 1
            items.append(renderListItem(child, ordered: ordered, number: number, depth: depth))
        }
        return items.joined(separator: "\n")
    }

    private static func renderListItem(_ li: Node, ordered: Bool, number: Int, depth: Int) -> String {
        // One TAB per nesting level — the editor's native indent unit; two
        // spaces would parse as a level but render barely indented (~7pt).
        let indent = String(repeating: "\t", count: depth)

        var marker: String
        if let box = findCheckbox(li) {
            marker = isChecked(box) ? "- [x] " : "- [ ] "
        } else {
            marker = ordered ? "\(number). " : "- "
        }

        // Walk the item's children, keeping the leading inline run as the head
        // line, block children (paragraphs, etc.) as indented continuation
        // blocks, and lists as nested lists. A <div> is a transparent wrapper.
        var head = ""
        var headSet = false
        var blocks: [String] = []        // non-list continuation blocks
        var nestedLists: [String] = []   // already carry their depth+1 indent
        var inlineRun: [Node] = []

        func flushInline() {
            guard !inlineRun.isEmpty else { return }
            let rendered = renderInlineChildren(inlineRun).htmlTrimmed
            inlineRun.removeAll()
            guard !rendered.isEmpty else { return }
            if !headSet { head = rendered; headSet = true } else { blocks.append(rendered) }
        }

        func walk(_ children: [Node]) {
            for child in children {
                switch child.name {
                case "ul", "ol":
                    flushInline()
                    let sub = renderList(child, ordered: child.name == "ol", depth: depth + 1)
                    if !sub.isEmpty { nestedLists.append(sub) }
                case "div":
                    walk(child.children)
                case "p", "blockquote", "pre", "table", "hr",
                     "h1", "h2", "h3", "h4", "h5", "h6":
                    flushInline()
                    if let block = renderBlock(child), !block.isEmpty { blocks.append(block) }
                default:
                    inlineRun.append(child)
                }
            }
        }
        walk(li.children)
        flushInline()
        if !headSet, !blocks.isEmpty {
            head = blocks.removeFirst()
            headSet = true
        }

        // Chat UIs (Claude) render task lists as literal "[ ] text" in plain
        // <li>s; the text escaping turned that into "\[ \] ", which never
        // re-renders as a checkbox. Reclaim the escaped prefix as a real
        // task marker.
        if findCheckbox(li) == nil, !ordered {
            if head.hasPrefix("\\[ \\] ") {
                marker = "- [ ] "
                head = String(head.dropFirst(6))
            } else if head.hasPrefix("\\[x\\] ") || head.hasPrefix("\\[X\\] ") {
                marker = "- [x] "
                head = String(head.dropFirst(6))
            }
        }
        // Continuation lines align under the item's text (past the marker).
        let contIndent = indent + String(repeating: " ", count: marker.count)

        // First line: marker + head; re-indent any embedded (hard-break) newline
        // so the continuation stays inside the item.
        let headLines = head.components(separatedBy: "\n")
        var line = indent + marker + (headLines.first ?? "")
        for extra in headLines.dropFirst() {
            line += "\n" + (extra.isEmpty ? "" : contIndent + extra)
        }
        for block in blocks {
            line += "\n\n" + indentLines(block, by: contIndent)
        }
        for nested in nestedLists {
            line += "\n" + nested
        }
        return line
    }

    private static func indentLines(_ s: String, by prefix: String) -> String {
        s.components(separatedBy: "\n")
            .map { $0.isEmpty ? "" : prefix + $0 }
            .joined(separator: "\n")
    }

    private static func renderPre(_ node: Node) -> String {
        let source = firstDescendant(node, named: "code") ?? node
        var language = ""
        if let cls = source.attrs["class"] {
            for token in cls.split(separator: " ") where token.hasPrefix("language-") {
                language = String(token.dropFirst("language-".count))
                break
            }
        }
        var code = rawText(source)
        if code.hasPrefix("\n") { code.removeFirst() }
        if code.hasSuffix("\n") { code.removeLast() }
        return "```\(language)\n\(code)\n```"
    }

    private static func renderTable(_ node: Node) -> String {
        let trs = descendants(node, named: "tr")
        var rows: [[String]] = []
        for tr in trs {
            var cells: [String] = []
            for cell in tr.children where cell.name == "td" || cell.name == "th" {
                let text = renderInlineChildren(cell.children).htmlTrimmed
                    .replacingOccurrences(of: "|", with: #"\|"#)
                    .replacingOccurrences(of: "\n", with: " ")
                cells.append(text)
            }
            if !cells.isEmpty { rows.append(cells) }
        }
        guard !rows.isEmpty else { return "" }

        let columns = rows.map(\.count).max() ?? 0
        guard columns > 0 else { return "" }
        func pad(_ row: [String]) -> [String] {
            row + Array(repeating: "", count: max(0, columns - row.count))
        }

        var lines: [String] = []
        lines.append("| " + pad(rows[0]).joined(separator: " | ") + " |")
        lines.append("|" + Array(repeating: "---", count: columns).joined(separator: "|") + "|")
        for row in rows.dropFirst() {
            lines.append("| " + pad(row).joined(separator: " | ") + " |")
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - Inline rendering

    private static func renderInlineChildren(_ children: [Node]) -> String {
        children.map(renderInlineNode).joined()
    }

    private static func renderInlineNode(_ node: Node) -> String {
        if node.isText { return escapeMarkdown(collapseWhitespace(node.text)) }
        switch node.name {
        case "strong", "b":
            return "**" + renderInlineChildren(node.children) + "**"
        case "em", "i":
            return "*" + renderInlineChildren(node.children) + "*"
        case "del", "s", "strike":
            return "~~" + renderInlineChildren(node.children) + "~~"
        case "mark":
            return "==" + renderInlineChildren(node.children) + "=="
        case "code":
            return "`" + rawText(node) + "`"
        case "br":
            return "  \n"   // CommonMark hard break
        case "a":
            let inner = renderInlineChildren(node.children)
            let href = node.attrs["href"] ?? ""
            return href.isEmpty ? inner : "[\(inner)](\(formatLinkDestination(href)))"
        case "input":
            return ""   // checkboxes are handled at the list-item level
        case "head", "style", "script", "title":
            return ""   // metadata / code-for-the-browser — unwrapping would leak CSS/JS as text
        default:
            // Unknown / styling-only tags (span, font, sup, etc.) → unwrap.
            return renderInlineChildren(node.children)
        }
    }

    /// Backslash-escapes markdown-significant characters in a TEXT node so pasted
    /// literal text does not re-parse as markdown. Conservative: only a leading
    /// block marker at the start of the run, plus inline emphasis/code/link
    /// delimiters, are escaped. Code spans/fences bypass this (they use rawText).
    private static func escapeMarkdown(_ s: String) -> String {
        guard !s.isEmpty else { return s }
        let chars = Array(s)
        var out = ""
        var i = 0

        // Leading block marker (treat the run's start as a potential line start).
        if chars[0] == "#" {
            var hashes = 0
            while hashes < chars.count, hashes < 6, chars[hashes] == "#" { hashes += 1 }
            if hashes < chars.count, chars[hashes] == " " {
                out.append("\\#")
                i = 1
            }
        } else if chars[0] == ">" {
            out.append("\\>")
            i = 1
        } else if chars[0] == "-" || chars[0] == "*" || chars[0] == "+" {
            if chars.count > 1, chars[1] == " " {
                out.append("\\")
                out.append(chars[0])
                i = 1
            }
        } else if chars[0].isNumber {
            var d = 0
            while d < chars.count, chars[d].isNumber { d += 1 }
            if d < chars.count, chars[d] == "." || chars[d] == ")",
               d + 1 == chars.count || chars[d + 1] == " " {
                for k in 0..<d { out.append(chars[k]) }
                out.append("\\")
                out.append(chars[d])
                i = d + 1
            }
        }

        // Inline delimiters, anywhere in the run.
        while i < chars.count {
            let c = chars[i]
            switch c {
            case "*", "_", "`", "[", "]":
                out.append("\\")
                out.append(c)
            default:
                out.append(c)
            }
            i += 1
        }
        return out
    }

    /// Formats a link/image destination. Angle-wraps it when it contains
    /// whitespace or unbalanced parentheses, which would otherwise break the
    /// `(dest)` syntax; leaves clean destinations bare.
    private static func formatLinkDestination(_ href: String) -> String {
        let hasWhitespace = href.contains { $0.isWhitespace }
        var depth = 0
        var balanced = true
        for c in href {
            if c == "(" {
                depth += 1
            } else if c == ")" {
                depth -= 1
                if depth < 0 { balanced = false; break }
            }
        }
        if depth != 0 { balanced = false }
        guard hasWhitespace || !balanced else { return href }
        let safe = href
            .replacingOccurrences(of: "<", with: "%3C")
            .replacingOccurrences(of: ">", with: "%3E")
        return "<\(safe)>"
    }

    // MARK: - Tree helpers

    private static func findCheckbox(_ node: Node) -> Node? {
        for child in node.children {
            if child.name == "input", child.attrs["type"]?.lowercased() == "checkbox" {
                return child
            }
            if let found = findCheckbox(child) { return found }
        }
        return nil
    }

    private static func isChecked(_ input: Node) -> Bool {
        guard let value = input.attrs["checked"] else { return false }
        return value.isEmpty || value.lowercased() == "checked" || value.lowercased() == "true"
    }

    private static func firstDescendant(_ node: Node, named name: String) -> Node? {
        for child in node.children {
            if child.name == name { return child }
            if let found = firstDescendant(child, named: name) { return found }
        }
        return nil
    }

    private static func descendants(_ node: Node, named name: String) -> [Node] {
        var result: [Node] = []
        for child in node.children {
            if child.name == name { result.append(child) }
            result.append(contentsOf: descendants(child, named: name))
        }
        return result
    }

    /// Concatenates the raw (un-collapsed) text of a node's subtree — used for
    /// code spans and fenced blocks where whitespace is significant.
    private static func rawText(_ node: Node) -> String {
        if node.isText { return node.text }
        return node.children.map(rawText).joined()
    }

    // MARK: - Whitespace & entities

    /// Collapses runs of insignificant whitespace to a single space, preserving
    /// a single leading/trailing space so inline runs stay separated.
    private static func collapseWhitespace(_ s: String) -> String {
        var out = ""
        var pendingSpace = false
        for ch in s {
            if ch.isWhitespace {
                pendingSpace = true
                continue
            }
            if pendingSpace {
                out.append(" ")
                pendingSpace = false
            }
            out.append(ch)
        }
        if pendingSpace { out.append(" ") }
        return out
    }

    private static let namedEntities: [String: String] = [
        "nbsp": " ", "lt": "<", "gt": ">", "quot": "\"",
        "apos": "'", "amp": "&"
    ]

    /// Decodes named entities plus numeric (`&#NNN;`) and hex (`&#xHH;`/`&#XHH;`)
    /// character references. Malformed or unknown references are left verbatim.
    private static func decodeHTMLEntities(_ s: String) -> String {
        guard s.contains("&") else { return s }
        let chars = Array(s)
        let n = chars.count
        var out = ""
        var i = 0
        while i < n {
            guard chars[i] == "&", let semi = findSemicolon(chars, from: i + 1, max: 32) else {
                out.append(chars[i])
                i += 1
                continue
            }
            let entity = String(chars[(i + 1)..<semi])
            if entity.hasPrefix("#") {
                let numPart = entity.dropFirst()
                let value: UInt32?
                if let first = numPart.first, first == "x" || first == "X" {
                    value = UInt32(numPart.dropFirst(), radix: 16)
                } else {
                    value = UInt32(numPart)
                }
                if let value, let scalar = Unicode.Scalar(value) {
                    out.append(Character(scalar))
                    i = semi + 1
                    continue
                }
            } else if let rep = namedEntities[entity] ?? namedEntities[entity.lowercased()] {
                out.append(rep)
                i = semi + 1
                continue
            }
            out.append(chars[i])
            i += 1
        }
        return out
    }

    /// Index of the next `;` within `max` characters, or `nil` if a stray `&`/`<`
    /// (which cannot appear inside a well-formed reference) is hit first.
    private static func findSemicolon(_ chars: [Character], from: Int, max: Int) -> Int? {
        var j = from
        let limit = Swift.min(chars.count, from + max)
        while j < limit {
            if chars[j] == ";" { return j }
            if chars[j] == "&" || chars[j] == "<" { return nil }
            j += 1
        }
        return nil
    }
}

private extension String {
    var htmlTrimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}
#endif
