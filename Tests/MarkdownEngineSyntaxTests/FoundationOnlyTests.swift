//
//  FoundationOnlyTests.swift
//  MarkdownEngineSyntaxTests
//
//  `MarkdownEngineSyntax` imports Foundation only.
//

import Foundation
import Testing

struct FoundationOnlyTests {
    @Test func theSyntaxTargetImportsFoundationOnly() throws {
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/MarkdownEngineSyntax")
        let files = try #require(FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil))
            .compactMap { $0 as? URL }
            .filter { $0.pathExtension == "swift" }
        #expect(!files.isEmpty)
        // `import M`, `@preconcurrency import M`, `import struct M.T`, at any indent.
        let pattern = try NSRegularExpression(
            pattern: #"^(?:@\w+\s+)*import\s+(?:(?:struct|class|enum|protocol|func|var|let|typealias)\s+)?(\w+)"#)
        for file in files {
            let lines = try String(contentsOf: file, encoding: .utf8).split(separator: "\n")
            for line in lines {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                let range = NSRange(trimmed.startIndex..., in: trimmed)
                guard let match = pattern.firstMatch(in: trimmed, range: range),
                      let module = Range(match.range(at: 1), in: trimmed) else { continue }
                #expect(trimmed[module] == "Foundation", "\(file.lastPathComponent): \(trimmed)")
            }
        }
    }
}
