//
//  CharacterizationTests.swift
//  MarkdownEngineTests
//
//  Phase 0 — pins the CURRENT behavior of the regex-based parser and styler.
//  These snapshots are the acceptance latch for the regex→AST refactor: the
//  Phase 1 per-block scoped parser must reproduce them (modulo a documented
//  whitelist of deliberate fixes).
//
//  First run records baselines under __Snapshots__/ and fails; re-run to
//  verify green. Force re-record with RECORD_SNAPSHOTS=1.
//

import AppKit
import Foundation
import Testing
@testable import MarkdownEngine

// `.serialized` so the one-time snapshot *recording* (concurrent file writes)
// can't race. Steady-state runs are read-only compares and would be safe
// either way.
@Suite("Phase 0 — characterization latch", .serialized)
struct CharacterizationTests {

    @Test("parseTokens output is pinned", arguments: MarkdownCorpus.cases)
    func parseTokensSnapshot(_ c: MarkdownCase) {
        // After P2.6 the live parser is the AST pipeline; the latch pins it.
        let tokens = MarkdownTokenizer.parseTokensViaAST(in: c.text)
        assertSnapshot(tokenSnapshot(tokens, in: c.text), named: "tokens__\(c.name)")
    }

    // @MainActor + NSApplication.shared: the table / block-LaTeX render path
    // resolves `NSApp.effectiveAppearance`, which force-unwraps nil in a
    // headless test process until the shared application instance exists.
    // (Test-environment requirement, not a production bug — the real app
    // always has a live NSApp. A `NSApp?.…` guard there would be more robust.)
    @MainActor
    @Test("styleAttributes key projection is pinned", arguments: MarkdownCorpus.cases)
    func styleAttributesSnapshot(_ c: MarkdownCase) {
        _ = NSApplication.shared
        let styled = MarkdownStyler.styleAttributes(
            text: c.text,
            fontName: NSFont.systemFont(ofSize: 14).fontName,
            fontSize: 14,
            caretLocation: -1,
            activeTokenIndices: [],
            configuration: .default
        )
        assertSnapshot(styleKeySnapshot(styled), named: "style__\(c.name)")
    }
}
