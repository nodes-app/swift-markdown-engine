#if os(macOS)
//
//  NativeTextView+PasteHandling.swift
//  MarkdownEngine
//
//  Created by Luca Chen on 16.03.26.
//
//

import AppKit

extension NativeTextView {
    private static let pastableTextExtensions: Set<String> = [
        "md", "markdown", "mdown", "mkd", "txt", "text"
    ]

    override func paste(_ sender: Any?) {
        guard isEditable else {
            super.paste(sender)
            return
        }

        let pasteboard = NSPasteboard.general

        if let imageEmbed = onPasteImage?(pasteboard), !imageEmbed.isEmpty {
            insertBlockEmbed(imageEmbed)
            return
        }

        // Our own copy: prefer the private raw-markdown flavor so an in-app
        // copy→paste round-trips byte-exact. The derived HTML flavor is lossy
        // (e.g. the HTML renderer drops the `|UUID` of a wiki link), so this
        // must win over the HTML branch below.
        if let ownMarkdown = pasteboard.string(forType: MarkdownPasteboardWriter.markdownType) {
            let sanitized = sanitizePastedText(ownMarkdown)
            if !sanitized.isEmpty {
                insertPreservingBlockquote(sanitized)
                return
            }
        }

        // Rich paste: convert an HTML flavor (Claude, browsers, Word, Notion)
        // into Markdown so lists, headings, tables, and inline formatting
        // survive — the Obsidian-style incoming direction. Only run the
        // converter when the HTML actually carries block-level structure;
        // inline-only HTML (VS Code's per-line <div>s, a casually copied bold
        // word or link) would otherwise lose code indentation or gain stray
        // markdown, so we let it fall through to the clean plain-text flavor.
        if let html = pasteboard.string(forType: .html),
           Self.htmlHasBlockStructure(html),
           let markdown = HTMLToMarkdownConverter.markdown(fromHTML: html) {
            let sanitized = sanitizePastedText(markdown)
            if !sanitized.isEmpty {
                insertPreservingBlockquote(sanitized)
                return
            }
        }

        if let pasted = pasteboard.string(forType: .string) {
            let sanitized = sanitizePastedText(pasted)
            if !sanitized.isEmpty {
                insertPreservingBlockquote(sanitized)
                return
            }
        }

        if let fileText = textFromPastedFileURL(pasteboard: pasteboard) {
            let sanitized = sanitizePastedText(fileText)
            if !sanitized.isEmpty {
                insertPreservingBlockquote(sanitized)
                return
            }
        }

        pasteAsPlainText(sender)
    }

    /// Insert pasted content as its own coalescing-fenced undo step: the paste
    /// enters via `insertText` (the typing path), so without fences before and
    /// after, the next edit coalesces into it and one Cmd+Z reverts both.
    private func insertPasted(_ text: String, replacementRange: NSRange) {
        breakUndoCoalescing()
        insertText(text, replacementRange: replacementRange)
        undoManager?.setActionName("Paste")
        breakUndoCoalescing()
    }

    /// Insert pasted text, extending the `>` prefix to every line when the
    /// caret sits on a blockquote line — so a multi-line paste stays quoted
    /// instead of only its first line landing after the existing marker.
    private func insertPreservingBlockquote(_ text: String) {
        let sel = selectedRange()
        var prepared = MarkdownLists.blockquoteContinuedPaste(text, at: sel.location, in: string)
        // A paste ENDING in a table row would park the caret inside the table,
        // keeping its raw pipe source on screen. Add a line break so the caret
        // lands on a fresh line below and the table renders immediately.
        if endsInTableRow(prepared) { prepared += "\n" }
        insertPasted(prepared, replacementRange: sel)
    }

    /// Last line looks like a `|…|` table row and no newline follows it yet.
    private func endsInTableRow(_ text: String) -> Bool {
        guard !text.hasSuffix("\n"),
              let lastLine = text.split(separator: "\n", omittingEmptySubsequences: false).last
        else { return false }
        let t = lastLine.trimmingCharacters(in: .whitespaces)
        return t.count >= 3 && t.hasPrefix("|") && t.hasSuffix("|")
    }

    private func insertBlockEmbed(_ embed: String) {
        let sel = selectedRange()
        let nsText = string as NSString
        var prefix = ""
        var suffix = ""
        if sel.location > 0, nsText.character(at: sel.location - 1) != 0x0A {
            prefix = "\n"
        }
        let afterLocation = sel.location + sel.length
        if afterLocation < nsText.length, nsText.character(at: afterLocation) != 0x0A {
            suffix = "\n"
        }
        insertPasted(prefix + embed + suffix, replacementRange: sel)
    }

    /// Reads the textual content of a pasted markdown/text file URL — the
    /// fallback that makes iOS Universal Clipboard pastes useful.
    private func textFromPastedFileURL(pasteboard: NSPasteboard) -> String? {
        let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: nil) as? [URL] ?? []
        for url in urls where url.isFileURL {
            guard Self.pastableTextExtensions.contains(url.pathExtension.lowercased()) else { continue }
            if let s = try? String(contentsOf: url, encoding: .utf8) { return s }
            if let s = try? String(contentsOf: url) { return s }
        }
        return nil
    }

    private func sanitizePastedText(_ s: String) -> String {
        var out = s
        // Normalize pasted bullet glyphs (• ‣ ◦ ·) at line start to Markdown '- ' lists.
        if let bulletRegex = try? NSRegularExpression(pattern: #"^([ \t]*)[•‣◦·][ \t]+"#, options: [.anchorsMatchLines]) {
            let nsRange = NSRange(location: 0, length: (out as NSString).length)
            out = bulletRegex.stringByReplacingMatches(in: out, range: nsRange, withTemplate: "$1- ")
        }
        if let regex = try? NSRegularExpression(pattern: "\\n{3,}") {
            let nsRange = NSRange(location: 0, length: (out as NSString).length)
            out = regex.stringByReplacingMatches(in: out, range: nsRange, withTemplate: "\n\n")
        }
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    override func validateUserInterfaceItem(_ item: any NSValidatedUserInterfaceItem) -> Bool {
        if item.action == #selector(paste(_:)) {
            let pasteboard = NSPasteboard.general
            if PasteboardImageReader.canPasteImage(from: pasteboard) { return true }
            if textFromPastedFileURL(pasteboard: pasteboard) != nil { return true }
        }
        return super.validateUserInterfaceItem(item)
    }

    // MARK: - HTML structure guard

    /// True when `html` carries block-level structure worth converting to
    /// Markdown — a list, heading, table, blockquote, preformatted block, or
    /// horizontal rule. Inline-only markup (<div>/<span>/<b>/<i>/<a>/<p>) is not
    /// enough: converting it would mangle VS Code's per-line <div> code or turn
    /// a casually copied bold word / link into stray markdown, so those pastes
    /// should fall through to the clean plain-text flavor instead.
    static func htmlHasBlockStructure(_ html: String) -> Bool {
        // "li" included bare: Chromium serializes a within-list selection as
        // naked <li> elements without the ul/ol wrapper (Claude/ChatGPT copies).
        let blockTags = ["ul", "ol", "li", "h1", "h2", "h3", "h4", "h5", "h6",
                         "table", "blockquote", "pre", "hr"]
        for tag in blockTags where openingTagCount(html, tag, stopAfter: 1) > 0 {
            return true
        }
        // Formatted prose (chatbot / web / Word copy): several real paragraphs
        // plus inline formatting. A lone styled word/sentence (≤1 <p>) and
        // VS Code's div/span code (no <p> at all) stay on the plain-text path.
        let inlineTags = ["strong", "em", "b", "i", "code", "mark", "del", "s", "a", "u"]
        if openingTagCount(html, "p", stopAfter: 2) >= 2,
           inlineTags.contains(where: { openingTagCount(html, $0, stopAfter: 1) > 0 }) {
            return true
        }
        return false
    }

    /// Occurrences of an opening `<tag>` / `<tag …>` / `<tag/>` in `html`,
    /// case-insensitive. The boundary check keeps prefixes from matching
    /// (`<p` vs `<pre`, `<b` vs `<br>`, `<s` vs `<span`). Stops counting at
    /// `stopAfter` so callers pay only for the answer they need.
    private static func openingTagCount(_ html: String, _ tag: String, stopAfter: Int) -> Int {
        let needle = "<" + tag
        var count = 0
        var searchRange = html.startIndex..<html.endIndex
        while let r = html.range(of: needle, options: .caseInsensitive, range: searchRange) {
            if r.upperBound < html.endIndex {
                let c = html[r.upperBound]
                if c == ">" || c == "/" || c == " " || c == "\t" || c == "\n" || c == "\r" {
                    count += 1
                    if count >= stopAfter { return count }
                }
            }
            searchRange = r.upperBound..<html.endIndex
        }
        return count
    }
}
#endif
