//
//  MarkdownPasteboardWriter.swift
//  MarkdownEngine
//
//  Created by Luca Chen on 09.07.26.
//
//  Writes a clean, multi-flavor representation of a raw markdown selection to
//  an NSPasteboard. The editor's storage holds RAW markdown styled in place,
//  so a default copy leaks syntax markers and drops thematic breaks. Here we
//  render the raw markdown to clean HTML, write it as web archive + HTML,
//  derive RTF with visible stand-ins for constructs RTF cannot carry, and
//  keep the raw markdown itself as the plain-text flavor.
//

import AppKit

enum MarkdownPasteboardWriter {
    /// Private flavor carrying the exact raw markdown of the selection. When one
    /// of our own editors pastes, it prefers this over the derived HTML so wiki
    /// links (`[[Name|UUID]]`), code, and every other construct round-trip
    /// byte-exact instead of being re-derived from the lossy HTML flavor.
    static let markdownType = NSPasteboard.PasteboardType("dev.markdownengine.raw-markdown")

    @MainActor
    static func write(markdown: String, to pasteboard: NSPasteboard,
                      extensions: [any MarkdownExtension] = []) {
        pasteboard.clearContents()

        // Always keep the raw markdown available as plain text.
        pasteboard.setString(markdown, forType: .string)

        // Also keep the exact raw markdown under our private flavor so our own
        // paste path can round-trip it losslessly.
        pasteboard.setString(markdown, forType: Self.markdownType)

        // Render the selection to clean HTML.
        let htmlBody = MarkdownHTMLRenderer.html(from: markdown, extensions: extensions)
        // Rich targets (web archive + RTF) show task items as plain bullets
        // (user's call); the .html flavor keeps the GFM checkbox markup so
        // markdown apps (Obsidian etc.) restore `- [ ]` on paste.
        let richBody = stripTaskCheckboxes(htmlBody)
        let fullHTML = "<html><head><meta charset=\"utf-8\"></head><body>\(htmlBody)</body></html>"
        let richHTML = "<html><head><meta charset=\"utf-8\"></head><body>\(richBody)</body></html>"

        // Web archive built straight from OUR html — deriving it from
        // NSAttributedString(html:) silently dropped <hr>, so WebKit-reading
        // consumers get the real document instead.
        if let web = webArchiveData(html: richHTML) {
            pasteboard.setData(web, forType: NSPasteboard.PasteboardType("com.apple.webarchive"))
        }
        pasteboard.setData(Data(fullHTML.utf8), forType: .html)

        // RTF for consumers without web-archive support. RTF has no horizontal
        // rule and the HTML importer drops it, so convert a body with a
        // visible ─ stand-in on the main thread.
        let rtfHTML = "<html><head><meta charset=\"utf-8\"></head><body>\(rtfFallbackBody(richBody))</body></html>"
        if let data = rtfHTML.data(using: .utf8),
           let attr = try? NSAttributedString(
               data: data,
               options: [
                   .documentType: NSAttributedString.DocumentType.html,
                   .characterEncoding: String.Encoding.utf8.rawValue,
               ],
               documentAttributes: nil
           ),
           let rtf = try? attr.data(
               from: NSRange(location: 0, length: attr.length),
               documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]
           ) {
            pasteboard.setData(rtf, forType: .rtf)
        }
    }

    /// Stand-in for what RTF can't carry: the Cocoa HTML importer drops `<hr>`,
    /// so substitute a line of U+2500 (glyphs connect edge-to-edge); 40 chars
    /// reads full-width yet never wraps in ~72-char columns.
    static func rtfFallbackBody(_ body: String) -> String {
        body.replacingOccurrences(of: "<hr>", with: "<p>\(rtfRuleStandIn)</p>")
    }

    /// The visible horizontal-rule stand-in for the RTF flavor.
    static let rtfRuleStandIn = String(repeating: "─", count: 40)

    /// Rich targets show task items as plain bullets: drop the GFM checkbox
    /// inputs the renderer emits (the .html flavor keeps them).
    static func stripTaskCheckboxes(_ body: String) -> String {
        body
            .replacingOccurrences(of: "<input type=\"checkbox\" checked disabled> ", with: "")
            .replacingOccurrences(of: "<input type=\"checkbox\" disabled> ", with: "")
    }

    /// A minimal Safari-style web archive with `html` as its main resource.
    static func webArchiveData(html: String) -> Data? {
        let resource: [String: Any] = [
            "WebResourceData": Data(html.utf8),
            "WebResourceMIMEType": "text/html",
            "WebResourceTextEncodingName": "UTF-8",
            "WebResourceURL": "about:blank",
        ]
        return try? PropertyListSerialization.data(
            fromPropertyList: ["WebMainResource": resource],
            format: .binary,
            options: 0
        )
    }
}
