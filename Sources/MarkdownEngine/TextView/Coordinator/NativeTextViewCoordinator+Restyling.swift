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
            parseGeneration &+= 1
        }
        lastSyncedText = text
        lastComputedStorage = text
        previousDisplayLength = (displayText as NSString).length
        let nsDisplay = displayText as NSString
        // Fresh document baseline: drop the incremental parse state and reseed
        // the backtick census (a stale count from the previous document would
        // force a spurious full-document restyle on the first keystroke).
        parseState.invalidate()
        pendingBacktickWindow = nil
        backtickCensusNeedsRescan = false
        previousBacktickCount = MarkdownDetection.tripleBacktickCount(in: nsDisplay)
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
            let parsed = parsedDocument(for: displayText)
            let tokens = parsed.tokens
            // Hide caret from styling when read-only, else clicks reveal raw token syntax.
            let caretLocation = textView.isEditable ? textView.selectedRange().location : -1
            activeTokenIndices = activeTokenIndices(
                parsed: parsed,
                selection: textView.selectedRange(),
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
                classified: parsed.classified,
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
        tokens: [MarkdownToken]? = nil,
        classified: MarkdownStyler.ClassifiedStyleTokens? = nil,
        blocks: [Block]? = nil
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
            classified: classified,
            precomputedBlocks: blocks,
            configuration: configuration
        )
        // Reconcile wide-table overlays after layout settles.
        if let nativeTextView = textView as? NativeTextView {
            DispatchQueue.main.async { [weak nativeTextView] in
                nativeTextView?.updateWideTableOverlays()
            }
        }
    }

    func parsedDocument(for text: String, edit: ParseEditDescriptor? = nil) -> ParsedDocument {
        let length = (text as NSString).length
        if let cachedParsedDocument, cachedParsedLength == length {
            // O(1) hit: nothing has edited the storage since the cached parse.
            if cachedParseGeneration == parseGeneration { return cachedParsedDocument }
            // Generation moved but the text may still be identical (e.g. an
            // attribute-only pass): confirm via NSString.isEqual (a byte
            // compare — the bridged Swift `==` walked 139k chars per keystroke).
            if let cachedParsedText, (cachedParsedText as NSString).isEqual(to: text) {
                cachedParseGeneration = parseGeneration
                return cachedParsedDocument
            }
        }

        let tokens = parseState.tokens(for: text, edit: edit, registry: cachedExtensionRegistry)
        let tClassify = DispatchTime.now().uptimeNanoseconds
        var codeTokens: [MarkdownToken] = []
        var latexTokens: [MarkdownToken] = []
        var blockLatexTokens: [MarkdownToken] = []
        var wikiLinkTokens: [MarkdownToken] = []
        var imageEmbedTokens: [MarkdownToken] = []
        var tableTokens: [MarkdownToken] = []
        var codeBlockTokensWithIndices: [(index: Int, token: MarkdownToken)] = []
        var inlineLatexIdx: [(index: Int, token: MarkdownToken)] = []
        var blockLatexIdx: [(index: Int, token: MarkdownToken)] = []
        var imageEmbedIdx: [(index: Int, token: MarkdownToken)] = []
        var imageLinkIdx: [(index: Int, token: MarkdownToken)] = []
        var tableIdx: [(index: Int, token: MarkdownToken)] = []

        codeTokens.reserveCapacity(tokens.count / 2)
        latexTokens.reserveCapacity(tokens.count / 4)
        blockLatexTokens.reserveCapacity(tokens.count / 4)
        wikiLinkTokens.reserveCapacity(tokens.count / 4)

        for (index, token) in tokens.enumerated() {
            switch token.kind {
            case .codeBlock, .inlineCode:
                codeTokens.append(token)
                if token.kind == .codeBlock {
                    codeBlockTokensWithIndices.append((index, token))
                }
            case .inlineLatex:
                latexTokens.append(token)
                inlineLatexIdx.append((index, token))
            case .blockLatex:
                blockLatexTokens.append(token)
                blockLatexIdx.append((index, token))
            case .wikiLink:
                wikiLinkTokens.append(token)
            case .imageEmbed:
                imageEmbedTokens.append(token)
                imageEmbedIdx.append((index, token))
            case .imageLink:
                imageLinkIdx.append((index, token))
            case .table:
                tableTokens.append(token)
                tableIdx.append((index, token))
            default:
                break
            }
        }

        parsedDocumentVersion &+= 1
        let parsed = ParsedDocument(
            tokens: tokens,
            blocks: parseState.currentBlocks,
            codeTokens: codeTokens,
            latexTokens: latexTokens,
            blockLatexTokens: blockLatexTokens,
            wikiLinkTokens: wikiLinkTokens,
            imageEmbedTokens: imageEmbedTokens,
            tableTokens: tableTokens,
            codeBlockTokensWithIndices: codeBlockTokensWithIndices,
            classified: MarkdownStyler.ClassifiedStyleTokens(
                inlineLatex: inlineLatexIdx, blockLatex: blockLatexIdx,
                imageEmbed: imageEmbedIdx, imageLink: imageLinkIdx,
                table: tableIdx, code: codeTokens),
            version: parsedDocumentVersion
        )
        cachedParsedText = text
        cachedParsedLength = length
        cachedParseGeneration = parseGeneration
        cachedParsedDocument = parsed
        PerfTrace.note {
            let ms = Double(DispatchTime.now().uptimeNanoseconds - tClassify) / 1_000_000
            return "classify=\(String(format: "%.2f", ms))ms #tokens=\(tokens.count)"
        }
        return parsed
    }

    /// Memoized computeActiveTokenIndices — a pure function of
    /// (parsed.version, selection, suppressed) that otherwise runs up to
    /// three times per keystroke on identical inputs (pre-edit ask,
    /// selection change, textDidChange).
    func activeTokenIndices(parsed: ParsedDocument, selection: NSRange, in text: NSString, suppressed: Bool) -> Set<Int> {
        if let memo = activeTokenMemo, memo.version == parsed.version,
           memo.selection == selection, memo.suppressed == suppressed {
            return memo.result
        }
        let result = MarkdownDetection.computeActiveTokenIndices(
            selectionRange: selection, tokens: parsed.tokens, in: text, suppressed: suppressed)
        activeTokenMemo = (parsed.version, selection, suppressed, result)
        return result
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
        let docText = textView.string      // one O(doc) bridge, reused below
        let parsed = parsedDocument(for: docText)
        let tokens = parsed.tokens
        let nsText = docText as NSString
        activeTokenIndices = activeTokenIndices(
            parsed: parsed,
            selection: textView.selectedRange(),
            in: nsText,
            suppressed: !textView.isEditable
        )
        restyleTextView(textView, paragraphCandidates: paragraphs, tokens: tokens,
                        classified: parsed.classified, blocks: parsed.blocks)
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
