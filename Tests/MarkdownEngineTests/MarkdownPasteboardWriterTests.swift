//
//  MarkdownPasteboardWriterTests.swift
//  MarkdownEngine
//
//  Created by Luca Chen on 11.07.26.
//
//  The web archive must carry OUR html verbatim (deriving it from
//  NSAttributedString(html:) dropped <hr> and checkboxes), and the RTF path
//  substitutes visible stand-ins for what RTF cannot represent.
//

import AppKit
import Foundation
import Testing
@testable import MarkdownEngine

@Suite("Pasteboard writer flavors")
struct MarkdownPasteboardWriterTests {

    @Test("web archive wraps our html verbatim as its main resource")
    func webArchiveCarriesRealHTML() throws {
        let html = "<html><body><p>a</p><hr><li><input type=\"checkbox\" disabled> t</li></body></html>"
        let data = try #require(MarkdownPasteboardWriter.webArchiveData(html: html))
        let plist = try #require(try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        let main = try #require(plist["WebMainResource"] as? [String: Any])
        #expect(main["WebResourceMIMEType"] as? String == "text/html")
        let payload = try #require(main["WebResourceData"] as? Data)
        let roundTripped = try #require(String(data: payload, encoding: .utf8))
        #expect(roundTripped == html)   // <hr> and the checkbox survive untouched
    }

    @Test("rich flavors strip checkbox inputs to plain bullets")
    func stripCheckboxes() {
        let body = "<ul>\n<li><input type=\"checkbox\" disabled> open</li>\n<li><input type=\"checkbox\" checked disabled> done</li>\n</ul>"
        #expect(MarkdownPasteboardWriter.stripTaskCheckboxes(body) == "<ul>\n<li>open</li>\n<li>done</li>\n</ul>")
    }

    @Test("rtf stand-in: hr becomes a 40-char rule")
    func rtfFallbackRule() {
        let rule = String(repeating: "─", count: 40)
        #expect(MarkdownPasteboardWriter.rtfFallbackBody("<p>a</p>\n<hr>\n<p>b</p>")
            == "<p>a</p>\n<p>\(rule)</p>\n<p>b</p>")
    }

    @Test("bare URL reaches the rich flavors as a real link (Mail/Outlook run no detection of their own)")
    @MainActor
    func bareURLRichFlavorsCarryAnchor() throws {
        let pb = NSPasteboard(name: NSPasteboard.Name("MarkdownPasteboardWriterTests.bareURL"))
        MarkdownPasteboardWriter.write(markdown: "https://example.com", to: pb)

        let html = try #require(pb.string(forType: .html))
        #expect(html.contains("<a href=\"https://example.com\">https://example.com</a>"))

        // The RTF flavor is derived from that HTML; the anchor must come out
        // the other side as an RTF hyperlink field, not styled plain text.
        let rtf = try #require(pb.data(forType: .rtf))
        let rtfSource = try #require(String(data: rtf, encoding: .isoLatin1))
        #expect(rtfSource.contains("HYPERLINK"))
        #expect(rtfSource.contains("example.com"))
    }
}
