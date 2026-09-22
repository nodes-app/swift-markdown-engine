//
//  BareHrefPolicyTests.swift
//  MarkdownEngineTests
//
//  The styler used to unconditionally prepend `https://` to any `[label](href)`
//  whose `href` did not already carry `://`, on the assumption that every href
//  is web-shaped. `LinkStyle.bareHrefs` lets an embedder opt out of the guess
//  when its hrefs are meaningful outside of the web (relative paths, opaque
//  ids, custom schemes registered elsewhere in the app). These tests pin the
//  default at the historical behavior and the opt-out at end-to-end pass-through.
//

import AppKit
import Foundation
import Testing
@testable import MarkdownEngine

@MainActor
@Suite("LinkStyle.bareHrefs")
struct BareHrefPolicyTests {

    private let base: CGFloat = 14
    private var fontName: String { NSFont.systemFont(ofSize: 14).fontName }

    /// The `.link` NSAttributedString attribute the styler emits for the label
    /// range of a link. Returns nil if no link ran there.
    private func linkURL(in attrs: [StyledRange], covering location: Int) -> URL? {
        for (range, dict) in attrs {
            if NSLocationInRange(location, range), let url = dict[.link] as? URL {
                return url
            }
        }
        return nil
    }

    @Test("default preserves the historical https:// prepend for a bare href")
    func defaultPolicyPrependsHTTPS() {
        let text = "[docs](docs/)"
        let attrs = MarkdownASTStyler.styleAttributes(
            text: text, fontName: fontName, fontSize: base,
            configuration: .default
        )
        // Label starts after the `[`, so the .link attribute sits at index 1.
        let url = linkURL(in: attrs, covering: 1)
        #expect(url?.absoluteString == "https://docs/")
    }

    @Test("default leaves a scheme-carrying href alone")
    func defaultPolicyLeavesSchemeHrefAlone() {
        let text = "[docs](https://example.com/docs)"
        let attrs = MarkdownASTStyler.styleAttributes(
            text: text, fontName: fontName, fontSize: base,
            configuration: .default
        )
        let url = linkURL(in: attrs, covering: 1)
        #expect(url?.absoluteString == "https://example.com/docs")
    }

    @Test("preserveAsWritten hands the source href through untouched")
    func preserveAsWrittenHandsSourceHrefThrough() {
        let text = "[docs](docs/)"
        var config = MarkdownEditorConfiguration.default
        config.link = LinkStyle(bareHrefs: .preserveAsWritten)
        let attrs = MarkdownASTStyler.styleAttributes(
            text: text, fontName: fontName, fontSize: base,
            configuration: config
        )
        let url = linkURL(in: attrs, covering: 1)
        // No prepend: the URL is exactly the source href, and stays relative.
        #expect(url?.absoluteString == "docs/")
    }

    @Test("preserveAsWritten still passes through a scheme-carrying href unchanged")
    func preserveAsWrittenLeavesSchemeHrefAlone() {
        let text = "[docs](https://example.com/docs)"
        var config = MarkdownEditorConfiguration.default
        config.link = LinkStyle(bareHrefs: .preserveAsWritten)
        let attrs = MarkdownASTStyler.styleAttributes(
            text: text, fontName: fontName, fontSize: base,
            configuration: config
        )
        let url = linkURL(in: attrs, covering: 1)
        #expect(url?.absoluteString == "https://example.com/docs")
    }
}
