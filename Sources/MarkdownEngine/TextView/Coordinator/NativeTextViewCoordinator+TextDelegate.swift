//
//  NativeTextViewCoordinator+TextDelegate.swift
//  MarkdownEngine
//
//  Created by Luca Chen on 16.03.26.
//
//  The hot NSTextViewDelegate path: keystroke handling, selection-change
//  reaction, link-click forwarding, and the typing-attributes shim that
//  prevents AppKit from leaking heading paragraphStyle into the trailing
//  extra-line fragment. Restyle scoping (which paragraphs to re-tokenize on
//  each event) lives here too — it sets up the inputs that
//  `+Restyling.swift` then consumes.
//

import AppKit

extension NativeTextViewCoordinator {

    /// Supplies a per-document `UndoManager` to the text view.
    ///
    /// AppKit reuses one `NSTextView` across every open document, so the built-in
    /// view-wide undo manager would blend files together (and used to be wiped on
    /// each switch). Returning a manager keyed on the current `documentId` gives
    /// each file its own undo stack that survives switching away and back.
    /// Returning the *same* instance for a given document on every call is
    /// required — a fresh manager per call breaks undo.
    public func undoManager(for view: NSTextView) -> UndoManager? {
        let key = documentId ?? "__default__"
        if let existing = undoManagers[key] {
            return existing
        }
        let manager = UndoManager()
        undoManagers[key] = manager
        return manager
    }

    /// Drops `documentId`'s undo stack when its switch-away snapshot no longer
    /// matches the text now being loaded (the file was rewritten while switched
    /// away). AppKit's range-based text undo would otherwise corrupt the reloaded
    /// content. Returns `true` if a stack was cleared.
    @discardableResult
    func invalidateUndoIfContentDiverged(for documentId: String, incomingText: String) -> Bool {
        guard let snapshot = undoContentSnapshots[documentId], snapshot != incomingText else {
            return false
        }
        undoManagers[documentId]?.removeAllActions()
        return true
    }

    /// Force base typingAttributes on every change so AppKit's auto-inheritance
    /// can't bleed a heading paragraphStyle into the trailing extra-line
    /// fragment's metrics.
    public func textView(
        _ textView: NSTextView,
        shouldChangeTypingAttributes oldTypingAttributes: [String: Any],
        toAttributes newTypingAttributes: [NSAttributedString.Key: Any]
    ) -> [NSAttributedString.Key: Any] {
        let (baseFont, baseParagraphStyle) = TextStylingService.makeBaseFontAndStyle(
            fontName: fontName,
            fontSize: fontSize,
            layoutBridge: layoutBridge,
            configuration: configuration
        )
        var result = newTypingAttributes
        result[.paragraphStyle] = baseParagraphStyle
        result[.font] = baseFont
        result[.foregroundColor] = configuration.theme.bodyText
        return result
    }

    public func textDidChange(_ notification: Notification) {
        guard let tv = notification.object as? NSTextView else { return }
        // Before the early returns: the first keystroke must hide the placeholder.
        (tv as? NativeTextView)?.refreshPlaceholderVisibility()
        let wtActive = isWritingToolsActive
        if wtActive, wtDetectedMode == .unknown {
            let firstEditLen = tv.textStorage?.editedRange.length ?? 0
            if let sel = wtInitialSelectionRange, sel.length > 0 {
                let threshold = max(10, Int(Double(sel.length) * 0.6))
                wtDetectedMode = firstEditLen >= threshold ? .rewrite : .proofread
            } else {
                wtDetectedMode = .rewrite
            }
        }
        if wtActive && wtDetectedMode == .proofread { return }


        let rawSelRange = tv.selectedRange()
        let fullLength = (tv.string as NSString).length
        guard !tv.hasMarkedText() else { return }
        let safeLocation = min(rawSelRange.location, fullLength)
        let safeSelRange = NSRange(location: safeLocation, length: 0)
        previousCaretLocation = safeSelRange.location
        if !wtActive {
            let storageState = WikiLinkService.makeStorageState(
                from: tv.string,
                existingMetadata: self.wikiLinkMetadata,
                textStorage: tv.textStorage
            )
            self.wikiLinkMetadata = storageState.metadata
            if storageState.storage != self.lastSyncedText {
                DispatchQueue.main.async {
                    self.lastSyncedText = storageState.storage
                    self.text = storageState.storage
                }
            }
        }

        let fullText = tv.string as NSString
        let paragraphRange = fullText.paragraphRange(for: safeSelRange)
        let documentLength = fullText.length
        let nextLocation = min(documentLength, NSMaxRange(paragraphRange))
        let previousParagraph = paragraphRange.location > 0
            ? fullText.paragraphRange(for: NSRange(location: max(0, paragraphRange.location - 1), length: 0))
            : NSRange(location: NSNotFound, length: 0)
        let nextParagraph = nextLocation < documentLength
            ? fullText.paragraphRange(for: NSRange(location: nextLocation, length: 0))
            : NSRange(location: NSNotFound, length: 0)
        let editedRange = pendingEditedRange ?? tv.textStorage?.editedRange ?? safeSelRange
        pendingEditedRange = nil
        let wtEditedFallback: NSRange? = {
            guard wtActive, let sel = wtInitialSelectionRange else { return nil }
            let docLength = fullText.length
            let loc = min(sel.location, docLength)
            let len = min(sel.length, docLength - loc)
            return NSRange(location: loc, length: len)
        }()
        let safeEditedRange: NSRange = {
            if let wtRange = wtEditedFallback { return wtRange }
            return editedRange.location == NSNotFound ? safeSelRange : editedRange
        }()
        let editedParagraphs = paragraphRanges(in: fullText, intersecting: safeEditedRange)
        let paragraphCandidates: [NSRange] = [
            previousParagraph,
            paragraphRange,
            nextParagraph
        ] + editedParagraphs

        let backtickCount = tv.string.components(separatedBy: "```").count - 1
        let codeBlockStructureChanged = backtickCount != previousBacktickCount
        previousBacktickCount = backtickCount

        let parsed = parsedDocument(for: tv.string)
        let tokens = parsed.tokens
        let codeTokens = parsed.codeTokens
        let latexTokens = parsed.latexTokens
        let blockLatexTokens = parsed.blockLatexTokens
        let preEditActiveTokenIndices = pendingPreEditActiveTokenIndices ?? previousActiveTokenIndices
        pendingPreEditActiveTokenIndices = nil

        activeTokenIndices = MarkdownDetection.computeActiveTokenIndices(
            selectionRange: safeSelRange,
            tokens: tokens,
            in: fullText,
            suppressed: !tv.isEditable
        )
        filterImageEmbedActiveTokens(parsed: parsed, text: fullText, selectionLocation: safeSelRange.location)
        updateAutocorrectSettings(
            tv,
            caretLocation: safeSelRange.location,
            codeTokens: codeTokens,
            latexTokens: latexTokens,
            allTokens: tokens
        )

        var effectiveParagraphCandidates = paragraphCandidates
        if codeBlockStructureChanged {
            effectiveParagraphCandidates = [NSRange(location: 0, length: fullText.length)]
        }
        // Always restyle paragraphs containing latex/imageEmbed tokens to avoid stale raw text.
        let latexParagraphs = (latexTokens + blockLatexTokens + parsed.imageEmbedTokens).map { fullText.paragraphRange(for: $0.range) }
        effectiveParagraphCandidates.append(contentsOf: latexParagraphs)
        effectiveParagraphCandidates.append(contentsOf: tokenRestyleParagraphs(
            in: fullText,
            tokens: tokens,
            currentActiveTokenIndices: activeTokenIndices,
            previousActiveTokenIndices: preEditActiveTokenIndices
        ))

        restyleTextView(tv, paragraphCandidates: effectiveParagraphCandidates, tokens: tokens)
        updateCodeBlockSelection(textView: tv, tokens: tokens)
        if wtActive {
            previousActiveTokenIndices = activeTokenIndices
            return
        }
        if let bottomTextView = tv as? NativeTextView,
           let scrollView = tv.enclosingScrollView {
            bottomTextView.recalcOverscroll(for: scrollView, debugTag: "textDidChange")
            (scrollView as? ClampedScrollView)?.clampToInsets()
        }
        previousActiveTokenIndices = activeTokenIndices
    }

    public func textViewDidChangeSelection(_ notification: Notification) {
        guard let tv = notification.object as? NSTextView else { return }
        if isWritingToolsActive { return }
        let selRange = tv.selectedRange()
        let currentEventType = NSApp.currentEvent?.type
        // Mouse-/Wake-Fokus auf Link: kein Preview, erst Navigation. Gilt für alle Nicht-Key-Events.
        if currentEventType != .keyDown,
           selRange.location < (tv.string as NSString).length,
           tv.textStorage?.attribute(.link, at: selRange.location, effectiveRange: nil) != nil {
            isImageEmbedActive = false
            isWikiLinkActive = false
            onInlineSelectionChange?(nil)
            return
        }
        updateSelectionStates(tv)
        let selLoc = selRange.location

        let parsed = parsedDocument(for: tv.string)
        let tokens = parsed.tokens
        let codeTokens = parsed.codeTokens
        let latexTokens = parsed.latexTokens
        let blockLatexTokens = parsed.blockLatexTokens
        let nsText = tv.string as NSString

        let prevActive = activeTokenIndices
        activeTokenIndices = MarkdownDetection.computeActiveTokenIndices(selectionRange: selRange, tokens: tokens, in: nsText, suppressed: !tv.isEditable)
        filterImageEmbedActiveTokens(parsed: parsed, text: nsText, selectionLocation: selRange.location)

        // Snap-back: when the caret LEFT a wiki/image token, re-sync its displayed name to the live target name.
        if selRange.length == 0,
           currentEventType != .leftMouseDragged, currentEventType != .periodic,
           !isProgrammaticEdit, !tv.hasMarkedText() {
            let leftTokens = prevActive.subtracting(activeTokenIndices)
            for idx in leftTokens.sorted() where idx >= 0 && idx < tokens.count {
                let token = tokens[idx]
                guard token.kind == .wikiLink || token.kind == .imageEmbed else { continue }
                if let newCaret = resyncWikiLinkNameOnLeave(tv, token: token, caretLoc: selRange.location) {
                    // Dismiss any inline preview before the early return (the nested setSelectedRange
                    // re-entry recomputes it for the final caret, but clear it here too — mirrors :203-205).
                    isImageEmbedActive = false
                    isWikiLinkActive = false
                    onInlineSelectionChange?(nil)
                    let clamped = min(max(newCaret, 0), (tv.string as NSString).length)
                    // Only re-settle (and suppress the reveal) when the caret actually moved. If the
                    // link was AFTER the caret the location is unchanged → setSelectedRange would be a
                    // no-op that never consumes suppressAutoRevealOnce, leaking it onto the next reveal.
                    if clamped != selRange.location {
                        (tv as? NativeTextView)?.suppressAutoRevealOnce = true
                        tv.setSelectedRange(NSRange(location: clamped, length: 0))
                    }
                    // The snap-back's didChangeText restyles the CARET's paragraph, not the LINK's, so
                    // the link keeps its pre-leave ACTIVE styling (raw [[ ]] stays visible). Restyle the
                    // link's own paragraph (token.range.location is before the in-name edit, so it's
                    // stable) — the caret is now outside, so its markers collapse to a rendered link.
                    let healedNS = tv.string as NSString
                    if healedNS.length > 0 {
                        let linkPara = healedNS.paragraphRange(for: NSRange(location: min(token.range.location, healedNS.length - 1), length: 0))
                        restyleParagraphs([linkPara], in: tv)
                    }
                    return
                }
            }
        }

        updateAutocorrectSettings(
            tv,
            caretLocation: selLoc,
            codeTokens: codeTokens,
            latexTokens: latexTokens,
            allTokens: tokens
        )
        let caretLoc = selRange.location
        let paragraphRange = nsText.paragraphRange(for: NSRange(location: caretLoc, length: 0))

        var paragraphCandidates: [NSRange] = [paragraphRange]
        if paragraphRange.length == 0 && caretLoc > 0 {
            paragraphCandidates.append(nsText.paragraphRange(for: NSRange(location: max(0, caretLoc - 1), length: 0)))
        }
        if let prevLoc = previousCaretLocation, prevLoc != caretLoc {
            let safePrev = min(prevLoc, nsText.length)
            let prevPara = nsText.paragraphRange(for: NSRange(location: safePrev, length: 0))
            paragraphCandidates.append(prevPara)
        }
        // Also restyle paragraphs containing latex/imageEmbed tokens to refresh rendering.
        let latexParagraphs = (latexTokens + blockLatexTokens + parsed.imageEmbedTokens).map { nsText.paragraphRange(for: $0.range) }
        paragraphCandidates.append(contentsOf: latexParagraphs)
        paragraphCandidates.append(contentsOf: tokenRestyleParagraphs(
            in: nsText,
            tokens: tokens,
            currentActiveTokenIndices: activeTokenIndices,
            previousActiveTokenIndices: previousActiveTokenIndices
        ))

        let shouldSkipSelectionRestyle = pendingEditedRange != nil
        let tokensChanged = activeTokenIndices != prevActive
        // Caret crossings in/out of `- [ ]` syntax need a restyle too: task
        // checkboxes aren't tracked as tokens, so `tokensChanged` won't
        // notice them, but the styler suppresses the checkbox glyph while
        // the caret sits inside the syntax. Without this signal a
        // cursor-out (after editing the brackets) leaves the line stuck on
        // raw chars.
        let prevTaskSyntax = previousCaretLocation.flatMap {
            MarkdownStyler.taskSyntaxRange(at: $0, in: tv.string)
        }
        let currentTaskSyntax = MarkdownStyler.taskSyntaxRange(at: selLoc, in: tv.string)
        let taskSyntaxChanged = prevTaskSyntax?.location != currentTaskSyntax?.location
            || prevTaskSyntax?.length != currentTaskSyntax?.length
        // Caret crossings in/out of a thematic-break (HR) line also need a
        // restyle: HR rendering is a pure attribute (no MarkdownToken), so
        // `tokensChanged` won't notice when the caret enters/leaves an
        // `---` / `***` / `___` line. Without this, clicking on a rendered
        // HR wouldn't reveal the source dashes for editing.
        let prevHRLine = previousCaretLocation.flatMap {
            MarkdownStyler.hrLineRange(at: $0, in: tv.string)
        }
        let currentHRLine = MarkdownStyler.hrLineRange(at: selLoc, in: tv.string)
        let hrLineChanged = prevHRLine?.location != currentHRLine?.location
            || prevHRLine?.length != currentHRLine?.length
        // Bullet markers: caret in/out of `- ` syntax flips glyph ↔ raw.
        let prevBulletSyntax = previousCaretLocation.flatMap {
            MarkdownStyler.bulletSyntaxRange(at: $0, in: tv.string)
        }
        let currentBulletSyntax = MarkdownStyler.bulletSyntaxRange(at: selLoc, in: tv.string)
        let bulletSyntaxChanged = prevBulletSyntax?.location != currentBulletSyntax?.location
            || prevBulletSyntax?.length != currentBulletSyntax?.length
        // Mid-drag restyle is suppressed (revealing markers shifts the layout → drag hit-test lands short, dropping trailing chars) and replayed on release.
        let isDragSelecting = currentEventType == .leftMouseDragged || currentEventType == .periodic
        if shouldSkipSelectionRestyle {
            needsRestyleAfterDrag = false // textDidChange restyles this edit cycle.
        } else if isDragSelecting {
            needsRestyleAfterDrag = true
        } else if tokensChanged || taskSyntaxChanged || hrLineChanged || bulletSyntaxChanged || needsRestyleAfterDrag {
            needsRestyleAfterDrag = false
            restyleTextView(tv, paragraphCandidates: paragraphCandidates, tokens: tokens)
        }

        // Auto-select content when clicking (mouse) into a rendered (previously inactive) latex or image embed
        if selRange.length == 0,
           let eventType = currentEventType,
           eventType == .leftMouseUp || eventType == .leftMouseDown {
            let newlyActive = activeTokenIndices.subtracting(previousActiveTokenIndices)
            for idx in newlyActive {
                let token = tokens[idx]
                guard token.kind == .inlineLatex
                    || token.kind == .blockLatex
                    || token.kind == .imageEmbed else {
                    continue
                }
                let selectRange = token.contentRange
                if selectRange.length > 0 {
                    tv.setSelectedRange(selectRange)
                    break
                }
            }
        }

        let nsString = tv.string as NSString
        let selLocation = tv.selectedRange().location
        let inlineContext = inlineTokenContext(
            at: selLocation,
            parsed: parsed,
            codeTokens: codeTokens,
            text: nsText
        )
        let isInsideImageEmbed = {
            guard case .imageEmbed = inlineContext else { return false }
            return true
        }()
        // Preview must only trigger inside the `![[…]]` content area
        let isInsideImageEmbedContent: Bool = {
            guard case .imageEmbed(let token) = inlineContext else { return false }
            let start = token.range.location + 3
            let end = NSMaxRange(token.range) - 2
            return selLocation >= start && selLocation <= end
        }()

        let isTyping = currentEventType == .keyDown
        let imageEmbedShowsInlinePreview = isInsideImageEmbedContent && isTyping
        var inlineSelectionState: InlineSelectionState? = nil
        if let inlineContext {
            let openingMarkerLength = inlineContext.selectionKind == .imageEmbed ? 3 : 2
            let displayRange = selectionDisplayRange(for: inlineContext.token, openingMarkerLength: openingMarkerLength)
            // Image embeds: rebuild the placeholder as the STORAGE form (`![[Name|uuid|width]]`) so
            // NodeLinkPreview's ImageEmbedReference.parse can recover the width on re-pick. The width
            // no longer lives in the editor text — it sits in the `.wikiLinkID` side-channel.
            let placeholder: String
            if case .imageEmbed(let token) = inlineContext {
                let embedName = nsString.substring(with: token.contentRange)
                if let suffix = wikiLinkID(for: token.range), !suffix.isEmpty {
                    placeholder = "![[\(embedName)|\(suffix)]]"
                } else {
                    placeholder = "![[\(embedName)]]"
                }
            } else {
                placeholder = nsString.substring(with: displayRange)
            }
            let storageRange = inlineContext.selectionKind == .wikiLink
                ? storageRange(containingDisplayLocation: selLocation) ?? storageRange(forDisplayRange: displayRange)
                : nil
            let previewRect = tv.viewRect(forCharacterRange: displayRange, using: layoutBridge)
                ?? tv.viewRect(forCharacterRange: tv.selectedRange(), using: layoutBridge)

            let shouldShowInlinePreview =
                inlineContext.selectionKind == .wikiLink
                || (inlineContext.selectionKind == .imageEmbed && imageEmbedShowsInlinePreview)
            if shouldShowInlinePreview, let previewRect {
                let selection = WikiLinkSelection(
                    displayRange: displayRange,
                    storageRange: storageRange,
                    placeholder: placeholder
                )
                inlineSelectionState = InlineSelectionState(kind: inlineContext.selectionKind, selection: selection)
                DispatchQueue.main.async {
                    self.onCaretRectChange?(previewRect)
                }
            }
        }

        DispatchQueue.main.async {
            self.isWikiLinkActive = inlineSelectionState?.kind == .wikiLink
            self.isImageEmbedActive = isInsideImageEmbed
            self.onInlineSelectionChange?(inlineSelectionState)
        }

        self.previousActiveTokenIndices = self.activeTokenIndices
        self.previousCaretLocation = caretLoc

        // Skip during a pending edit — viewRect is stale until textDidChange's restyle runs; otherwise the overlay flashes to the old Y before settling.
        if !shouldSkipSelectionRestyle {
            updateCodeBlockSelection(textView: tv, tokens: tokens)
        }
    }

    public func textView(_ textView: NSTextView, shouldChangeTextIn affectedCharRange: NSRange, replacementString: String?) -> Bool {
        if isProgrammaticEdit { return true }
        if isWritingToolsActive { return true }
        pendingEditedRange = NSRange(location: affectedCharRange.location, length: replacementString?.utf16.count ?? 0)
        let currentLen = (textView.string as NSString).length
        let maxR = affectedCharRange.location + affectedCharRange.length
        if affectedCharRange.location > currentLen || maxR > currentLen {
            pendingPreEditActiveTokenIndices = nil
            return false
        }
        if textView.undoManager?.isUndoing == true || textView.undoManager?.isRedoing == true {
            pendingPreEditActiveTokenIndices = nil
            return true
        }
        let parsed = parsedDocument(for: textView.string)
        pendingPreEditActiveTokenIndices = MarkdownDetection.computeActiveTokenIndices(
            selectionRange: textView.selectedRange(),
            tokens: parsed.tokens,
            in: textView.string as NSString,
            suppressed: !textView.isEditable
        )

        // Block LaTeX auto-wrap: insert newlines to keep $$ on its own line
        if MarkdownInputHandler.handleBlockLatexAutoWrap(
            textView: textView,
            affectedCharRange: affectedCharRange,
            replacementString: replacementString,
            blockLatexTokens: parsed.blockLatexTokens
        ) {
            return false
        }

        if MarkdownInputHandler.handleImageEmbedAutoWrap(
            textView: textView,
            affectedCharRange: affectedCharRange,
            replacementString: replacementString,
            imageEmbedTokens: parsed.imageEmbedTokens
        ) {
            return false
        }

        return MarkdownInputHandler.handleListInsertion(textView: textView, affectedCharRange: affectedCharRange, replacementString: replacementString)
    }

    public func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.insertBacktab(_:)) {
            return handleBacktab(textView)
        }
        return false
    }

    public func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
        // Edit zone: a click on the outer ~30% of a node link's first/last name char places the caret
        // just outside the markers (before '[[' / after ']]') to reveal the source for editing instead
        // of navigating. Editable views only — read-only links must stay navigable.
        if textView.isEditable, let storage = textView.textStorage {
            var linkRange = NSRange(location: NSNotFound, length: 0)
            let editZoneMinNameLength = 3   // 1–2 char names stay fully clickable for navigation
            if storage.attribute(.link, at: charIndex, longestEffectiveRange: &linkRange,
                                 in: NSRange(location: 0, length: storage.length)) != nil,
               linkRange.length >= editZoneMinNameLength {
                // Caret lands on the token's markers (no .link there, so the mouse-on-link guard in
                // textViewDidChangeSelection doesn't suppress the reveal).
                let token = parsedDocument(for: textView.string).tokens
                    .first { $0.kind == .wikiLink && NSLocationInRange(charIndex, $0.range) }
                let edgeFraction: CGFloat = 0.3
                let frac = clickFractionThroughGlyph(textView, charIndex: charIndex)
                if charIndex == linkRange.location, frac.map({ $0 <= edgeFraction }) ?? true {
                    let caret = token?.range.location ?? linkRange.location          // before '[['
                    textView.setSelectedRange(NSRange(location: caret, length: 0))
                    return true
                }
                if charIndex == NSMaxRange(linkRange) - 1, frac.map({ $0 >= 1 - edgeFraction }) ?? true {
                    let caret = token.map { NSMaxRange($0.range) } ?? NSMaxRange(linkRange)  // after ']]'
                    textView.setSelectedRange(NSRange(location: caret, length: 0))
                    return true
                }
            }
        }
        guard let target = WikiLinkService.resolveIdentifier(link: link, textView: textView, at: charIndex) else {
            return false
        }
        // Direkt deaktivieren, bevor der Navigation-Callback läuft.
        self.isWikiLinkActive = false
        DispatchQueue.main.async {
            self.onLinkClick?(target)
        }
        return true
    }

    /// Horizontal fraction (0 = leading, 1 = trailing) of the current click through the glyph at
    /// `charIndex`, or nil if unresolved. Coordinates mirror NativeTextView+CursorRects.
    private func clickFractionThroughGlyph(_ textView: NSTextView, charIndex: Int) -> CGFloat? {
        guard let event = NSApp.currentEvent,
              let tlm = textView.textLayoutManager,
              let tcm = tlm.textContentManager,
              let start = tcm.location(tlm.documentRange.location, offsetBy: charIndex),
              let end = tcm.location(start, offsetBy: 1),
              let range = NSTextRange(location: start, end: end) else { return nil }
        let viewPoint = textView.convert(event.locationInWindow, from: nil)
        let containerX = viewPoint.x - textView.textContainerOrigin.x
        var glyphFrame: CGRect?
        tlm.enumerateTextSegments(in: range, type: .standard, options: []) { _, segFrame, _, _ in
            glyphFrame = segFrame
            return false
        }
        guard let f = glyphFrame, f.width > 0 else { return nil }
        return (containerX - f.minX) / f.width
    }

    func updateSelectionStates(_ tv: NSTextView) {
        let nsText = tv.string as NSString
        let selRange = tv.selectedRange()
        let bus = configuration.services.bus
        let center = NotificationCenter.default
        if let name = bus.selectionBoldDidChange {
            center.post(
                name: name, object: nil,
                userInfo: ["isBold": isSelectionBold(in: nsText, range: selRange)]
            )
        }
        if let name = bus.selectionItalicDidChange {
            center.post(
                name: name, object: nil,
                userInfo: ["isItalic": isSelectionItalic(in: nsText, range: selRange)]
            )
        }
    }

    func handleBacktab(_ textView: NSTextView) -> Bool {
        let nsText = textView.string as NSString
        let caretLoc = textView.selectedRange().location
        let lineRange = nsText.lineRange(for: NSRange(location: caretLoc, length: 0))
        let line = nsText.substring(with: lineRange)

        let pattern = #"^([\t ]*)((\d+)\.|[-•*+])\s"#
        let regex = try? NSRegularExpression(pattern: pattern)
        if let regex = regex,
           let match = regex.firstMatch(in: line, range: NSRange(location: 0, length: line.utf16.count)) {
            let wsRangeLocal = match.range(at: 1)
            let wsString = (line as NSString).substring(with: wsRangeLocal)
            let wsDocStart = lineRange.location + wsRangeLocal.location
            let depth = MarkdownLists.indentLevel(from: wsString)
            // Legacy `\t• ` top-level depth=1 (synthetic tab); new format depth=0.
            let markerString = (line as NSString).substring(with: match.range(at: 2))
            let isLegacyBulletGlyph = markerString.first == "•"
            let minDepth = isLegacyBulletGlyph ? 1 : 0
            if depth <= minDepth {
                return true
            }

            if wsRangeLocal.length > 0 {
                if wsString.hasPrefix("\t") {
                    MarkdownLists.performEdit(textView, replace: NSRange(location: wsDocStart, length: 1), with: "")
                    textView.setSelectedRange(NSRange(location: max(0, caretLoc - 1), length: 0))
                    return true
                } else {
                    var removeCount = 0
                    for ch in wsString {
                        if ch == " " && removeCount < 2 { removeCount += 1 } else { break }
                    }
                    if removeCount == 0 { removeCount = min(2, wsRangeLocal.length) }
                    MarkdownLists.performEdit(textView, replace: NSRange(location: wsDocStart, length: removeCount), with: "")
                    textView.setSelectedRange(NSRange(location: max(0, caretLoc - removeCount), length: 0))
                    return true
                }
            } else {
                return true
            }
        }

        if line.hasPrefix("\t") {
            MarkdownLists.performEdit(textView, replace: NSRange(location: lineRange.location, length: 1), with: "")
            textView.setSelectedRange(NSRange(location: max(0, caretLoc - 1), length: 0))
            return true
        }
        return false
    }

}
