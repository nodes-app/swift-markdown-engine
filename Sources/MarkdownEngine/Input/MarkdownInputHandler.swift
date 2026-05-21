//
//  MarkdownInputHandler.swift
//  MarkdownEngine
//
//  Created by Luca Chen on 18.02.26.
//

#if os(macOS)
// Handles Markdown typing shortcuts, like continuing lists and keeping block
// LaTeX on its own line while you type.
import AppKit

enum MarkdownInputHandler {

    static func handleListInsertion(textView: NSTextView, affectedCharRange: NSRange, replacementString: String?) -> Bool {
        return MarkdownLists.handleInsertion(textView: textView, affectedCharRange: affectedCharRange, replacementString: replacementString)
    }

    // MARK: - Block LaTeX Auto-Wrap

    private static func insertTextProgrammatically(_ textView: NSTextView, text: String, at range: NSRange, cursorAfter: Int) {
        if let coord = textView.delegate as? NativeTextViewWrapper.Coordinator {
            coord.isProgrammaticEdit = true
        }
        textView.insertText(text, replacementRange: range)
        if let coord = textView.delegate as? NativeTextViewWrapper.Coordinator {
            coord.isProgrammaticEdit = false
        }
        textView.setSelectedRange(NSRange(location: cursorAfter, length: 0))
    }

    /// Ensures block LaTeX ($$...$$) stays on its own line by automatically inserting newlines
    /// when typing directly before or after a block LaTeX token.
    /// Returns true if the insertion was handled (caller should return false from shouldChangeTextIn).
    static func handleBlockLatexAutoWrap(
        textView: NSTextView,
        affectedCharRange: NSRange,
        replacementString: String?,
        blockLatexTokens: [MarkdownToken]? = nil
    ) -> Bool {
        let resolvedTokens: [MarkdownToken]
        if let blockLatexTokens {
            resolvedTokens = blockLatexTokens
        } else {
            resolvedTokens = MarkdownTokenizer.parseTokens(in: textView.string).filter { $0.kind == .blockLatex }
        }
        return handleBlockAutoWrap(textView: textView, affectedCharRange: affectedCharRange,
                                   replacementString: replacementString, tokens: resolvedTokens)
    }

    /// Ensures image embeds (![[...]]) stay on their own line by automatically inserting newlines.
    static func handleImageEmbedAutoWrap(
        textView: NSTextView,
        affectedCharRange: NSRange,
        replacementString: String?,
        imageEmbedTokens: [MarkdownToken]? = nil
    ) -> Bool {
        let resolvedTokens: [MarkdownToken]
        if let imageEmbedTokens {
            resolvedTokens = imageEmbedTokens
        } else {
            resolvedTokens = MarkdownTokenizer.parseTokens(in: textView.string).filter { $0.kind == .imageEmbed }
        }
        return handleBlockAutoWrap(textView: textView, affectedCharRange: affectedCharRange,
                                   replacementString: replacementString, tokens: resolvedTokens)
    }

    /// Shared auto-wrap logic: ensures a block-level token stays on its own line.
    private static func handleBlockAutoWrap(
        textView: NSTextView,
        affectedCharRange: NSRange,
        replacementString: String?,
        tokens: [MarkdownToken]
    ) -> Bool {
        guard let replacement = replacementString,
              !replacement.isEmpty,
              replacement != "\n" else { return false }

        let text = textView.string as NSString
        let newlineChar = UInt16(("\n" as Character).asciiValue!)

        for token in tokens {
            let tokenEnd = NSMaxRange(token.range)

            // Typing right after closing marker
            if affectedCharRange.location == tokenEnd {
                if tokenEnd < text.length && text.character(at: tokenEnd) == newlineChar {
                    insertTextProgrammatically(textView, text: replacement,
                                               at: NSRange(location: tokenEnd + 1, length: 0),
                                               cursorAfter: tokenEnd + 1 + replacement.utf16.count)
                } else {
                    insertTextProgrammatically(textView, text: "\n" + replacement,
                                               at: affectedCharRange,
                                               cursorAfter: affectedCharRange.location + 1 + replacement.utf16.count)
                }
                return true
            }

            // Typing right before opening marker
            if affectedCharRange.location == token.range.location {
                if token.range.location > 0 && text.character(at: token.range.location - 1) == newlineChar {
                    insertTextProgrammatically(textView, text: replacement,
                                               at: NSRange(location: token.range.location - 1, length: 0),
                                               cursorAfter: token.range.location - 1 + replacement.utf16.count)
                } else {
                    insertTextProgrammatically(textView, text: replacement + "\n",
                                               at: affectedCharRange,
                                               cursorAfter: affectedCharRange.location + replacement.utf16.count)
                }
                return true
            }
        }

        return false
    }
}
#endif
