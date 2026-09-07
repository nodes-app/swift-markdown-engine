#if os(iOS)
import Foundation

enum PerfTrace {
    static func note(_ message: () -> String) {}
}

struct DirectiveRegistry {
    static let empty = DirectiveRegistry()
    let isEmpty = true
    let fingerprint = ""
}

struct DirectiveMatch {
    let nodeID: String
    let range: NSRange
    let contentRange: NSRange
    let markers: [NSRange]
    let parsesContent: Bool
}

enum DirectiveScanner {
    static func match(_ text: NSString, len: Int, at index: Int, registry: DirectiveRegistry) -> DirectiveMatch? {
        nil
    }
}

struct InlineSyntax: Sendable, Equatable {
    var open: String
    var close: String
    var parsesContent: Bool
    var requiresNonEmptyContent: Bool
    var rejectsOpenerRun: Bool
    var rejectsCloserRun: Bool
}

struct ExtensionRegistry {
    struct Entry {
        let id: String
        let open: [unichar]
        let close: [unichar]
        let syntax: InlineSyntax
    }

    struct BlockEntry {
        let id: String
        let fence: String
        let fenceChars: [unichar]
    }

    let entries: [Entry]
    let blockEntries: [BlockEntry]
    let directives: DirectiveRegistry
    let fingerprint: String

    static let empty = ExtensionRegistry(entries: [], blockEntries: [], directives: .empty, fingerprint: "")

    func blockEntry(opening line: String) -> BlockEntry? {
        blockEntries.first { line.hasPrefix($0.fence) }
    }

    func blockEntry(for id: String) -> BlockEntry? {
        blockEntries.first { $0.id == id }
    }
}
#endif
