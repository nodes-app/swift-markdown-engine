//
//  NativeTextViewCoordinator+Restyling.swift
//  MarkdownEngine
//
//  Created by Luca Chen on 16.03.26.
//
//  Re-tokenization, paragraph-scoped restyling, and the inline-replacement
//  pipeline. The TextDelegate extension decides WHEN and on WHICH ranges to
//  restyle; this extension owns the tokenize cache and the actual call into
//  `TextStylingService`.
//

import AppKit

extension NativeTextViewCoordinator {
    /// Atomically rebuilds contents + base attrs + Markdown styling from storage-form `text`.
    func rebuildTextStorageAndStyle(
        _ textView: NSTextView,
        from text: String,
        invalidateLayout: Bool = false
    ) {
        // Storage is raw Markdown; only wiki links transform on display.
        // In raw source mode display IS storage — no transform, no metadata.
        let services = configuration.services
        let rawMode = configuration.rawSourceMode
        let displayText: String
        if rawMode {
            displayText = text
            wikiLinkMetadata = [:]
        } else {
            let displayState = WikiLinkService.makeDisplayState(from: text) { services.wikiLinks.name(forID: $0) }
            displayText = displayState.display
            wikiLinkMetadata = displayState.metadata
        }

        if textView.string != displayText {
            textView.string = displayText
        }
        lastSyncedText = text
        let nsDisplay = displayText as NSString
        let fullRange = NSRange(location: 0, length: nsDisplay.length)

        let (baseFont, paragraph) = TextStylingService.makeBaseFontAndStyle(
            fontName: fontName,
            fontSize: fontSize,
            layoutBridge: layoutBridge,
            configuration: configuration
        )
        let baseAttrs: [NSAttributedString.Key: Any] = [
            .font: baseFont,
            .foregroundColor: configuration.theme.bodyText,
            .paragraphStyle: paragraph
        ]
        textView.textStorage?.beginEditing()
        textView.textStorage?.removeAttribute(.link, range: fullRange)
        textView.textStorage?.setAttributes(baseAttrs, range: fullRange)

        if rawMode {
            // Base attributes only — the source stays verbatim and unstyled.
            activeTokenIndices = []
        } else {
            let tokens = parsedDocument(for: displayText).tokens
            // Hide caret from styling when read-only, else clicks reveal raw token syntax.
            let caretLocation = textView.isEditable ? textView.selectedRange().location : -1
            activeTokenIndices = MarkdownDetection.computeActiveTokenIndices(
                selectionRange: textView.selectedRange(),
                tokens: tokens,
                in: nsDisplay,
                suppressed: !textView.isEditable
            )

            let ranges = MarkdownStyler.styleAttributes(
                text: displayText,
                fontName: fontName,
                fontSize: fontSize,
                layoutBridge: layoutBridge,
                caretLocation: caretLocation,
                activeTokenIndices: activeTokenIndices,
                // FIX: apply .wikiLinkID attributes on load/node-switch too. Without this the uuid
                // survived only in the range-keyed wikiLinkMetadata; once a later writeback shifted a
                // link's range the metadata key missed and makeStorageState wrote [[Name]] (uuid lost).
                // wikiLinkMetadata was just refreshed by makeDisplayState above, so ranges match here.
                wikiLinkIDProvider: { [weak self] range in self?.wikiLinkID(for: range) },
                precomputedTokens: tokens,
                configuration: configuration
            )
            for (range, attrs) in ranges {
                for (key, value) in attrs {
                    textView.textStorage?.addAttribute(key, value: value, range: range)
                }
            }
        }
        textView.textStorage?.endEditing()

        textView.typingAttributes = TextStylingService.makeBaseTypingAttributes(
            font: baseFont,
            paragraphStyle: paragraph,
            theme: configuration.theme
        )

        if let tlm = textView.textLayoutManager {
            if invalidateLayout {
                tlm.invalidateLayout(for: tlm.documentRange)
            }
            tlm.ensureLayout(for: tlm.documentRange)
        }

        // Reconcile wide-table overlays after layout settles.
        if let nativeTextView = textView as? NativeTextView {
            DispatchQueue.main.async { [weak nativeTextView] in
                nativeTextView?.updateWideTableOverlays()
            }
        }
    }

    func restyleTextView(
        _ textView: NSTextView,
        paragraphCandidates: [NSRange],
        tokens: [MarkdownToken]? = nil
    ) {
        // Raw mode: no restyling; typing keeps base attrs via the typing shim.
        guard !configuration.rawSourceMode else { return }
        let (baseFont, paragraphStyle) = TextStylingService.makeBaseFontAndStyle(
            fontName: fontName,
            fontSize: fontSize,
            layoutBridge: layoutBridge,
            configuration: configuration
        )

        TextStylingService.restyle(
            textView: textView,
            layoutBridge: layoutBridge,
            paragraphCandidates: paragraphCandidates,
            baseFont: baseFont,
            paragraphStyle: paragraphStyle,
            caretLocation: textView.isEditable ? textView.selectedRange().location : -1,
            activeTokenIndices: activeTokenIndices,
            wikiLinkIDProvider: { [weak self] range in
                self?.wikiLinkID(for: range)
            },
            precomputedTokens: tokens,
            configuration: configuration
        )
        // Reconcile wide-table overlays after layout settles.
        if let nativeTextView = textView as? NativeTextView {
            DispatchQueue.main.async { [weak nativeTextView] in
                nativeTextView?.updateWideTableOverlays()
            }
        }
    }

    func parsedDocument(for text: String) -> ParsedDocument {
        if cachedParsedText == text, let cachedParsedDocument {
            return cachedParsedDocument
        }

        let tokens = MarkdownTokenizer.parseTokensViaAST(in: text)
        var codeTokens: [MarkdownToken] = []
        var latexTokens: [MarkdownToken] = []
        var blockLatexTokens: [MarkdownToken] = []
        var wikiLinkTokens: [MarkdownToken] = []
        var imageEmbedTokens: [MarkdownToken] = []

        codeTokens.reserveCapacity(tokens.count / 2)
        latexTokens.reserveCapacity(tokens.count / 4)
        blockLatexTokens.reserveCapacity(tokens.count / 4)
        wikiLinkTokens.reserveCapacity(tokens.count / 4)

        for token in tokens {
            switch token.kind {
            case .codeBlock, .inlineCode:
                codeTokens.append(token)
            case .inlineLatex:
                latexTokens.append(token)
            case .blockLatex:
                blockLatexTokens.append(token)
            case .wikiLink:
                wikiLinkTokens.append(token)
            case .imageEmbed:
                imageEmbedTokens.append(token)
            default:
                break
            }
        }

        let parsed = ParsedDocument(
            tokens: tokens,
            codeTokens: codeTokens,
            latexTokens: latexTokens,
            blockLatexTokens: blockLatexTokens,
            wikiLinkTokens: wikiLinkTokens,
            imageEmbedTokens: imageEmbedTokens
        )
        cachedParsedText = text
        cachedParsedDocument = parsed
        return parsed
    }

    func paragraphRanges(
        in text: NSString,
        intersecting editedRange: NSRange
    ) -> [NSRange] {
        guard text.length > 0 else { return [] }
        guard editedRange.location != NSNotFound else { return [] }

        var start = editedRange.location
        let end = min(NSMaxRange(editedRange), text.length)
        if start >= text.length {
            start = max(0, text.length - 1)
        }
        if end <= start {
            return [text.paragraphRange(for: NSRange(location: start, length: 0))]
        }

        var ranges: [NSRange] = []
        var cursor = start
        while cursor < end {
            let paragraph = text.paragraphRange(for: NSRange(location: cursor, length: 0))
            ranges.append(paragraph)
            let next = NSMaxRange(paragraph)
            if next <= cursor { break }
            cursor = next
        }
        return ranges
    }

    func tokenRestyleParagraphs(
        in text: NSString,
        tokens: [MarkdownToken],
        currentActiveTokenIndices: Set<Int>,
        previousActiveTokenIndices: Set<Int>
    ) -> [NSRange] {
        var paragraphs: [NSRange] = []
        let indicesToStyle = currentActiveTokenIndices.union(previousActiveTokenIndices)

        for idx in indicesToStyle where idx >= 0 && idx < tokens.count {
            let token = tokens[idx]
            paragraphs.append(text.paragraphRange(for: token.range))

            if token.kind == .codeBlock || token.kind == .blockLatex {
                for markerRange in token.markerRanges {
                    paragraphs.append(text.paragraphRange(for: markerRange))
                }
            }
        }

        return paragraphs
    }

    func restyleParagraphs(_ paragraphs: [NSRange], in textView: NSTextView) {
        let parsed = parsedDocument(for: textView.string)
        let tokens = parsed.tokens
        let nsText = textView.string as NSString
        activeTokenIndices = MarkdownDetection.computeActiveTokenIndices(
            selectionRange: textView.selectedRange(),
            tokens: tokens,
            in: nsText,
            suppressed: !textView.isEditable
        )
        restyleTextView(textView, paragraphCandidates: paragraphs, tokens: tokens)
    }

    func applyInlineReplacement(_ request: InlineReplacementRequest, to textView: NSTextView) {
        lastAppliedInlineReplacementID = request.id

        let currentText = textView.string as NSString
        let range = request.selection.displayRange
        guard range.location != NSNotFound,
              range.location + range.length <= currentText.length else {
            return
        }

        // Image embeds and node links share one path: insert DISPLAY form `![[Name]]` / `[[Name]]`
        // with the opaque suffix on the `.wikiLinkID` side-channel (displayFragmentAndID handles `!`).
        let replacementInfo = WikiLinkService.displayFragmentAndID(from: request.storageFragment)
        let replacementDisplay = replacementInfo.display
        let linkID = replacementInfo.id

        let undoActionName = request.isImageEmbedMode ? "Insert Image Embed" : "Insert Link"
        textView.breakUndoCoalescing()

        isProgrammaticEdit = true
        defer { isProgrammaticEdit = false }

        guard textView.shouldChangeText(in: range, replacementString: replacementDisplay) else {
            return
        }

        textView.textStorage?.replaceCharacters(in: range, with: replacementDisplay)

        if let linkID, !linkID.isEmpty {
            let isImage = replacementDisplay.hasPrefix("![[")
            let openLen = isImage ? 3 : 2
            let contentLength = max(0, (replacementDisplay as NSString).length - (openLen + 2))
            if contentLength > 0 {
                let contentRange = NSRange(location: range.location + openLen, length: contentLength)
                textView.textStorage?.addAttribute(.wikiLinkID, value: linkID, range: contentRange)
            }
        }

        textView.didChangeText()
        textView.undoManager?.setActionName(undoActionName)
        textView.breakUndoCoalescing()

        let caretRange = WikiLinkService.caretRangeAfterReplacing(
            displayRange: range,
            with: request.storageFragment
        )
        let documentLength = (textView.string as NSString).length
        let clampedCaret = NSRange(location: min(max(caretRange.location, 0), documentLength), length: 0)

        if let bottomTextView = textView as? NativeTextView {
            bottomTextView.suppressAutoRevealOnce = true
        }
        textView.window?.makeFirstResponder(textView)
        textView.setSelectedRange(clampedCaret)
    }
}
