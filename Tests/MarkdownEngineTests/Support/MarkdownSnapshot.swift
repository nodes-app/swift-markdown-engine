//
//  MarkdownSnapshot.swift
//  MarkdownEngineTests
//
//  Phase 0 — characterization / golden-snapshot support for the regex→AST
//  refactor. Serializes the *current* parser/styler output to stable,
//  human-readable text so any future change (e.g. the per-block scoped
//  parser introduced in Phase 1) can be diffed against today's behavior.
//
//  Two projections:
//    • tokenSnapshot   — position-sorted [MarkdownToken]. Order is normalized
//                        because the token array's order is behaviorally
//                        irrelevant: every consumer (MarkdownDetection,
//                        shrinkInactiveMarkers, …) recomputes indices fresh
//                        from the current array.
//    • styleKeySnapshot — [StyledRange] reduced to (range, sorted attribute
//                        KEY names). The values (NSFont/NSColor/NSParagraphStyle/
//                        NSImage) don't serialize stably; the keys do, and they
//                        are enough to catch "which range got which kind of
//                        attribute" regressions.
//
//  Snapshots are stored next to this file under __Snapshots__/. On first run
//  (or with RECORD_SNAPSHOTS=1) the baseline is written and the test fails so
//  the run is never silently green; subsequent runs assert equality.
//

import AppKit
import Foundation
import Testing
@testable import MarkdownEngine

// MARK: - Snapshot directory (derived from this file's own location)

private let snapshotsDirectory: URL = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()        // .../MarkdownEngineTests/Support
    .deletingLastPathComponent()        // .../MarkdownEngineTests
    .appendingPathComponent("__Snapshots__", isDirectory: true)

private var isRecording: Bool {
    ProcessInfo.processInfo.environment["RECORD_SNAPSHOTS"] == "1"
}

// MARK: - NSRange / text helpers

private func fmt(_ r: NSRange) -> String {
    r.location == NSNotFound ? "∅" : "\(r.location)+\(r.length)"
}

private func escapedPreview(_ range: NSRange, in nsText: NSString, maxLen: Int = 40) -> String {
    guard range.location != NSNotFound,
          range.location >= 0,
          range.length >= 0,
          NSMaxRange(range) <= nsText.length else { return "⟨invalid⟩" }
    var s = nsText.substring(with: range)
        .replacingOccurrences(of: "\n", with: "⏎")
        .replacingOccurrences(of: "\t", with: "⇥")
    if s.count > maxLen { s = String(s.prefix(maxLen)) + "…" }
    return s
}

// MARK: - Token kind names (explicit switch — compiler forces an update on new cases)

private func kindName(_ kind: MarkdownTokenKind) -> String {
    switch kind {
    case .italic: return "italic"
    case .boldItalic: return "boldItalic"
    case .bold: return "bold"
    case .link: return "link"
    case .wikiLink: return "wikiLink"
    case .heading: return "heading"
    case .blockquote: return "blockquote"
    case .codeBlock: return "codeBlock"
    case .inlineCode: return "inlineCode"
    case .blockLatex: return "blockLatex"
    case .inlineLatex: return "inlineLatex"
    case .imageEmbed: return "imageEmbed"
    case .imageLink: return "imageLink"
    case .strikethrough: return "strikethrough"
    case .table: return "table"
    case .backslashEscape: return "backslashEscape"
    }
}

// MARK: - Token snapshot (order-normalized)

/// A stable, position-sorted textual rendering of a `[MarkdownToken]`.
func tokenSnapshot(_ tokens: [MarkdownToken], in text: String) -> String {
    let nsText = text as NSString
    let lines = tokens
        .sorted { a, b in
            if a.range.location != b.range.location { return a.range.location < b.range.location }
            if a.range.length != b.range.length { return a.range.length < b.range.length }
            return kindName(a.kind) < kindName(b.kind)
        }
        .map { t -> String in
            let markers = t.markerRanges.map(fmt).joined(separator: ",")
            return "\(kindName(t.kind)) @\(fmt(t.range)) content=\(fmt(t.contentRange)) markers=[\(markers)] «\(escapedPreview(t.range, in: nsText))»"
        }
    return lines.isEmpty ? "(no tokens)" : lines.joined(separator: "\n")
}

// MARK: - StyledRange key projection

/// A stable rendering of `[StyledRange]` capturing which ranges received
/// which attribute keys (values are intentionally omitted — see file header).
func styleKeySnapshot(_ ranges: [StyledRange]) -> String {
    let lines = ranges
        .map { entry -> (NSRange, [String]) in
            (entry.range, entry.attributes.keys.map(\.rawValue).sorted())
        }
        .sorted { a, b in
            if a.0.location != b.0.location { return a.0.location < b.0.location }
            if a.0.length != b.0.length { return a.0.length < b.0.length }
            return a.1.joined(separator: ",") < b.1.joined(separator: ",")
        }
        .map { "@\(fmt($0.0)) keys=[\($0.1.joined(separator: ","))]" }
    return lines.isEmpty ? "(no styled ranges)" : lines.joined(separator: "\n")
}

// MARK: - Record / verify

/// Compares `actual` against a stored snapshot. On first run (file missing) or
/// when `RECORD_SNAPSHOTS=1`, writes the baseline and records an Issue so the
/// run is not silently green. Otherwise asserts equality with a focused diff.
func assertSnapshot(_ actual: String, named name: String) {
    let fileURL = snapshotsDirectory.appendingPathComponent("\(name).snap")
    let fm = FileManager.default
    let actualTrimmed = actual.trimmingCharacters(in: .newlines)

    if isRecording || !fm.fileExists(atPath: fileURL.path) {
        do {
            try fm.createDirectory(at: snapshotsDirectory, withIntermediateDirectories: true)
            try (actualTrimmed + "\n").write(to: fileURL, atomically: true, encoding: .utf8)
            let lineCount = actualTrimmed.split(separator: "\n", omittingEmptySubsequences: false).count
            Issue.record("Recorded snapshot '\(name)' (\(lineCount) lines) at \(fileURL.path). Re-run to verify.")
        } catch {
            Issue.record("Failed to record snapshot '\(name)': \(error)")
        }
        return
    }

    let expected: String
    do {
        expected = try String(contentsOf: fileURL, encoding: .utf8)
            .trimmingCharacters(in: .newlines)
    } catch {
        Issue.record("Failed to read snapshot '\(name)': \(error)")
        return
    }

    if actualTrimmed != expected {
        Issue.record("Snapshot '\(name)' mismatch.\n\(firstDifference(expected: expected, actual: actualTrimmed))")
    }
}

private func firstDifference(expected: String, actual: String) -> String {
    let e = expected.split(separator: "\n", omittingEmptySubsequences: false)
    let a = actual.split(separator: "\n", omittingEmptySubsequences: false)
    for i in 0..<max(e.count, a.count) {
        let el = i < e.count ? String(e[i]) : "⟨missing⟩"
        let al = i < a.count ? String(a[i]) : "⟨missing⟩"
        if el != al {
            return """
              first diff at line \(i + 1):
                expected: \(el)
                actual:   \(al)
              (expected \(e.count) lines, actual \(a.count) lines)
            """
        }
    }
    return "(content equal after trimming; lengths expected \(e.count), actual \(a.count))"
}
