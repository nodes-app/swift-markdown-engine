//
//  NativeTextView+WritingTools.swift
//  MarkdownEngine
//
//  Created by Luca Chen on 18.10.26.
//
//  Inline Writing Tools on macOS 27 run through NSTextView's own, undeclared
//  NSWritingToolsCoordinator delegate methods, and three of them have bugs a plain
//  NSTextView shows too (measured on 27.0.1): snapshots taken before a pending
//  display pass, nothing hidden under `.translate`, and a selection not laid out
//  yet. The overrides fix those, record the context offsets the hide needs, and
//  call NSTextView's IMP. The fourth bug is in `WritingToolsEditTrackerFix`. If an
//  SDK ever declares these selectors, the build fails here and they become plain
//  overrides.
//

import AppKit
import ObjectiveC
import os

extension NativeTextView {
    /// The rewrite animates from snapshots of the text view, taken before AppKit's
    /// own pending layout and display ran: the paragraphs being rewritten come out
    /// missing and the text below one rewrite-height off. Finish that pass first.
    @available(macOS 15.2, *)
    @objc(writingToolsCoordinator:requestsPreviewForRect:inContext:completion:)
    func writingToolsCoordinatorSnapshot(_ coordinator: NSWritingToolsCoordinator, for rect: NSRect,
                                         in context: NSWritingToolsCoordinator.Context,
                                         completion: @escaping (NSTextPreview?) -> Void) {
        let selector = #selector(writingToolsCoordinatorSnapshot(_:for:in:completion:))
        guard let method = class_getInstanceMethod(NSTextView.self, selector) else { return completion(nil) }
        window?.displayIfNeeded()
        typealias Snapshot = @convention(c) (NSTextView, Selector, NSWritingToolsCoordinator, NSRect,
                                             NSWritingToolsCoordinator.Context,
                                             @escaping @convention(block) (NSTextPreview?) -> Void) -> Void
        unsafeBitCast(method_getImplementation(method), to: Snapshot.self)(self, selector, coordinator, rect, context, completion)
    }

    /// `.translate` slides a snapshot of the text below the edit into place, and the
    /// delegate has to hide that text meanwhile (NSWritingToolsCoordinator.h).
    /// NSTextView hides nothing, so the real text showed under it: doubled words.
    @available(macOS 15.2, *)
    @objc(writingToolsCoordinator:prepareForTextAnimation:forRange:inContext:completion:)
    func writingToolsCoordinatorPrepare(_ coordinator: NSWritingToolsCoordinator,
                                        for animation: NSWritingToolsCoordinator.TextAnimation, range: NSRange,
                                        in context: NSWritingToolsCoordinator.Context, completion: @escaping () -> Void) {
        if animation == .translate {
            // The range is relative to the context: one paragraph for a proofread.
            if let start = writingToolsContextStarts[context.identifier] {
                hideWritingToolsRemainder(from: start + range.location)
            } else {
                Logger(subsystem: "MarkdownEngine", category: "WritingTools")
                    .fault("no document offset for a Writing Tools context; text below the edit stays visible")
            }
        }
        callTextAnimationSuper(#selector(writingToolsCoordinatorPrepare(_:for:range:in:completion:)),
                               coordinator, animation, range, context, completion)
    }

    @available(macOS 15.2, *)
    @objc(writingToolsCoordinator:finishTextAnimation:forRange:inContext:completion:)
    func writingToolsCoordinatorFinish(_ coordinator: NSWritingToolsCoordinator,
                                       for animation: NSWritingToolsCoordinator.TextAnimation, range: NSRange,
                                       in context: NSWritingToolsCoordinator.Context, completion: @escaping () -> Void) {
        if animation == .translate { showWritingToolsRemainder() }
        callTextAnimationSuper(#selector(writingToolsCoordinatorFinish(_:for:range:in:completion:)),
                               coordinator, animation, range, context, completion)
    }

    /// Proofreading anchors a suggestion's explanation to the paths it asks for in
    /// this completion. NSTextView scrolls the suggestion into view here but lays the
    /// new viewport out only on the next pass, so a suggestion that was off screen
    /// came back with an empty path and the panel anchored to the whole text view.
    @available(macOS 15.2, *)
    @objc(writingToolsCoordinator:selectRanges:inContext:completion:)
    func writingToolsCoordinatorSelect(_ coordinator: NSWritingToolsCoordinator, ranges: [NSValue],
                                       in context: NSWritingToolsCoordinator.Context, completion: @escaping () -> Void) {
        let selector = #selector(writingToolsCoordinatorSelect(_:ranges:in:completion:))
        guard let method = class_getInstanceMethod(NSTextView.self, selector) else { return completion() }
        typealias Select = @convention(c) (NSTextView, Selector, NSWritingToolsCoordinator, NSArray,
                                           NSWritingToolsCoordinator.Context, @escaping @convention(block) () -> Void) -> Void
        unsafeBitCast(method_getImplementation(method), to: Select.self)(self, selector, coordinator, ranges as NSArray, context) { [weak self] in
            self?.textLayoutManager?.textViewportLayoutController.layoutViewport()
            completion()
        }
    }

    /// Records where each context starts in the document while the text still
    /// matches it: a rewrite's context is the whole document, a proofread's the
    /// selected paragraphs, and every range Writing Tools sends is relative to it.
    @available(macOS 15.2, *)
    @objc(writingToolsCoordinator:requestsContextsForScope:completion:)
    func writingToolsCoordinatorContexts(_ coordinator: NSWritingToolsCoordinator,
                                         for scope: NSWritingToolsCoordinator.ContextScope,
                                         completion: @escaping ([NSWritingToolsCoordinator.Context]) -> Void) {
        let selector = #selector(writingToolsCoordinatorContexts(_:for:completion:))
        guard let method = class_getInstanceMethod(NSTextView.self, selector) else { return completion([]) }
        typealias Contexts = @convention(c) (NSTextView, Selector, NSWritingToolsCoordinator, NSWritingToolsCoordinator.ContextScope,
                                             @escaping @convention(block) ([NSWritingToolsCoordinator.Context]) -> Void) -> Void
        unsafeBitCast(method_getImplementation(method), to: Contexts.self)(self, selector, coordinator, scope) { [weak self] contexts in
            if let self {
                self.writingToolsContextStarts = [:]
                for context in contexts {
                    if let start = self.documentStart(of: context) { self.writingToolsContextStarts[context.identifier] = start }
                }
            }
            completion(contexts)
        }
    }

    /// The whole document, or the selection's paragraphs; nil rather than a guess.
    @available(macOS 15.2, *)
    private func documentStart(of context: NSWritingToolsCoordinator.Context) -> Int? {
        let document = string as NSString
        let text = context.attributedString.string
        let length = (text as NSString).length
        guard length > 0, length <= document.length else { return nil }
        if length == document.length { return document.isEqual(to: text) ? 0 : nil }
        let start = selectedRange().location - context.range.location
        guard start >= 0, start + length <= document.length,
              document.substring(with: NSRange(location: start, length: length)) == text else { return nil }
        return start
    }

    @available(macOS 15.2, *)
    private func callTextAnimationSuper(_ selector: Selector, _ coordinator: NSWritingToolsCoordinator,
                                        _ animation: NSWritingToolsCoordinator.TextAnimation, _ range: NSRange,
                                        _ context: NSWritingToolsCoordinator.Context, _ completion: @escaping () -> Void) {
        guard let method = class_getInstanceMethod(NSTextView.self, selector) else { return completion() }
        typealias Animation = @convention(c) (NSTextView, Selector, NSWritingToolsCoordinator, NSWritingToolsCoordinator.TextAnimation,
                                              NSRange, NSWritingToolsCoordinator.Context, @escaping @convention(block) () -> Void) -> Void
        unsafeBitCast(method_getImplementation(method), to: Animation.self)(self, selector, coordinator, animation, range, context, completion)
    }

    /// The rest of the edited paragraph gets a clear foreground; fragments after it
    /// stop drawing (MarkdownTextLayoutFragment checks `writingToolsHiddenRemainder`),
    /// because a clear foreground leaves bullets, bars, code backgrounds and tables.
    private func hideWritingToolsRemainder(from location: Int) {
        showWritingToolsRemainder()
        let document = string as NSString
        guard let tlm = textLayoutManager, let content = tlm.textContentManager, location <= document.length,
              let start = content.location(content.documentRange.location, offsetBy: location) else { return }
        let paragraphEnd = location < document.length
            ? NSMaxRange(document.paragraphRange(for: NSRange(location: location, length: 0))) : location
        let end = content.location(content.documentRange.location, offsetBy: paragraphEnd) ?? start
        guard let tail = NSTextRange(location: start, end: end) else { return }
        if !tail.isEmpty { tlm.addRenderingAttribute(.foregroundColor, value: NSColor.clear, for: tail) }
        writingToolsHiddenRemainder = tail
        redrawLineViews()
    }

    /// Session end or document switch: nothing may stay hidden, no context survives.
    func endWritingToolsHide() {
        showWritingToolsRemainder()
        writingToolsContextStarts = [:]
    }

    private func showWritingToolsRemainder() {
        guard let tail = writingToolsHiddenRemainder else { return }
        writingToolsHiddenRemainder = nil
        if !tail.isEmpty { textLayoutManager?.removeRenderingAttribute(.foregroundColor, for: tail) }
        redrawLineViews()
    }

    /// After a rendering-attribute change NSTextView repaints only its own layer, not
    /// TextKit 2's line views (AppKit itself uses the private `_setTextRangeNeedsDisplay:`).
    private func redrawLineViews() {
        func redraw(_ view: NSView) {
            view.needsDisplay = true
            view.subviews.forEach(redraw)
        }
        redraw(self)
    }
}
