//
//  NativeTextViewCoordinator+Autocorrect.swift
//  MarkdownEngine
//
//  Created by Luca Chen on 16.03.26.
//
//  Toggles AppKit's auto-correct, spell-check, grammar-check and quote
//  substitution off when the caret enters tokens where those features are
//  unwanted (code blocks, LaTeX, links). The decision is cached so it only
//  fires when the state actually changes.
//

import AppKit

extension NativeTextViewCoordinator {
    func updateAutocorrectSettings(
        _ textView: NSTextView,
        caretLocation: Int,
        codeTokens: [MarkdownToken]? = nil,
        latexTokens: [MarkdownToken]? = nil,
        allTokens: [MarkdownToken]? = nil
    ) {
        // Prefer precomputed tokens to avoid the expensive textView.string bridge on long docs.
        let inCode: Bool
        if let codeTokens = codeTokens {
            inCode = MarkdownDetection.isInsideCodeBlock(location: caretLocation, codeTokens: codeTokens)
        } else {
            inCode = MarkdownDetection.isInsideCodeBlock(location: caretLocation, in: textView.string)
        }
        let inLatex: Bool
        if let latexTokens = latexTokens {
            inLatex = MarkdownDetection.isInsideLatex(location: caretLocation, latexTokens: latexTokens)
        } else {
            inLatex = MarkdownDetection.isInsideLatex(location: caretLocation, in: textView.string)
        }
        let inSpellcheckSuppressedToken: Bool
        if let allTokens = allTokens {
            inSpellcheckSuppressedToken = allTokens.contains { token in
                (token.kind == .wikiLink || token.kind == .link || token.kind == .imageEmbed)
                    && NSLocationInRange(caretLocation, token.range)
            }
        } else {
            inSpellcheckSuppressedToken = isInsideSpellcheckSuppressedToken(location: caretLocation, in: textView.string)
        }
        let shouldDisableSpelling = inCode || inLatex || inSpellcheckSuppressedToken

        if cachedSpellingDisabled == shouldDisableSpelling {
            return
        }
        cachedSpellingDisabled = shouldDisableSpelling

        textView.isAutomaticSpellingCorrectionEnabled = !shouldDisableSpelling
        textView.isContinuousSpellCheckingEnabled = !shouldDisableSpelling
        textView.isGrammarCheckingEnabled = !shouldDisableSpelling
        textView.isAutomaticQuoteSubstitutionEnabled = !shouldDisableSpelling
        textView.isAutomaticDashSubstitutionEnabled = false
    }

    func isInsideCode(range: NSRange, in text: String) -> Bool {
        let parsed = parsedDocument(for: text)
        return MarkdownDetection.isInsideCodeBlock(range: range, codeTokens: parsed.codeTokens)
    }

    func isInsideLatex(location: Int, in text: String) -> Bool {
        let parsed = parsedDocument(for: text)
        if MarkdownDetection.isInsideLatex(location: location, latexTokens: parsed.latexTokens) {
            return true
        }
        return MarkdownDetection.isInsideLatex(location: location, latexTokens: parsed.blockLatexTokens)
    }

    func isInsideSpellcheckSuppressedToken(location: Int, in text: String) -> Bool {
        let parsed = parsedDocument(for: text)
        return parsed.tokens.contains { token in
            guard token.kind == .wikiLink || token.kind == .link || token.kind == .imageEmbed else {
                return false
            }
            return NSLocationInRange(location, token.range)
        }
    }

    func isInsideSpellcheckSuppressedToken(range: NSRange, in text: String) -> Bool {
        let parsed = parsedDocument(for: text)
        return parsed.tokens.contains { token in
            guard token.kind == .wikiLink || token.kind == .link || token.kind == .imageEmbed else {
                return false
            }
            return NSIntersectionRange(token.range, range).length > 0
        }
    }
}
