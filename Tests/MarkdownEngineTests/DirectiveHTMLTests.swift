//
//  DirectiveHTMLTests.swift
//  MarkdownEngineTests
//
//  The clean-copy path for directives. Arguments are recovered from the same
//  prefix geometry the styler uses, so what gets copied can't disagree with
//  what was on screen.
//

import AppKit
import Foundation
import Testing
@testable import MarkdownEngine

@Suite("Directives — HTML")
struct DirectiveHTMLTests {

    private let directives: [any MarkdownDirective] = [
        FontDirective(), ColorDirective(), MarkerDirective(),
    ]

    private func html(_ markdown: String) -> String {
        MarkdownHTMLRenderer.html(from: markdown, directives: directives)
    }

    @Test("a container directive wraps its body")
    func containerWraps() {
        #expect(html("@font(size: 18){hello}").contains("font-size:18.0px"))
        #expect(html("@font(size: 18){hello}").contains(">hello<"))
    }

    @Test("body markup renders inside the wrapper")
    func bodyMarkupRenders() {
        #expect(html("@font(size: 18){**bold**}").contains("<strong>bold</strong>"))
    }

    @Test("a self-contained directive renders its own markup")
    func selfContainedRenders() {
        #expect(html("@marker").contains("<hr class=\"marker\" />"))
    }

    @Test("a directive with no styling arguments still emits its body")
    func noArgumentsStillEmitsBody() {
        #expect(html("@font(){hello}").contains("hello"))
    }

    @Test("nested directives nest in the output")
    func nestedDirectives() {
        let out = html("@font(size: 18){@font(weight: bold){x}}")
        #expect(out.contains("font-size:18.0px"))
        #expect(out.contains("font-weight:bold"))
    }

    @Test("without registration the source copies literally")
    func unregisteredCopiesLiterally() {
        let out = MarkdownHTMLRenderer.html(from: "@font(size: 18){hello}")
        #expect(out.contains("@font(size: 18){hello}"))
    }

    @Test("registering directives does not disturb ordinary markdown")
    func ordinaryMarkdownUnchanged() {
        let markdown = "# Title\n\nSome **bold** and a [link](https://example.com).\n"
        #expect(html(markdown) == MarkdownHTMLRenderer.html(from: markdown))
    }

    @Test("an extension and a directive coexist in one render")
    func extensionsAndDirectivesCoexist() {
        let out = MarkdownHTMLRenderer.html(
            from: "==hi== and @font(size: 18){there}",
            extensions: [HighlightExtension()],
            directives: directives
        )
        #expect(out.contains("<mark>hi</mark>"))
        #expect(out.contains("font-size:18.0px"))
    }
}
