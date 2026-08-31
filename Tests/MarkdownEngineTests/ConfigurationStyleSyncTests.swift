//
//  ConfigurationStyleSyncTests.swift
//  MarkdownEngineTests
//
//  `updateNSView` used to copy only a handful of `MarkdownEditorConfiguration`
//  fields into the coordinator, so an embedder that swapped configurations at
//  runtime — a light/dark theme toggle, a heading-metric change, a link-ink
//  update — got a stale styler on every rebuild. These tests pin the two
//  pieces the sync path relies on: the style-signature comparison and the
//  field-by-field copy, plus an end-to-end proof that the styler actually
//  reads the coordinator's live theme when a rebuild fires.
//

import AppKit
import SwiftUI
import Testing
@testable import MarkdownEngine

@MainActor
@Suite("Configuration style-only sync")
struct ConfigurationStyleSyncTests {

    // MARK: - Signature comparison

    @Test("changing any pure-style field flips the style signature")
    func styleSignatureDetectsEveryStyleField() {
        let base = MarkdownEditorConfiguration.default

        var themed = base
        themed.theme = MarkdownEditorTheme(bodyText: .red)
        #expect(base.styleSignature != themed.styleSignature)

        var paragraphed = base
        paragraphed.paragraph = ParagraphStyle(spacingFactor: 0.9)
        #expect(base.styleSignature != paragraphed.styleSignature)

        var linked = base
        linked.link = LinkStyle(activeLinkAlpha: 0.1)
        #expect(base.styleSignature != linked.styleSignature)

        var headed = base
        headed.headings = HeadingStyle(fontMultipliers: [3, 2, 1.5, 1, 1, 1])
        #expect(base.styleSignature != headed.styleSignature)

        var marked = base
        marked.markers = MarkerStyle(hiddenMarkerFontSize: 5)
        #expect(base.styleSignature != marked.styleSignature)

        var caret = base
        caret.cursorFollowsSpanInk.toggle()
        #expect(base.styleSignature != caret.styleSignature)
    }

    @Test("changing grammar/service/lifecycle fields does not flip the style signature")
    func styleSignatureIgnoresNonStyleFields() {
        // These fields have their own sync paths in `updateNSView` — the style
        // signature must not drag them into its own compare, or every services
        // fingerprint bump would double-fire a full restyle.
        let base = MarkdownEditorConfiguration.default

        var lists = base
        lists.lists = ListStyle(helpersEnabled: false)
        #expect(base.styleSignature == lists.styleSignature)

        var height = base
        height.heightBehavior = .fitsContent
        #expect(base.styleSignature == height.styleSignature)

        var raw = base
        raw.rawSourceMode = true
        #expect(base.styleSignature == raw.styleSignature)

        var insets = base
        insets.safeAreaInsets = SafeAreaInsets(top: 40)
        #expect(base.styleSignature == insets.styleSignature)
    }

    // MARK: - Field copy

    @Test("adoptStyleFields copies every style field, and only those")
    func adoptStyleFieldsCopiesTheRightFields() {
        var target = MarkdownEditorConfiguration.default
        // Give the target a distinctive non-style state so we can prove those
        // fields are left alone.
        target.heightBehavior = .fitsContent
        target.rawSourceMode = true
        target.lists = ListStyle(helpersEnabled: false)

        var source = MarkdownEditorConfiguration.default
        source.theme = MarkdownEditorTheme(bodyText: .systemPurple, link: .systemPink)
        source.paragraph = ParagraphStyle(spacingFactor: 0.9, lineHeightExtraSpacing: 4)
        source.link = LinkStyle(activeLinkAlpha: 0.11, incompleteLinkAlpha: 0.22)
        source.headings = HeadingStyle(fontMultipliers: [3, 2, 1.5, 1, 1, 1])
        source.cursorFollowsSpanInk = true

        target.adoptStyleFields(from: source)

        #expect(target.theme == source.theme)
        #expect(target.paragraph == source.paragraph)
        #expect(target.link == source.link)
        #expect(target.headings == source.headings)
        #expect(target.cursorFollowsSpanInk == source.cursorFollowsSpanInk)
        // Non-style fields are left as they were — they belong to other paths.
        #expect(target.heightBehavior == .fitsContent)
        #expect(target.rawSourceMode == true)
        #expect(target.lists.helpersEnabled == false)
    }

    // MARK: - End-to-end: a theme swap actually repaints

    @Test("a rebuild after a theme swap paints body text with the new color")
    func rebuildAfterThemeSwapUsesNewColor() {
        _ = NSApplication.shared
        let text = "plain body text"
        let coordinator = NativeTextViewCoordinator(
            text: .constant(text), fontName: "SF Pro", fontSize: 16,
            isWikiLinkActive: .constant(false), onLinkClick: nil, onInlineSelectionChange: nil
        )
        let tv = NativeTextView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        tv.isEditable = true
        tv.delegate = coordinator
        coordinator.textView = tv
        coordinator.configuration = MarkdownEditorConfiguration.default
        tv.configuration = coordinator.configuration
        coordinator.rebuildTextStorageAndStyle(tv, from: text)

        // The default theme's bodyText is `.labelColor`, so an equality check
        // against a fresh distinct color is a valid before/after proof.
        let newTheme = MarkdownEditorTheme(bodyText: NSColor(calibratedRed: 0.2, green: 0.4, blue: 0.6, alpha: 1))

        // The same two lines `updateNSView` runs when the style signature moves.
        var next = MarkdownEditorConfiguration.default
        next.theme = newTheme
        coordinator.configuration.adoptStyleFields(from: next)
        tv.configuration.adoptStyleFields(from: next)

        // A rebuild picks the theme up from `configuration.theme`, so the
        // newly painted body foreground must equal the swapped-in color.
        coordinator.rebuildTextStorageAndStyle(tv, from: text)
        let painted = tv.textStorage?.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor
        #expect(painted == newTheme.bodyText)
    }
}
