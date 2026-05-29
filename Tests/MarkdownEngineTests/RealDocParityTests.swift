//
//  RealDocParityTests.swift
//  MarkdownEngineTests
//
//  Phase 1 — best-effort parity check against the live corpus on this machine.
//  Runs ONLY if a MarkdownFiles directory exists; never commits or prints
//  document content (reports filenames + token kinds/ranges only — no text).
//  Skipped silently when the corpus is absent (e.g. CI).
//

import Foundation
import Testing
@testable import MarkdownEngine

@Suite("Phase 1 — real-document parity (best-effort)")
struct RealDocParityTests {

    /// Candidate locations: sandbox container first, then the classic path.
    static let candidateDirs: [String] = [
        "\(NSHomeDirectory())/Library/Containers/com.nvm.nodes/Data/Documents/MarkdownFiles",
        "\(NSHomeDirectory())/Documents/MarkdownFiles",
    ]

    @Test("scoped parse matches whole-doc parse on real documents, if present")
    func realDocsParity() {
        let fm = FileManager.default
        guard let dir = Self.candidateDirs.first(where: { fm.fileExists(atPath: $0) }) else {
            return  // No live corpus here — nothing to verify, not a failure.
        }
        let urls = (try? fm.contentsOfDirectory(
            at: URL(fileURLWithPath: dir), includingPropertiesForKeys: nil
        ))?.filter { $0.pathExtension == "md" } ?? []

        var checked = 0
        var divergent: [(String, String)] = []
        for url in urls {
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            checked += 1
            let whole = MarkdownTokenizer.parseTokens(in: text)
            let byBlock = MarkdownTokenizer.parseTokensByBlock(in: text)
            if let diff = structuralDifference(whole: whole, byBlock: byBlock) {
                divergent.append((url.lastPathComponent, diff))
            }
        }

        if !divergent.isEmpty {
            let report = divergent.prefix(20).map { "  \($0.0): \($0.1)" }.joined(separator: "\n")
            Issue.record("""
            \(divergent.count)/\(checked) real documents diverge (whole-doc vs per-block parse):
            \(report)
            """)
        }
    }

    /// Order-independent comparison. Returns nil if equal, else a privacy-safe
    /// summary (token kind + ranges only, never document text).
    private func structuralDifference(whole: [MarkdownToken], byBlock: [MarkdownToken]) -> String? {
        func key(_ t: MarkdownToken) -> String {
            "\(t.kind)@\(t.range.location)+\(t.range.length)/c\(t.contentRange.location)+\(t.contentRange.length)"
        }
        let w = Set(whole.map(key))
        let b = Set(byBlock.map(key))
        guard w != b else { return nil }
        let onlyWhole = Array(w.subtracting(b).sorted().prefix(3))
        let onlyBlock = Array(b.subtracting(w).sorted().prefix(3))
        return "Δcount \(whole.count)→\(byBlock.count); only-whole=\(onlyWhole); only-byBlock=\(onlyBlock)"
    }
}
