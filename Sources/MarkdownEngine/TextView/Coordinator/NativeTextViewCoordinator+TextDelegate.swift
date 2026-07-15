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
        PerfTrace.checkpoint("didIn")
        // Before the early returns: the first keystroke must hide the placeholder.
        (tv as? NativeTextView)?.refreshPlaceholderVisibility()
        // Raw mode: display IS storage — sync the binding, skip the restyle.
        if configuration.rawSourceMode {
            guard !tv.hasMarkedText() else { return }
            if tv.string != lastSyncedText {
                let rawText = tv.string
                DispatchQueue.main.async {
                    self.lastSyncedText = rawText
                    self.text = rawText
                }
            }
            if let bottomTextView = tv as? NativeTextView,
               let scrollView = tv.enclosingScrollView {
                bottomTextView.recalcOverscroll(for: scrollView, debugTag: "textDidChange")
                (scrollView as? ClampedScrollView)?.clampToInsets()
            }
            return
        }
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
        let docString = tv.string
        let fullText = docString as NSString
        let fullLength = fullText.length
        guard !tv.hasMarkedText() else { return }
        let safeLocation = min(rawSelRange.location, fullLength)
        let safeSelRange = NSRange(location: safeLocation, length: 0)
        previousCaretLocation = safeSelRange.location
        PerfTrace.begin(docLength: fullLength)

        // Edit descriptor, hoisted above the wiki sync so both it and the
        // paragraph scoping below share it.
        let editedRange = pendingEditedRange ?? tv.textStorage?.editedRange ?? safeSelRange
        pendingEditedRange = nil
        // Exactly one proposed edit since the last completed cycle means the
        // descriptor describes THIS transition; anything else (interceptor
        // substitutions, IME commits, WT batches) distrusts the fast paths.
        let singleTrackedEdit = pendingEditCount == 1
        pendingEditCount = 0
#if DEBUG
        debugLastEditWasTrusted = singleTrackedEdit
#endif
        let lengthDelta = previousDisplayLength >= 0 ? fullLength - previousDisplayLength : Int.min
        previousDisplayLength = fullLength

        // Parse-cache generation. shouldChangeTextIn already bumped for this
        // mutation and the selection-change re-parsed the post-edit text at
        // that generation; bumping again would force parsedDocument onto its
        // O(doc) byte-compare VERIFY. A trusted length-CHANGING edit already
        // invalidated the pre-edit cache by length, so keep the generation and
        // hit O(1). Same-length/untracked edits still bump — the byte-compare
        // then catches a same-length content change the length check misses.
        if !(singleTrackedEdit && lengthDelta != 0 && lengthDelta != Int.min) {
            parseGeneration &+= 1
        }

        if !wtActive {
            let storageState = PerfTrace.measure("wiki") {
                WikiLinkService.updatedStorageState(
                    displayText: docString,
                    editedRange: editedRange,
                    changeInLength: lengthDelta,
                    previousStorage: lastComputedStorage,
                    previousMetadata: wikiLinkMetadata
                ) ?? WikiLinkService.makeStorageState(
                    from: docString,
                    existingMetadata: wikiLinkMetadata,
                    textStorage: tv.textStorage
                )
            }
            self.wikiLinkMetadata = storageState.metadata
            self.lastComputedStorage = storageState.storage
#if DEBUG
            // Sampled safety net: every 64th keystroke, prove the splice equals
            // a full rebuild. Opt-in (MD_PERF_VERIFY=1) — the O(doc) rebuild
            // spikes pollute the PERF numbers. Remove with PerfTrace after sign-off.
            wikiVerifyCounter &+= 1
            if PerfTrace.verifyEnabled, wikiVerifyCounter % 64 == 0 {
                let reference = WikiLinkService.makeStorageState(
                    from: docString,
                    existingMetadata: wikiLinkMetadata,
                    textStorage: tv.textStorage
                )
                assert(reference.storage == storageState.storage,
                       "wiki incremental splice diverged from full rebuild")
            }
#endif
            if storageState.storage != self.lastSyncedText {
                DispatchQueue.main.async {
                    self.lastSyncedText = storageState.storage
                    self.text = storageState.storage
                }
            }
        }

        let paragraphRange = fullText.paragraphRange(for: safeSelRange)
        let documentLength = fullText.length
        let nextLocation = min(documentLength, NSMaxRange(paragraphRange))
        let previousParagraph = paragraphRange.location > 0
            ? fullText.paragraphRange(for: NSRange(location: max(0, paragraphRange.location - 1), length: 0))
            : NSRange(location: NSNotFound, length: 0)
        let nextParagraph = nextLocation < documentLength
            ? fullText.paragraphRange(for: NSRange(location: nextLocation, length: 0))
            : NSRange(location: NSNotFound, length: 0)
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

        let backtickCount = PerfTrace.measure("backtick") {
            incrementalBacktickCensus(fullText: fullText, editedRange: editedRange,
                                      lengthDelta: lengthDelta, trusted: singleTrackedEdit)
        }
        let codeBlockStructureChanged = backtickCount != previousBacktickCount
        previousBacktickCount = backtickCount

        let parsed = PerfTrace.measure("parse") {
            parsedDocument(for: docString, edit: singleTrackedEdit
                ? ParseEditDescriptor(editedRange: editedRange, delta: lengthDelta)
                : nil)
        }
        let tokens = parsed.tokens
        let codeTokens = parsed.codeTokens
        let latexTokens = parsed.latexTokens
        let blockLatexTokens = parsed.blockLatexTokens
        let preEditActiveTokenIndices = pendingPreEditActiveTokenIndices ?? previousActiveTokenIndices
        pendingPreEditActiveTokenIndices = nil

        activeTokenIndices = PerfTrace.measure("activeTok") {
            activeTokenIndices(parsed: parsed, selection: safeSelRange, in: fullText, suppressed: !tv.isEditable)
        }
        filterImageEmbedActiveTokens(parsed: parsed, text: fullText, selectionLocation: safeSelRange.location)
        updateAutocorrectSettings(
            tv,
            caretLocation: safeSelRange.location,
            codeTokens: codeTokens,
            latexTokens: latexTokens,
            allTokens: tokens
        )

        var effectiveParagraphCandidates = paragraphCandidates
        // An edit touching an extension block fence re-pairs lines arbitrarily
        // far away (exactly like ```), so restyle the whole document. Checked
        // on BOTH sides of the edit: the pre-edit window (captured in
        // shouldChangeTextIn, catches a deleted fence) and the post-edit
        // window (catches a typed/pasted one). No-op with no block extensions.
        let extFenceStructureChanged = pendingExtFenceTouched
            || editWindowTouchesExtensionFence(in: fullText, around: safeEditedRange)
        pendingExtFenceTouched = false
        if codeBlockStructureChanged || extFenceStructureChanged {
            effectiveParagraphCandidates = [NSRange(location: 0, length: fullText.length)]
        }
        // Restyle only latex/imageEmbed paragraphs the EDIT touches (mirrors the
        // table loop below); the caret entering/leaving a formula, which flips
        // rendered↔raw, is covered by tokenRestyleParagraphs. Blanket-restyling
        // every such paragraph made scopeBounds span the whole document, which
        // defeated the per-pass scope culling in the styler.
        let latexParagraphs = PerfTrace.measure("latexMap") { () -> [NSRange] in
            var out: [NSRange] = []
            // Binary-searched slices — the old loops walked each array from
            // the document head to the edit on every keystroke.
            for group in [parsed.classified.inlineLatex, parsed.classified.blockLatex, parsed.classified.imageEmbed] {
                for (_, token) in MarkdownStyler.scopedSlice(group, lo: safeEditedRange.location, hi: NSMaxRange(safeEditedRange))
                where NSIntersectionRange(token.range, safeEditedRange).length > 0 {
                    out.append(fullText.paragraphRange(for: token.range))
                }
            }
            return out
        }
        effectiveParagraphCandidates.append(contentsOf: latexParagraphs)
        // A table renders as ONE image anchored on the block's FIRST paragraph.
        // When an edit touches any of its rows (typing in a row, or a paste
        // that merges into an existing table), the styler re-emits the anchor
        // against the FULL block — restyling only the edited rows would clip
        // that anchor away and the table goes blank until a full restyle.
        // Location-sorted classified tables, binary-searched to the edit.
        var editedTableParagraphs: [NSRange] = []
        for (_, token) in MarkdownStyler.scopedSlice(parsed.classified.table, lo: safeEditedRange.location, hi: NSMaxRange(safeEditedRange))
        where NSIntersectionRange(token.range, safeEditedRange).length > 0 {
            editedTableParagraphs.append(fullText.paragraphRange(for: token.range))
        }
        effectiveParagraphCandidates.append(contentsOf: editedTableParagraphs)
        effectiveParagraphCandidates.append(contentsOf: tokenRestyleParagraphs(
            in: fullText,
            tokens: tokens,
            currentActiveTokenIndices: activeTokenIndices,
            previousActiveTokenIndices: preEditActiveTokenIndices
        ))

        PerfTrace.measure("restyle") { restyleTextView(tv, paragraphCandidates: effectiveParagraphCandidates, tokens: tokens, classified: parsed.classified, blocks: parsed.blocks) }
        PerfTrace.measure("codeSel") { updateCodeBlockSelection(textView: tv, parsed: parsed) }
        if wtActive {
            previousActiveTokenIndices = activeTokenIndices
            PerfTrace.end()
            return
        }
        PerfTrace.measure("overscroll") {
            if let bottomTextView = tv as? NativeTextView,
               let scrollView = tv.enclosingScrollView {
                bottomTextView.recalcOverscroll(for: scrollView, debugTag: "textDidChange")
                (scrollView as? ClampedScrollView)?.clampToInsets()
            }
        }
        previousActiveTokenIndices = activeTokenIndices
        PerfTrace.end()
    }

    public func textViewDidChangeSelection(_ notification: Notification) {
        guard let tv = notification.object as? NSTextView else { return }
        // Raw mode: plain source — no reveal, snap-back, or inline previews.
        if configuration.rawSourceMode { return }
        if isWritingToolsActive { return }
        PerfTrace.checkpoint("selIn")
        defer { PerfTrace.checkpoint("selOut") }
        let selRange = tv.selectedRange()
        let currentEventType = NSApp.currentEvent?.type
        // ONE bridge of the document text — this handler fires on every
        // keystroke (mid-edit) and every caret move, and used to re-copy
        // `tv.string` (O(doc) each) at a dozen separate sites below. The
        // snap-back branch mutates the text and re-reads explicitly.
        let docText = tv.string
        let nsText = docText as NSString
        // Mouse-/Wake-Fokus auf Link: kein Preview, erst Navigation. Gilt für alle Nicht-Key-Events.
        if currentEventType != .keyDown,
           selRange.location < nsText.length,
           tv.textStorage?.attribute(.link, at: selRange.location, effectiveRange: nil) != nil {
            isImageEmbedActive = false
            isWikiLinkActive = false
            onInlineSelectionChange?(nil)
            return
        }
        PerfTrace.measure("selStates") { updateSelectionStates(tv, nsText: nsText) }
        let selLoc = selRange.location

        // Selection change fires BEFORE textDidChange mid-edit: hand the
        // pending descriptor through so this (the keystroke's first post-edit
        // parse) splices in O(edit) instead of scanning the whole document.
        let selectionEdit: ParseEditDescriptor? = {
            guard let pending = pendingEditedRange, pendingEditCount == 1,
                  previousDisplayLength >= 0 else { return nil }
            let delta = nsText.length - previousDisplayLength
            return ParseEditDescriptor(editedRange: pending, delta: delta)
        }()
        // The keystroke's FIRST post-edit parse happens here, not in
        // textDidChange (whose "parse" span then O(1)-hits) — measure it so
        // the printed frame stops understating the real parse cost.
        let parsed = PerfTrace.measure("selParse") { parsedDocument(for: docText, edit: selectionEdit) }
        let tokens = parsed.tokens
        let codeTokens = parsed.codeTokens
        let latexTokens = parsed.latexTokens
        let blockLatexTokens = parsed.blockLatexTokens

        let prevActive = activeTokenIndices
        PerfTrace.measure("selActive") {
            activeTokenIndices = activeTokenIndices(parsed: parsed, selection: selRange, in: nsText, suppressed: !tv.isEditable)
            filterImageEmbedActiveTokens(parsed: parsed, text: nsText, selectionLocation: selRange.location)
        }

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

        PerfTrace.measure("selAuto") {
            updateAutocorrectSettings(
                tv,
                caretLocation: selLoc,
                codeTokens: codeTokens,
                latexTokens: latexTokens,
                allTokens: tokens
            )
        }
        let caretLoc = selRange.location
        let paragraphRange = nsText.paragraphRange(for: NSRange(location: caretLoc, length: 0))

        let shouldSkipSelectionRestyle = pendingEditedRange != nil
        let tokensChanged = activeTokenIndices != prevActive
        // Caret crossings in/out of `- [ ]` syntax need a restyle too: task
        // checkboxes aren't tracked as tokens, so `tokensChanged` won't
        // notice them, but the styler suppresses the checkbox glyph while
        // the caret sits inside the syntax. Without this signal a
        // cursor-out (after editing the brackets) leaves the line stuck on
        // raw chars.
        let prevTaskSyntax = previousCaretLocation.flatMap {
            MarkdownStyler.taskSyntaxRange(at: $0, in: docText)
        }
        let currentTaskSyntax = MarkdownStyler.taskSyntaxRange(at: selLoc, in: docText)
        let taskSyntaxChanged = prevTaskSyntax?.location != currentTaskSyntax?.location
            || prevTaskSyntax?.length != currentTaskSyntax?.length
        // Caret crossings in/out of a thematic-break (HR) line also need a
        // restyle: HR rendering is a pure attribute (no MarkdownToken), so
        // `tokensChanged` won't notice when the caret enters/leaves an
        // `---` / `***` / `___` line. Without this, clicking on a rendered
        // HR wouldn't reveal the source dashes for editing.
        let prevHRLine = previousCaretLocation.flatMap {
            MarkdownStyler.hrLineRange(at: $0, in: docText)
        }
        let currentHRLine = MarkdownStyler.hrLineRange(at: selLoc, in: docText)
        let hrLineChanged = prevHRLine?.location != currentHRLine?.location
            || prevHRLine?.length != currentHRLine?.length
        // Bullet markers: caret in/out of `- ` syntax flips glyph ↔ raw.
        let prevBulletSyntax = previousCaretLocation.flatMap {
            MarkdownStyler.bulletSyntaxRange(at: $0, in: docText)
        }
        let currentBulletSyntax = MarkdownStyler.bulletSyntaxRange(at: selLoc, in: docText)
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
            // Candidates are built ONLY when a restyle actually runs — this
            // used to happen unconditionally on every selection change,
            // including the mid-keystroke one that skips the restyle above.
            var paragraphCandidates: [NSRange] = [paragraphRange]
            if paragraphRange.length == 0 && caretLoc > 0 {
                paragraphCandidates.append(nsText.paragraphRange(for: NSRange(location: max(0, caretLoc - 1), length: 0)))
            }
            if let prevLoc = previousCaretLocation, prevLoc != caretLoc {
                let safePrev = min(prevLoc, nsText.length)
                paragraphCandidates.append(nsText.paragraphRange(for: NSRange(location: safePrev, length: 0)))
            }
            // Latex/imageEmbed tokens only inside the caret/previous-caret
            // paragraphs (binary-searched); the rendered↔raw flip of a token
            // the caret entered or left is covered by tokenRestyleParagraphs.
            // The old blanket map over EVERY formula in the document widened
            // scopeBounds to the whole document on every caret-move restyle,
            // defeating the styler's per-pass culling — O(#formulas) each.
            let scopeLo = paragraphCandidates.map(\.location).min() ?? 0
            let scopeHi = paragraphCandidates.map { NSMaxRange($0) }.max() ?? 0
            for group in [parsed.classified.inlineLatex, parsed.classified.blockLatex, parsed.classified.imageEmbed] {
                for (_, token) in MarkdownStyler.scopedSlice(group, lo: scopeLo, hi: scopeHi) {
                    paragraphCandidates.append(nsText.paragraphRange(for: token.range))
                }
            }
            paragraphCandidates.append(contentsOf: tokenRestyleParagraphs(
                in: nsText,
                tokens: tokens,
                currentActiveTokenIndices: activeTokenIndices,
                previousActiveTokenIndices: previousActiveTokenIndices
            ))
            PerfTrace.measure("selRestyle") {
                restyleTextView(tv, paragraphCandidates: paragraphCandidates, tokens: tokens,
                                classified: parsed.classified, blocks: parsed.blocks)
            }
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

        // Text unchanged past this point (the snap-back branch returned above);
        // only the selection may have moved.
        let selLocation = tv.selectedRange().location
        let inlineContext = PerfTrace.measure("selCtx") {
            inlineTokenContext(
                at: selLocation,
                parsed: parsed,
                codeTokens: codeTokens,
                text: nsText
            )
        }
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
                let embedName = nsText.substring(with: token.contentRange)
                if let suffix = wikiLinkID(for: token.range), !suffix.isEmpty {
                    placeholder = "![[\(embedName)|\(suffix)]]"
                } else {
                    placeholder = "![[\(embedName)]]"
                }
            } else {
                placeholder = nsText.substring(with: displayRange)
            }
            let storageRange = inlineContext.selectionKind == .wikiLink
                ? storageRange(containingDisplayLocation: selLocation) ?? storageRange(forDisplayRange: displayRange)
                : nil
            let previewRect = tv.viewRect(forCharacterRange: displayRange, using: layoutBridge)
                ?? tv.viewRect(forCharacterRange: tv.selectedRange(), using: layoutBridge)

            // Only autocomplete while TYPING — not when the caret merely lands in an existing link via
            // a click (mirrors the image-embed gate). Clicking into a complete [[Name]] shouldn't pop
            // the picker; typing a name does.
            let shouldShowInlinePreview =
                (inlineContext.selectionKind == .wikiLink && isTyping)
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
            updateCodeBlockSelection(textView: tv, parsed: parsed)
        }
    }

    /// Whether the line-expanded window around `range` contains a registered
    /// extension block fence. O(edit window) — the lines touched by the edit,
    /// not the document.
    func editWindowTouchesExtensionFence(in text: NSString, around range: NSRange) -> Bool {
        let fences = cachedExtensionRegistry.blockEntries
        guard !fences.isEmpty else { return false }
        guard range.location != NSNotFound, range.location >= 0,
              NSMaxRange(range) <= text.length else { return false }
        let window = text.lineRange(for: range)
        let windowText = text.substring(with: window)
        return fences.contains { windowText.contains($0.fence) }
    }

    /// Backtick census in O(edit window): the greedy ``` count equals
    /// Σ floor(runLen/3) over maximal backtick runs, so an edit only changes
    /// the contribution of runs it touches. `previousBacktickCount` minus the
    /// pre-edit window count (captured in shouldChangeTextIn) plus the
    /// post-edit window count is exact. Any doubt → full scan.
    private func incrementalBacktickCensus(fullText: NSString, editedRange: NSRange,
                                           lengthDelta: Int, trusted: Bool) -> Int {
        defer { pendingBacktickWindow = nil }
        guard trusted, !backtickCensusNeedsRescan,
              let base = pendingBacktickWindow,
              lengthDelta != Int.min,
              base.location == editedRange.location,
              editedRange.length - lengthDelta == base.oldLength,
              editedRange.location >= 0,
              NSMaxRange(editedRange) <= fullText.length
        else {
            backtickCensusNeedsRescan = false
            return MarkdownDetection.tripleBacktickCount(in: fullText)
        }
        let newWindow = MarkdownDetection.backtickWindowCount(in: fullText, around: editedRange)
        let count = previousBacktickCount - base.oldCount + newWindow
#if DEBUG
        // Opt-in (MD_PERF_VERIFY=1): the full scan is the O(doc) cost this
        // census exists to avoid — as a default-on sample it skews the numbers.
        backtickVerifyCounter &+= 1
        if PerfTrace.verifyEnabled, backtickVerifyCounter % 64 == 0 {
            assert(count == MarkdownDetection.tripleBacktickCount(in: fullText),
                   "incremental backtick census diverged from the full scan")
        }
#endif
        return count
    }

    public func textView(_ textView: NSTextView, shouldChangeTextIn affectedCharRange: NSRange, replacementString: String?) -> Bool {
        // ONE bridge of the pre-edit text — every `textView.string` read is an
        // O(doc) copy of the mutable backing store; this function used to take
        // four of them per keystroke.
        let preText = textView.string
        let preNS = preText as NSString
        // Open the keystroke's PERF frame HERE: the pre-edit parse and the
        // smart-input interceptors below used to run before the frame existed
        // and were invisible in the printed totals.
        PerfTrace.begin(docLength: preNS.length)

        // Pre-edit parse for the interactive path, BEFORE the generation bump:
        // the text is still pre-edit, so this O(1)-hits the cache the previous
        // cycle left behind. Bumping first forced parsedDocument onto its
        // O(doc) byte-compare verify on every ordinary keystroke.
        let outOfBounds = affectedCharRange.location > preNS.length
            || affectedCharRange.location + affectedCharRange.length > preNS.length
        let isUndoRedo = textView.undoManager?.isUndoing == true
            || textView.undoManager?.isRedoing == true
        let interactive = !isProgrammaticEdit && !isWritingToolsActive
            && !configuration.rawSourceMode && !outOfBounds && !isUndoRedo
        let preEditParsed = interactive
            ? PerfTrace.measure("preParse") { parsedDocument(for: preText) }
            : nil

        parseGeneration &+= 1
        // Refresh the descriptor for EVERY proposed edit — including programmatic
        // ones. A smart-input interceptor that suppresses a keystroke and performs
        // a different edit (auto-pair, "->"→"→", Tab indent, list-exit, $$-wrap)
        // would otherwise leave the suppressed edit's descriptor behind, and the
        // wiki splice in textDidChange would corrupt the storage form from it.
        pendingEditedRange = NSRange(location: affectedCharRange.location, length: replacementString?.utf16.count ?? 0)
        pendingEditCount += 1
        // Pre-edit backtick window baseline for the incremental census.
        if affectedCharRange.location >= 0, NSMaxRange(affectedCharRange) <= preNS.length {
            pendingBacktickWindow = (affectedCharRange.location, affectedCharRange.length,
                MarkdownDetection.backtickWindowCount(in: preNS, around: affectedCharRange))
            pendingExtFenceTouched = editWindowTouchesExtensionFence(in: preNS, around: affectedCharRange)
        } else {
            pendingBacktickWindow = nil
            pendingExtFenceTouched = false
        }
        if isProgrammaticEdit { return true }
        if isWritingToolsActive { return true }
        // Raw mode: plain-text editing — no smart Markdown input.
        if configuration.rawSourceMode { return true }
        if outOfBounds {
            pendingPreEditActiveTokenIndices = nil
            return false
        }
        if isUndoRedo {
            pendingPreEditActiveTokenIndices = nil
            return true
        }
        guard let parsed = preEditParsed else { return true }
        pendingPreEditActiveTokenIndices = activeTokenIndices(
            parsed: parsed,
            selection: textView.selectedRange(),
            in: preNS,
            suppressed: !textView.isEditable
        )

        defer { PerfTrace.checkpoint("shouldOut") }
        return PerfTrace.measure("smartInput") {
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

            return MarkdownInputHandler.handleListInsertion(textView: textView, affectedCharRange: affectedCharRange,
                                                            replacementString: replacementString, codeTokens: parsed.codeTokens)
        }
    }

    public func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        // Raw mode: default key handling (no ⇧⇥ outdent, no preview routing).
        if configuration.rawSourceMode { return false }
        if commandSelector == #selector(NSResponder.insertBacktab(_:)) {
            return handleBacktab(textView)
        }
        // While an inline [[…]] / ![[…]] preview is open, route ↑/↓/Enter/Esc to the embedder's
        // autocomplete list (it returns true to consume the key; false → normal editor handling).
        if (isWikiLinkActive || isImageEmbedActive), let handler = onInlinePreviewKey {
            let key: InlinePreviewKey?
            switch commandSelector {
            case #selector(NSResponder.moveUp(_:)): key = .moveUp
            case #selector(NSResponder.moveDown(_:)): key = .moveDown
            case #selector(NSResponder.insertNewline(_:)): key = .confirm   // ⌘↵ → handled in performKeyEquivalent
            case #selector(NSResponder.cancelOperation(_:)): key = .cancel
            default: key = nil
            }
            if let key, handler(key) { return true }
        }
        return false
    }

    public func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
        // Record that the delegate ran this press, so mouseDown's fallback knows
        // AppKit didn't drop the dispatch.
        (textView as? NativeTextView)?.linkClickDidFire = true
        // Edit zone: a click on the outer ~30% of a link's first/last visible char places the caret
        // just outside the markers (before '[[' / '[' , after ']]' / ')') to reveal the source for
        // editing instead of navigating. Applies to both wiki links [[…]] and web links [text](url).
        // Editable views only — read-only links must stay navigable.
        if textView.isEditable, let storage = textView.textStorage {
            var linkRange = NSRange(location: NSNotFound, length: 0)
            let editZoneMinNameLength = 3   // 1–2 char names stay fully clickable for navigation
            if storage.attribute(.link, at: charIndex, longestEffectiveRange: &linkRange,
                                 in: NSRange(location: 0, length: storage.length)) != nil,
               linkRange.length >= editZoneMinNameLength {
                // Caret lands on the token's outer markers ('[['/'[' or ']]'/')'), which carry no
                // .link, so the mouse-on-link guard in textViewDidChangeSelection doesn't suppress
                // the reveal. Web links (.link) get the same edit zone as wiki links (.wikiLink); the
                // .link attribute only spans the visible text, so without the full token range a web
                // link would drop the caret between its brackets instead of just outside them.
                let token = parsedDocument(for: textView.string).tokens
                    .first { ($0.kind == .wikiLink || $0.kind == .link) && NSLocationInRange(charIndex, $0.range) }
                let edgeFraction: CGFloat = 0.3
                let frac = clickFractionThroughGlyph(textView, charIndex: charIndex)
                if charIndex == linkRange.location, frac.map({ $0 <= edgeFraction }) ?? true {
                    let caret = token?.range.location ?? linkRange.location          // before '[[' / '['
                    textView.setSelectedRange(NSRange(location: caret, length: 0))
                    return true
                }
                if charIndex == NSMaxRange(linkRange) - 1, frac.map({ $0 >= 1 - edgeFraction }) ?? true {
                    let caret = token.map { NSMaxRange($0.range) } ?? NSMaxRange(linkRange)  // after ']]' / ')'
                    textView.setSelectedRange(NSRange(location: caret, length: 0))
                    return true
                }
            }
        }
        guard let target = WikiLinkService.resolveIdentifier(link: link, textView: textView, at: charIndex) else {
            // Web link (URL-valued): returning false lets AppKit open the URL
            // (the mouseDown fallback mirrors that). Opening a link is navigation
            // too — flag it so mouseDown restores the pre-click caret.
            (textView as? NativeTextView)?.linkClickDidNavigate = true
            return false
        }
        // Direkt deaktivieren, bevor der Navigation-Callback läuft.
        (textView as? NativeTextView)?.linkClickDidNavigate = true
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

    func updateSelectionStates(_ tv: NSTextView, nsText: NSString? = nil) {
        let nsText = nsText ?? (tv.string as NSString)
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
        if let name = bus.selectionHighlightDidChange {
            center.post(
                name: name, object: nil,
                userInfo: ["isHighlight": isSelectionHighlight(in: nsText, range: selRange)]
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
