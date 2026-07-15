//
//  MarkdownInputHandler.swift
//  MarkdownEngine
//
//  Created by Luca Chen on 18.02.26.
//

// Handles Markdown typing shortcuts, like continuing lists and keeping block
// LaTeX on its own line while you type.
import AppKit

enum MarkdownInputHandler {

    /// `codeTokens` (codeBlock + inlineCode, from the keystroke's existing
    /// parse) answers "is the caret in code?" without the O(doc) document
    /// scan the handler otherwise runs on every space/Enter/Tab.
    static func handleListInsertion(textView: NSTextView, affectedCharRange: NSRange, replacementString: String?, codeTokens: [MarkdownToken]? = nil) -> Bool {
        let isInsideCodeBlock = codeTokens.map {
            MarkdownDetection.isInsideCodeBlock(location: affectedCharRange.location, codeTokens: $0)
        }
        return MarkdownLists.handleInsertion(textView: textView, affectedCharRange: affectedCharRange,
                                             replacementString: replacementString, isInsideCodeBlock: isInsideCodeBlock)
    }

    // MARK: - Block LaTeX Auto-Wrap

    private static func insertTextProgrammatically(_ textView: NSTextView, text: String, at range: NSRange, cursorAfter: Int) {
        if let coord = textView.delegate as? NativeTextViewWrapper.Coordinator {
            coord.isProgrammaticEdit = true
            // Replaces a suppressed keystroke that never applied — reset its
            // pending count so this edit registers as the cycle's single
            // tracked edit and textDidChange keeps the trusted fast paths.
            coord.pendingEditCount = 0
        }
        textView.insertText(text, replacementRange: range)
        if let coord = textView.delegate as? NativeTextViewWrapper.Coordinator {
            coord.isProgrammaticEdit = false
        }
        textView.setSelectedRange(NSRange(location: cursorAfter, length: 0))
    }

    /// Keeps block LaTeX ($$...$$) on its own line by inserting newlines; returns true if handled.
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
            resolvedTokens = MarkdownTokenizer.parseTokensViaAST(
                in: textView.string,
                registry: (textView as? NativeTextView)?.configuration.extensionRegistry ?? .empty
            ).filter { $0.kind == .blockLatex }
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
            resolvedTokens = MarkdownTokenizer.parseTokensViaAST(
                in: textView.string,
                registry: (textView as? NativeTextView)?.configuration.extensionRegistry ?? .empty
            ).filter { $0.kind == .imageEmbed }
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
