//
//  MarkdownHTMLRenderer.swift
//  MarkdownEngine
//
//  Created by Luca Chen on 09.07.26.
//
//  A clean Markdown → HTML fragment renderer. The editor's NSTextStorage holds
//  RAW markdown styled in place (syntax markers merely colored, thematic breaks
//  drawn by a layout fragment, tables as image attachments), so the default copy
//  serializes junk. This walks the semantic `DocumentAST` and emits a clean HTML
//  fragment — a sequence of block elements, no <html>/<body> wrapper — that the
//  copy override wraps and places on the pasteboard.
//

import Foundation

public enum MarkdownHTMLRenderer {

    /// Render `markdown` to an HTML fragment (block elements joined by newlines).
    /// `extensions` render their spans (e.g. `<mark>` for highlight); an
    /// unregistered extension's syntax stays literal text.
    public static func html(from markdown: String, extensions: [any MarkdownExtension] = []) -> String {
        let ns = markdown as NSString
        let env = Env(registry: ExtensionRegistry(extensions: extensions),
                      byID: {
                          var out: [String: any MarkdownExtension] = [:]
                          for ext in extensions { out[ext.id] = ext }
                          return out
                      }())
        let blocks = DocumentAST.parse(markdown, registry: env.registry)
        let pieces = blocks.compactMap { block(for: $0, ns: ns, env: env) }
        return pieces.joined(separator: "\n")
    }

    /// Extension lookup threaded through the render walk.
    private struct Env {
        let registry: ExtensionRegistry
        let byID: [String: any MarkdownExtension]
        static let empty = Env(registry: .empty, byID: [:])
    }

    // MARK: - Blocks

    private static func block(for node: BlockNode, ns: NSString, env: Env) -> String? {
        switch node {
        case .heading(let level, _, _, let inlines):
            let l = min(max(level, 1), 6)
            return "<h\(l)>\(renderInlines(inlines, ns: ns, env: env))</h\(l)>"

        case .paragraph(_, let inlines):
            return "<p>\(renderInlines(inlines, ns: ns, env: env))</p>"

        case .blockquote(let range, _):
            return renderBlockquote(range: range, ns: ns, env: env)

        case .list(_, let items):
            return renderList(items: items, ns: ns, env: env)

        case .codeBlock(let range):
            return renderCodeBlock(range: range, ns: ns)

        case .blockLatex(let range):
            return "<pre>\(escape(ns.substring(with: range).trimmingCharacters(in: .newlines)))</pre>"

        case .table(let range):
            return renderTable(range: range, ns: ns)

        case .thematicBreak:
            return "<hr>"

        case .blank:
            return nil

        case .ext(let node):
            guard let ext = env.byID[node.extensionID] else {
                return "<p>\(escape(ns.substring(with: node.range).trimmingCharacters(in: .newlines)))</p>"
            }
            // Content lines are separate lines of one block — keep them as
            // <br> breaks so multi-line bodies don't collapse to one line.
            let inner = renderInlines(node.inlines, ns: ns, env: env)
                .trimmingCharacters(in: .newlines)
                .replacingOccurrences(of: "\n", with: "<br>\n")
            return ext.html(childrenHTML: inner)
        }
    }

    /// Blockquote inlines are parsed over the block range *including* the `> `
    /// markers, so strip the markers per line and re-parse the content clean.
    private static func renderBlockquote(range: NSRange, ns: NSString, env: Env) -> String {
        let raw = ns.substring(with: range)
        let stripped = raw
            .components(separatedBy: "\n")
            .map(stripQuoteMarkers)
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
        let inlines = InlineParser.parse(stripped, registry: env.registry)
        return "<blockquote>\(renderInlines(inlines, ns: stripped as NSString, env: env))</blockquote>"
    }

    /// Drop leading indent (≤3 spaces/tabs) then one-or-more `>` each with an
    /// optional trailing space, matching the block styler's marker scan.
    private static func stripQuoteMarkers(_ line: String) -> String {
        var s = Substring(line)
        var indent = 0
        while let c = s.first, c == " " || c == "\t", indent < 3 { s = s.dropFirst(); indent += 1 }
        while s.first == ">" {
            s = s.dropFirst()
            if s.first == " " || s.first == "\t" { s = s.dropFirst() }
        }
        return String(s)
    }

    /// Emit `<ul>`/`<ol>` groups, switching container when ordered-ness flips.
    /// Nesting is flattened to a single level for v1 (see deviations).
    private static func renderList(items: [ListItem], ns: NSString, env: Env) -> String {
        var out: [String] = []
        var currentOrdered: Bool?
        var buffer: [String] = []

        func flush() {
            guard let ordered = currentOrdered, !buffer.isEmpty else { return }
            let tag = ordered ? "ol" : "ul"
            out.append("<\(tag)>\n" + buffer.joined(separator: "\n") + "\n</\(tag)>")
            buffer.removeAll()
        }

        for item in items {
            if currentOrdered != item.ordered {
                flush()
                currentOrdered = item.ordered
            }
            buffer.append(listItem(item, ns: ns, env: env))
        }
        flush()
        return out.joined(separator: "\n")
    }

    private static func listItem(_ item: ListItem, ns: NSString, env: Env) -> String {
        let content = renderInlines(item.inlines, ns: ns, env: env)
        if item.checkbox != nil {
            // GFM task markup so markdown consumers (Obsidian etc.) restore
            // `- [ ]` on paste. Rich targets get this stripped to a plain
            // bullet by the pasteboard writer (user's call).
            let box = item.checked
                ? "<input type=\"checkbox\" checked disabled> "
                : "<input type=\"checkbox\" disabled> "
            return "<li>\(box)\(content)</li>"
        }
        return "<li>\(content)</li>"
    }

    /// Fenced code: drop the opening ```lang / closing ``` fence lines, escape body.
    private static func renderCodeBlock(range: NSRange, ns: NSString) -> String {
        let raw = ns.substring(with: range)
        var lines = raw.components(separatedBy: "\n")
        if lines.last == "" { lines.removeLast() }   // drop trailing-newline artifact

        let language = fenceLanguage(lines.first ?? "")
        var body = Array(lines.dropFirst())
        if let last = body.last, isFenceLine(last) { body.removeLast() }

        let escaped = escape(body.joined(separator: "\n"))
        if let language, !language.isEmpty {
            return "<pre><code class=\"language-\(escape(language))\">\(escaped)</code></pre>"
        }
        return "<pre><code>\(escaped)</code></pre>"
    }

    /// The parser only produces column-0 backtick fences (BlockParser.isFence),
    /// so match that contract when stripping the closing fence line.
    private static func isFenceLine(_ line: String) -> Bool {
        line.hasPrefix("```")
    }

    /// Language info-string from an opening fence line (chars after the backticks).
    private static func fenceLanguage(_ line: String) -> String? {
        let lang = line.drop { $0 == "`" }.trimmingCharacters(in: .whitespaces)
        return lang.isEmpty ? nil : lang
    }

    private static func renderTable(range: NSRange, ns: NSString) -> String {
        let raw = ns.substring(with: range)
        guard let parsed = MarkdownStyler.parseTableSource(raw) else {
            return "<pre>\(escape(raw.trimmingCharacters(in: .newlines)))</pre>"
        }
        let head = parsed.header.map { "<th>\(escape($0))</th>" }.joined()
        let body = parsed.rows.map { row in
            "<tr>" + row.map { "<td>\(escape($0))</td>" }.joined() + "</tr>"
        }.joined()
        return "<table><thead><tr>\(head)</tr></thead><tbody>\(body)</tbody></table>"
    }

    // MARK: - Inlines

    private static func renderInlines(_ nodes: [InlineNode], ns: NSString, env: Env) -> String {
        var out = ""
        for node in nodes { out += renderInline(node, ns: ns, env: env) }
        return out
    }

    private static func renderInline(_ node: InlineNode, ns: NSString, env: Env) -> String {
        switch node {
        case .text(let r):
            return escape(ns.substring(with: r))

        case .code(_, let content):
            return "<code>\(escape(ns.substring(with: content)))</code>"

        case .emphasis(let kind, _, _, let children):
            let inner = renderInlines(children, ns: ns, env: env)
            switch kind {
            case .italic:     return "<em>\(inner)</em>"
            case .bold:       return "<strong>\(inner)</strong>"
            case .boldItalic: return "<strong><em>\(inner)</em></strong>"
            }

        case .link(_, _, let url, _, let children):
            return "<a href=\"\(escape(ns.substring(with: url)))\">\(renderInlines(children, ns: ns, env: env))</a>"

        case .image(_, let alt, let url, _):
            return "<img src=\"\(escape(ns.substring(with: url)))\" alt=\"\(escape(ns.substring(with: alt)))\">"

        case .wikiLink(_, let name, _, _):
            return escape(ns.substring(with: name))

        case .imageEmbed(_, let target, _):
            let t = escape(ns.substring(with: target))
            return "<img src=\"\(t)\" alt=\"\(t)\">"

        case .ext(let node):
            guard let ext = env.byID[node.extensionID] else {
                return escape(ns.substring(with: node.range))   // unknown id → literal
            }
            let inner = node.children.isEmpty
                ? escape(ns.substring(with: node.contentRange))
                : renderInlines(node.children, ns: ns, env: env)
            return ext.html(childrenHTML: inner)

        case .inlineLatex(let range, _, _):
            return escape(ns.substring(with: range))

        case .escape(_, let character, _):
            return escape(ns.substring(with: character))
        }
    }

    // MARK: - Escaping

    private static func escape(_ s: String) -> String {
        var out = ""
        out.reserveCapacity(s.count)
        for ch in s {
            switch ch {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            default: out.append(ch)
            }
        }
        return out
    }
}
