//
//  StreamingMarkdownDocument.swift
//  MarkdownEngine
//

import Foundation

/// Controls the explicit lifecycle of an append-only generated document.
public enum MarkdownStreamingState: Sendable, Equatable {
    /// Normal parsed Markdown rendering.
    case idle

    /// An active append-only transaction. Markdown parsing and syntax highlighting
    /// are deferred until the state returns to ``idle``.
    case streaming
}

/// Selects how an active streaming transaction validates cumulative updates.
public enum MarkdownStreamingValidation: Sendable, Equatable {
    /// Verifies that every cumulative update preserves the previously rendered prefix.
    /// This is the default and safely falls back to a reset when the prefix changes.
    case safe

    /// Trusts the producer's append-only contract and skips prefix verification.
    ///
    /// Use this only for AI/token streaming pipelines that construct each cumulative
    /// value by appending trusted deltas to the previous value.
    case trustedAppendOnly
}

/// Tracks the append cursor for one streaming document.
///
/// This deliberately does not retain or update an AST: streaming presentation is
/// plain/base-styled text, so parsing an active block would be work whose result is
/// discarded at completion. The normal document pipeline remains the single source
/// of truth for the final Markdown render.
final class StreamingMarkdownDocument {
    enum Mutation: Equatable {
        case none
        case reset(String)
        case append(String)
    }

    private(set) var documentID: String?
    private(set) var utf16Length = 0
    private var prefixFingerprint: UInt64 = 0

    func begin(documentID: String) {
        self.documentID = documentID
        utf16Length = 0
        prefixFingerprint = 0
    }

    func update(
        documentID: String,
        text: String,
        validation: MarkdownStreamingValidation = .safe,
        forceReset: Bool = false
    ) -> Mutation {
        let newLength = (text as NSString).length

        guard !forceReset,
              self.documentID == documentID,
              newLength >= utf16Length else {
            adopt(documentID: documentID, text: text, validation: validation)
            return .reset(text)
        }

        if newLength == utf16Length {
            guard validation == .safe else { return .none }
            let currentHash = fingerprint(text, utf16Length: newLength)
            guard currentHash == prefixFingerprint else {
                adopt(documentID: documentID, text: text, validation: validation)
                return .reset(text)
            }
            return .none
        }

        if validation == .safe {
            let currentPrefixHash = fingerprint(text, utf16Length: utf16Length)
            guard currentPrefixHash == prefixFingerprint else {
                adopt(documentID: documentID, text: text, validation: validation)
                return .reset(text)
            }
        }

        let tail = (text as NSString).substring(from: utf16Length)
        adoptStreamingAppend(
            documentID: documentID,
            text: text,
            newLength: newLength,
            validation: validation
        )
        return .append(tail)
    }

    func finish() {
        documentID = nil
        utf16Length = 0
        prefixFingerprint = 0
    }

    private func adopt(
        documentID: String,
        text: String,
        validation: MarkdownStreamingValidation
    ) {
        self.documentID = documentID
        utf16Length = (text as NSString).length
        prefixFingerprint = validation == .safe
            ? fingerprint(text, utf16Length: utf16Length)
            : 0
    }

    private func adoptStreamingAppend(
        documentID: String,
        text: String,
        newLength: Int,
        validation: MarkdownStreamingValidation
    ) {
        self.documentID = documentID
        utf16Length = newLength
        prefixFingerprint = validation == .safe
            ? fingerprint(text, utf16Length: newLength)
            : 0
    }

    private func fingerprint(_ text: String, utf16Length: Int) -> UInt64 {
        let nsText = text as NSString
        let prefix = nsText.substring(with: NSRange(location: 0, length: utf16Length))
        var hash: UInt64 = 1_469_598_103_934_665_603
        for byte in prefix.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return hash
    }
}
