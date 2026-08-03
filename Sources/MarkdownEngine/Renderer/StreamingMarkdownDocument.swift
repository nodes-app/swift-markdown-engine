//
//  StreamingMarkdownDocument.swift
//  MarkdownEngine
//

import Foundation

/// Selects how externally supplied document updates are rendered.
public enum MarkdownRenderingMode: Sendable, Equatable {
    /// Normal editor/document behavior: parse and style the complete Markdown document.
    case editor

    /// Read-only append-only behavior for generated text.
    ///
    /// While this mode is active, updates must preserve the existing text and only
    /// append new characters. The engine renders appended text with base attributes,
    /// without parsing Markdown or invoking syntax highlighting. Switch back to
    /// ``editor`` when generation completes to run one authoritative full render.
    case streamingReadOnly
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
    private var lastText = ""

    func update(documentID: String, text: String, forceReset: Bool = false) -> Mutation {
        let newLength = (text as NSString).length

        guard forceReset == false,
              self.documentID == documentID,
              newLength >= utf16Length else {
            adopt(documentID: documentID, text: text, utf16Length: newLength)
            return .reset(text)
        }

        if newLength == utf16Length {
            guard text != lastText else { return .none }
            adopt(documentID: documentID, text: text, utf16Length: newLength)
            return .reset(text)
        }

        // `.streamingReadOnly` is an append-only contract, so avoid an O(document)
        // prefix comparison on every update. Extract only the newly appended UTF-16
        // tail; callers end a stream by switching modes and replace a stream by using
        // a different document ID.
        let appendedText = (text as NSString).substring(from: utf16Length)
        adopt(documentID: documentID, text: text, utf16Length: newLength)
        return .append(appendedText)
    }

    func finish() {
        documentID = nil
        utf16Length = 0
        lastText = ""
    }

    private func adopt(documentID: String, text: String, utf16Length: Int) {
        self.documentID = documentID
        self.utf16Length = utf16Length
        lastText = text
    }
}
