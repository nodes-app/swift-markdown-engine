//
//  NativeTextViewCoordinator+WritingTools.swift
//  MarkdownEngine
//
//  Created by Luca Chen on 16.03.26.
//
//  Writing Tools sessions: styling pauses while one runs, its result reaches the
//  binding at the end, and ⌘Z or a document switch ends it, because AppKit's own end
//  replays the session's ranges over whatever text is there by then.
//

import AppKit

extension NativeTextViewCoordinator {
    @available(macOS 15.0, *)
    public func textViewWritingToolsWillBegin(_ textView: NSTextView) {
        let sel = textView.selectedRange()
        resetWritingToolsSession()
        isWritingToolsActive = true
        wtInitialSelectionRange = sel.length > 0 ? sel : nil
        observeUndoNotifications(for: textView.undoManager)
        scheduleChildWindowFix(textView: textView, attemptsRemaining: 20)
    }

    @available(macOS 15.0, *)
    public func textViewWritingToolsDidEnd(_ textView: NSTextView) {
        (textView as? NativeTextView)?.endWritingToolsHide()
        let wasActive = isWritingToolsActive
        let postUndo = wtPostUndoSnapshot
        resetWritingToolsSession()
        // A switch ended the session or waits for this end: the binding already
        // belongs to the next document, so the result is dropped.
        guard wasActive, deferredNodeSwitch == nil else { return }

        // ⌘Z mid-session on 15.1–26: Apple's stale accept action corrupts the text and
        // leaves 0.1pt marker fonts behind; the post-undo snapshot is the true state.
        let sourceText = postUndo ?? textView.string
        let storageState = WikiLinkService.makeStorageState(
            from: sourceText,
            existingMetadata: wikiLinkMetadata,
            textStorage: textView.textStorage
        )
        wikiLinkMetadata = storageState.metadata
        let storage = storageState.storage

        // Binding is already equal to `storage` after undo so SwiftUI won't re-render — rebuild the textView directly.
        if postUndo != nil {
            rebuildTextStorageAndStyle(textView, from: storage)
        }
        // Don't pre-set `lastSyncedText` — leaving it stale lets updateNSView do its
        // normal rebuild (restyle + re-measure) so the accepted WT result stays visible.
        let target = documentId
        DispatchQueue.main.async { [self] in
            guard bindingFollows(target) else { return }
            text = storage
        }
    }

    /// Writing Tools rewrite prose only: code, formulas, links, embeds and tables come
    /// back as written (the zones spell checking skips too).
    @available(macOS 15.0, *)
    public func textView(_ textView: NSTextView,
                         writingToolsIgnoredRangesInEnclosingRange enclosingRange: NSRange) -> [NSValue] {
        parsedDocument(for: textView.string).tokens.compactMap { token in
            switch token.kind {
            case .codeBlock, .inlineCode, .inlineLatex, .blockLatex, .link, .wikiLink, .imageEmbed, .imageLink, .table:
                let range = NSIntersectionRange(token.range, enclosingRange)
                return range.length > 0 ? NSValue(range: range) : nil
            default:
                return nil
            }
        }
    }

    // MARK: - Child window (Done/Original panel) position fix

    private func scheduleChildWindowFix(textView: NSTextView, attemptsRemaining: Int) {
        guard attemptsRemaining > 0, isWritingToolsActive else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            guard let self, self.isWritingToolsActive else { return }
            self.captureChildWindowIfNeeded(textView: textView)
            if self.wtChildWindow == nil {
                self.scheduleChildWindowFix(textView: textView, attemptsRemaining: attemptsRemaining - 1)
            }
        }
    }

    private func captureChildWindowIfNeeded(textView: NSTextView) {
        guard wtChildWindow == nil,
              let mainWindow = textView.window,
              let childWin = mainWindow.childWindows?.first(where: { $0.isVisible }) else { return }
        wtChildWindow = childWin
        wtInitialChildOrigin = childWin.frame.origin
    }

    /// Everything a session leaves on the coordinator, cleared at its start and end and
    /// on a document switch. The proofread path skips `textDidChange`'s own reset of the
    /// pending edit count, which then swallowed the next keystroke's mutation.
    func resetWritingToolsSession() {
        isWritingToolsActive = false
        wtChildWindow = nil
        wtInitialChildOrigin = nil
        wtInitialSelectionRange = nil
        wtDetectedMode = .unknown
        wtPostUndoSnapshot = nil
        stopObservingUndoNotifications()
        pendingEditCount = 0
        pendingEditedRange = nil
    }

    // MARK: - Undo observer

    private func observeUndoNotifications(for undoManager: UndoManager?) {
        stopObservingUndoNotifications()
        guard let um = undoManager else { return }
        let center = NotificationCenter.default
        wtUndoObserverTokens = [
            center.addObserver(forName: .NSUndoManagerDidUndoChange, object: um, queue: .main) { [weak self] _ in
                guard let self, let tv = self.textView, self.isWritingToolsActive else { return }
                // On 27 AppKit's end of the session throws on the undone text; ending it
                // here leaves that text as the result. 15.1–26 recover in didEnd.
                if #available(macOS 15.2, *), let writingTools = tv.writingToolsCoordinator {
                    writingTools.stopWritingTools()
                } else {
                    self.wtPostUndoSnapshot = tv.string
                }
            }
        ]
    }

    private func stopObservingUndoNotifications() {
        wtUndoObserverTokens.forEach(NotificationCenter.default.removeObserver(_:))
        wtUndoObserverTokens.removeAll()
    }

    func fixWritingToolsChildWindowIfNeeded(textView: NSTextView) {
        guard let childWin = wtChildWindow,
              let correctOrigin = wtInitialChildOrigin else { return }

        let frame = childWin.frame
        let needsFix = abs(frame.origin.x - correctOrigin.x) > 0.5 || abs(frame.origin.y - correctOrigin.y) > 0.5
        if needsFix {
            var fixed = frame
            fixed.origin = correctOrigin
            childWin.setFrame(fixed, display: false)
        }
    }

    /// Stops the session (its result is dropped: the document is about to change)
    /// and replays the latest switch once the coordinator leaves `.interactiveStreaming`.
    @available(macOS 15.2, *)
    func deferNodeSwitch(until writingTools: NSWritingToolsCoordinator, replay: @escaping () -> Void) {
        deferredNodeSwitch = replay
        guard deferredNodeSwitchTimer == nil else { return }
        writingTools.stopWritingTools()
        let timer = Timer(timeInterval: 0.05, repeats: true) { [weak self, weak writingTools] timer in
            MainActor.assumeIsolated {
                guard let self else { return timer.invalidate() }
                if let writingTools, writingTools.state == .interactiveStreaming { return }
                let replay = self.deferredNodeSwitch
                self.cancelDeferredNodeSwitch()
                replay?()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        deferredNodeSwitchTimer = timer
    }

    /// Whether text from the text view may still reach the binding. SwiftUI hands over
    /// the next document's binding before a deferred switch reaches the text view, and
    /// an async write can land after a switch.
    func bindingFollows(_ documentId: String?) -> Bool {
        deferredNodeSwitch == nil && documentId == self.documentId
    }

    func cancelDeferredNodeSwitch() {
        deferredNodeSwitchTimer?.invalidate()
        deferredNodeSwitchTimer = nil
        deferredNodeSwitch = nil
    }
}
