//
//  LinkTextAttributesTests.swift
//  MarkdownEngineTests
//
//  `NSTextView.linkTextAttributes` layers over every `.link` range at
//  display time, so a theme's `link` color emitted upstream is repainted
//  by AppKit's stock `.linkColor` blue unless the wrapper carries the
//  theme through this attribute too. These tests pin the default at
//  AppKit's stock look and a custom theme at the color it configures.
//

import AppKit
import Testing
@testable import MarkdownEngine

@Suite("Theme.linkTextAttributes")
struct LinkTextAttributesTests {

    @Test("default theme matches AppKit's stock link look")
    func defaultThemeMatchesAppKitStock() {
        let attrs = MarkdownEditorTheme.default.linkTextAttributes
        #expect(attrs[.foregroundColor] as? NSColor == .linkColor)
        #expect(attrs[.underlineStyle] as? Int == NSUnderlineStyle.single.rawValue)
        #expect(attrs[.cursor] as? NSCursor == NSCursor.pointingHand)
    }

    @Test("a custom link color reaches linkTextAttributes")
    func customLinkColorReachesLinkTextAttributes() {
        let theme = MarkdownEditorTheme(link: .white)
        let attrs = theme.linkTextAttributes
        #expect(attrs[.foregroundColor] as? NSColor == .white)
        #expect(attrs[.underlineStyle] as? Int == NSUnderlineStyle.single.rawValue)
    }

    @Test("linkUnderlineStyle = [] drops the underline")
    func customLinkUnderlineStyleReachesLinkTextAttributes() {
        let none = MarkdownEditorTheme(linkUnderlineStyle: [])
        #expect(none.linkTextAttributes[.underlineStyle] as? Int == 0)

        let thick = MarkdownEditorTheme(linkUnderlineStyle: .thick)
        #expect(thick.linkTextAttributes[.underlineStyle] as? Int == NSUnderlineStyle.thick.rawValue)
    }
}
