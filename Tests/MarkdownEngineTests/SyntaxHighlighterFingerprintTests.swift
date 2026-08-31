//
//  SyntaxHighlighterFingerprintTests.swift
//  MarkdownEngineTests
//
//  `SyntaxHighlighter.fingerprint()` is the seam for a runtime swap between
//  two different highlighter instances (a light-theme bridge → a dark-theme
//  bridge, a plain-text highlighter → a syntax-aware one). Its parallel to
//  `WikiLinkResolver.fingerprint()` and `EmbeddedImageProvider.fingerprint()`
//  is what these tests pin: the protocol default keeps existing highlighters
//  untouched, and the wrapper's services gate consults it alongside the two
//  existing fingerprints.
//

import AppKit
import SwiftUI
import Testing
@testable import MarkdownEngine

@MainActor
@Suite("SyntaxHighlighter.fingerprint()")
struct SyntaxHighlighterFingerprintTests {

    /// A highlighter whose fingerprint is a caller-supplied String, so a test
    /// can swap it and observe the gate.
    private struct FingerprintedHighlighter: SyntaxHighlighter {
        let identity: String
        let color: NSColor
        func codeFont(size: CGFloat) -> NSFont { .monospacedSystemFont(ofSize: size, weight: .regular) }
        func backgroundColor() -> NSColor { color }
        func highlight(code: String, language: String?) -> NSAttributedString? { nil }
        var appearanceDidChangeNotification: Notification.Name? { nil }
        func fingerprint() -> AnyHashable { identity }
    }

    @Test("PlainTextSyntaxHighlighter inherits the protocol default (0)")
    func defaultFingerprintIsZero() {
        let hl = PlainTextSyntaxHighlighter()
        #expect(hl.fingerprint() == AnyHashable(0))
    }

    @Test("a swap to a different fingerprint changes the value")
    func fingerprintFlipsOnSwap() {
        let light = FingerprintedHighlighter(identity: "light", color: .white)
        let dark = FingerprintedHighlighter(identity: "dark", color: .black)
        #expect(light.fingerprint() != dark.fingerprint())
    }

    @Test("the coordinator adopts a new highlighter when its fingerprint changes")
    func fingerprintChangeAdoptsNewHighlighter() {
        _ = NSApplication.shared
        let coordinator = NativeTextViewCoordinator(
            text: .constant("```swift\nlet x = 1\n```\n"),
            fontName: "SF Pro", fontSize: 14,
            isWikiLinkActive: .constant(false),
            onLinkClick: nil, onInlineSelectionChange: nil
        )
        let initial = FingerprintedHighlighter(identity: "v1", color: .red)
        var initialConfig = MarkdownEditorConfiguration.default
        initialConfig.services = MarkdownEditorServices(syntaxHighlighter: initial)
        coordinator.configuration = initialConfig
        coordinator.lastHighlighterFingerprint = initial.fingerprint()

        let next = FingerprintedHighlighter(identity: "v2", color: .green)
        var nextConfig = MarkdownEditorConfiguration.default
        nextConfig.services = MarkdownEditorServices(syntaxHighlighter: next)

        // What updateNSView runs when the highlighter fingerprint changes.
        let newFp = nextConfig.services.syntaxHighlighter.fingerprint()
        let changed = newFp != coordinator.lastHighlighterFingerprint
        #expect(changed == true)
        if changed {
            coordinator.lastHighlighterFingerprint = newFp
            coordinator.configuration.services = nextConfig.services
        }
        #expect(coordinator.configuration.services.syntaxHighlighter.backgroundColor() == .green)
    }
}
