//
//  NativeTextViewWrapper.swift
//  MarkdownEngine
//
//  Created by Luca Chen on 18.02.26.
//

// Brings the editor into SwiftUI and wires up the text view with the
// right setup, styling, and callbacks.
//
// Public selection / replacement value types live in
// `NativeTextViewSelectionTypes.swift`.
import SwiftUI
import AppKit

/// SwiftUI bridge for MarkdownEngine's AppKit-backed editor.
///
/// Wraps a TextKit 2 `NSTextView` inside an `NSScrollView` and exposes a
/// SwiftUI-friendly API of bindings (text, link state, replacement requests)
/// and callback closures (link clicks, caret movement, inline-selection and
/// code-block change notifications). All visual styling and external
/// dependencies are routed through ``MarkdownEditorConfiguration``.
public struct NativeTextViewWrapper: NSViewRepresentable {
    public typealias Coordinator = NativeTextViewCoordinator
    public typealias NSViewType = NSScrollView

    /// Two-way binding to the document text in storage form
    /// (`[[Name|<id>]]` for wiki-links). The engine keeps display and
    /// storage forms in sync internally.
    @Binding public var text: String
    /// Becomes `true` while the caret is inside a `[[Name]]` link's content
    /// range, so embedders can show a contextual UI (e.g. a popover).
    @Binding public var isWikiLinkActive: Bool
    /// Push a replacement into the editor by setting this to a non-nil value;
    /// the engine applies it on the next update and then clears the binding.
    @Binding public var pendingInlineReplacement: InlineReplacementRequest?
    /// The full editor configuration (theme + services + style toggles). Engine
    /// embedders construct this themselves and pass it in; the wrapper does
    /// not read UserDefaults or know about app-specific colors/services.
    public var configuration: MarkdownEditorConfiguration
    /// PostScript name of the base font used for body text.
    public var fontName: String
    /// Base font size in points. Headings, code blocks, and LaTeX are scaled
    /// off this value via ``MarkdownEditorConfiguration``.
    public var fontSize: CGFloat
    /// Opaque document identifier. Changing this invalidates undo history
    /// and resets per-document editor state.
    public var documentId: String
    /// When `false` the editor renders read-only with no caret.
    public var isEditable: Bool
    /// Optional paste hook. Return a Markdown image-embed string (e.g.
    /// `"![[my-image]]"`) to insert at the caret, or `nil` to fall through
    /// to the system's default plain-text paste.
    public var onPasteImage: ((NSPasteboard) -> String?)?

    /// Fires when the user clicks a `[[Name]]` link. The argument is the
    /// resolved opaque identifier (or the display name when no resolver
    /// was supplied).
    public var onLinkClick: ((String) -> Void)?
    /// Fires whenever the caret rect inside an active wiki-link changes,
    /// so embedders can position a follow-the-caret UI.
    public var onCaretRectChange: ((CGRect) -> Void)?
    /// Fires when the caret enters or leaves a `[[Name]]` or `![[…]]`
    /// token. `nil` means the caret is no longer inside such a token.
    public var onInlineSelectionChange: ((InlineSelectionState?) -> Void)?
    /// Fires when the set of visible code blocks changes, so embedders can
    /// overlay copy buttons (see ``CodeBlockButton``).
    public var onCodeBlockSelectionChange: (([CodeBlockSelection]) -> Void)?

    public init(
        text: Binding<String>,
        isWikiLinkActive: Binding<Bool>,
        pendingInlineReplacement: Binding<InlineReplacementRequest?>,
        configuration: MarkdownEditorConfiguration,
        fontName: String,
        fontSize: CGFloat = 16,
        documentId: String,
        isEditable: Bool = true,
        onPasteImage: ((NSPasteboard) -> String?)? = nil,
        onLinkClick: ((String) -> Void)? = nil,
        onCaretRectChange: ((CGRect) -> Void)? = nil,
        onInlineSelectionChange: ((InlineSelectionState?) -> Void)? = nil,
        onCodeBlockSelectionChange: (([CodeBlockSelection]) -> Void)? = nil
    ) {
        self._text = text
        self._isWikiLinkActive = isWikiLinkActive
        self._pendingInlineReplacement = pendingInlineReplacement
        self.configuration = configuration
        self.fontName = fontName
        self.fontSize = fontSize
        self.documentId = documentId
        self.isEditable = isEditable
        self.onPasteImage = onPasteImage
        self.onLinkClick = onLinkClick
        self.onCaretRectChange = onCaretRectChange
        self.onInlineSelectionChange = onInlineSelectionChange
        self.onCodeBlockSelectionChange = onCodeBlockSelectionChange
    }

    public func makeNSView(context: Context) -> NSScrollView {
        let scrollView = ClampedScrollView()
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = configuration.scrollers.hasVerticalScroller
        scrollView.hasHorizontalScroller = configuration.scrollers.hasHorizontalScroller
        scrollView.autohidesScrollers = configuration.scrollers.autohidesScrollers
        scrollView.drawsBackground = false
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.contentInsets = NSEdgeInsets(
            top: configuration.safeAreaInsets.top,
            left: configuration.safeAreaInsets.leading,
            bottom: configuration.safeAreaInsets.bottom,
            right: configuration.safeAreaInsets.trailing
        )

        // Let NSTextView auto-initialize its own TextKit 2 stack via init(frame:).
        let textView = NativeTextView(frame: .zero)

        // Configure the auto-created text container.
        guard let textContainer = textView.textContainer,
              let textLayoutManager = textView.textLayoutManager else {
            fatalError("NSTextView did not create a TextKit 2 stack on this OS version")
        }
        textContainer.lineFragmentPadding = 0
        textContainer.widthTracksTextView = true
        textView.textContainerInset = NSSize(
            width: configuration.textInsets.horizontal,
            height: configuration.textInsets.vertical
        )
        textContainer.heightTracksTextView = false

        let layoutDelegate = MarkdownLayoutManagerDelegate()
        context.coordinator.layoutDelegate = layoutDelegate
        textLayoutManager.delegate = layoutDelegate
        textView.configuration = configuration
        textView.overscrollPercent = configuration.overscroll.percent
        textView.maxOverscrollPoints = configuration.overscroll.maxPoints
        textView.minOverscrollPoints = configuration.overscroll.minPoints
        context.coordinator.configuration = configuration
        textView.insertionPointColor = configuration.theme.bodyText
        textView.isEditable = isEditable
        textView.isSelectable = isEditable
        textView.isRichText = true
        let initialState = WikiLinkService.makeDisplayState(from: text)
        textView.string = initialState.display
        textView.delegate = context.coordinator
        textView.isVerticallyResizable = true
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.postsFrameChangedNotifications = true
        textView.autoresizingMask = [.width]
        textView.backgroundColor = .clear
        let font = NSFont(name: fontName, size: fontSize) ?? NSFont.systemFont(ofSize: fontSize)
        textView.font = font
        textView.baseFont = font
        textView.allowsUndo = true
        textView.isAutomaticSpellingCorrectionEnabled = true
        textView.isContinuousSpellCheckingEnabled = true
        textView.isGrammarCheckingEnabled = true
        textView.isAutomaticQuoteSubstitutionEnabled = true
        textView.isAutomaticDataDetectionEnabled = true
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.onPasteImage = onPasteImage
        if #available(macOS 15.1, *) {
            textView.writingToolsBehavior = .complete
        }
        // Create TextKit 2 layout bridge
        let bridge = LayoutBridge(textLayoutManager)
        context.coordinator.layoutBridge = bridge
        textView.layoutBridge = bridge

        scrollView.documentView = textView
        // Force full-document layout at init so paragraph heights are known
        // upfront; otherwise TextKit 2 viewport layout causes scroll drift.
        textLayoutManager.ensureLayout(for: textLayoutManager.documentRange)

        scrollView.contentView.scroll(to: NSPoint(x: 0, y: -scrollView.contentInsets.top))
        scrollView.clampToInsets()
        scrollView.reflectScrolledClipView(scrollView.contentView)

        context.coordinator.textView = textView
        context.coordinator.wikiLinkMetadata = initialState.metadata
        context.coordinator.onCaretRectChange = onCaretRectChange
        context.coordinator.onInlineSelectionChange = onInlineSelectionChange
        context.coordinator.onCodeBlockSelectionChange = onCodeBlockSelectionChange

        textView.recalcOverscroll(for: scrollView)
        scrollView.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(forName: NSView.frameDidChangeNotification, object: scrollView.contentView, queue: nil) { _ in
            // Only react when the viewport itself resizes (window resize).
            // Without this guard, TextKit-induced textView frame changes echo
            // back here and re-trigger recalcOverscroll, causing a 149pt
            // height oscillation after clicks.
            guard abs(textView.frame.height - scrollView.contentView.bounds.height) > 1 else { return }
            textView.recalcOverscroll(for: scrollView)
            scrollView.clampToInsets()
        }
        NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: scrollView.contentView, queue: nil) { _ in
            (textView as? NativeTextView)?.ensureVisibleLayout()
            if context.coordinator.isWritingToolsActive {
                context.coordinator.fixWritingToolsChildWindowIfNeeded(textView: textView)
            }
            scrollView.clampToInsets()
            context.coordinator.refreshActiveLinkCaretRect()
            context.coordinator.updateCodeBlockSelection(textView: textView)
        }
        return scrollView
    }

    public func updateNSView(_ nsView: NSScrollView, context: Context) {
        guard let textView = nsView.documentView as? NSTextView else { return }

        let isNodeSwitch = context.coordinator.documentId != documentId
        let wtActive: Bool = {
            if #available(macOS 15.0, *), textView.isWritingToolsActive { return true }
            return context.coordinator.isWritingToolsActive
        }()

        if wtActive && isNodeSwitch {
            // User switched files while Writing Tools was active — discard the
            // WT session so it doesn't overwrite the wrong node.
            // Keep wtStartDocumentId so textViewWritingToolsDidEnd can detect the
            // node mismatch and discard the results.
            context.coordinator.isWritingToolsActive = false
        } else if wtActive {
            // WT active on the same node — don't interfere with the session.
            return
        }

        if let bottomTextView = nsView.documentView as? NativeTextView {
            bottomTextView.onPasteImage = onPasteImage
        }
        if nsView.hasVerticalScroller != configuration.scrollers.hasVerticalScroller {
            nsView.hasVerticalScroller = configuration.scrollers.hasVerticalScroller
        }
        if nsView.hasHorizontalScroller != configuration.scrollers.hasHorizontalScroller {
            nsView.hasHorizontalScroller = configuration.scrollers.hasHorizontalScroller
        }
        if nsView.autohidesScrollers != configuration.scrollers.autohidesScrollers {
            nsView.autohidesScrollers = configuration.scrollers.autohidesScrollers
        }
        let desiredTextInset = NSSize(
            width: configuration.textInsets.horizontal,
            height: configuration.textInsets.vertical
        )
        if textView.textContainerInset != desiredTextInset {
            textView.textContainerInset = desiredTextInset
        }
        // Refresh services/theme when the embedder hands us a new configuration
        // (e.g. when the available wiki-link targets change). Cheap pointer-/
        // value-based comparison; full equality isn't required because the
        // embedder is the source of truth.
        if context.coordinator.configuration.services.images.fingerprint()
            != configuration.services.images.fingerprint() {
            context.coordinator.configuration.services = configuration.services
            (nsView.documentView as? NativeTextView)?.configuration.services = configuration.services
        }
        textView.isEditable = isEditable
        textView.isSelectable = isEditable
        textView.insertionPointColor = isEditable ? context.coordinator.configuration.theme.bodyText : .clear
        let fontChanged = (context.coordinator.fontName != fontName) || (context.coordinator.fontSize != fontSize)
        if let pendingInlineReplacement {
            if pendingInlineReplacement.documentId == documentId,
               context.coordinator.lastAppliedInlineReplacementID != pendingInlineReplacement.id {
                context.coordinator.applyInlineReplacement(pendingInlineReplacement, to: textView)
            }
            DispatchQueue.main.async {
                if self.pendingInlineReplacement?.id == pendingInlineReplacement.id {
                    self.pendingInlineReplacement = nil
                }
            }
            return
        }
        if context.coordinator.didInitialFormatting
            && context.coordinator.lastSyncedText == text
            && !fontChanged {
            return
        }
        if fontChanged {
            context.coordinator.didInitialFormatting = false
        }
        if isNodeSwitch {
            context.coordinator.documentId = documentId
            textView.undoManager?.removeAllActions()
            context.coordinator.didInitialFormatting = false
            context.coordinator.resetImageEmbedState()
            // Reset scroll to top of content so the previous file's scrollY
            // doesn't leak into a (potentially shorter) new file.
            nsView.contentView.scroll(to: NSPoint(x: 0, y: -nsView.contentInsets.top))
            nsView.reflectScrolledClipView(nsView.contentView)
            (nsView as? ClampedScrollView)?.clampToInsets()
        }

        let font = NSFont(name: fontName, size: fontSize) ?? NSFont.systemFont(ofSize: fontSize)
        textView.font = font
        if let tv = nsView.documentView as? NativeTextView {
            tv.baseFont = font
            tv.recalcOverscroll(for: nsView)
            (nsView as? ClampedScrollView)?.clampToInsets()
        }

        let displayState = WikiLinkService.makeDisplayState(from: text)
        let displayText = displayState.display
        context.coordinator.wikiLinkMetadata = displayState.metadata
        if textView.string != displayText {
            textView.string = displayText
        }
        context.coordinator.lastSyncedText = text
        let nsDisplay = displayText as NSString
        let fullRange = NSRange(location: 0, length: nsDisplay.length)

        let activeConfiguration = context.coordinator.configuration
        let (baseFont, paragraph) = TextStylingService.makeBaseFontAndStyle(
            fontName: fontName,
            fontSize: fontSize,
            layoutBridge: context.coordinator.layoutBridge,
            configuration: activeConfiguration
        )

        let baseAttrs: [NSAttributedString.Key: Any] = [
            .font: baseFont,
            .foregroundColor: activeConfiguration.theme.bodyText,
            .paragraphStyle: paragraph
        ]
        textView.textStorage?.beginEditing()
        textView.textStorage?.removeAttribute(.link, range: fullRange)
        textView.textStorage?.setAttributes(baseAttrs, range: fullRange)

        let currentCaretLocation = textView.selectedRange().location
        // Reuse the coordinator's tokenize cache.
        let tokens = context.coordinator.parsedDocument(for: displayText).tokens
        let updatedActiveTokenIndices = MarkdownDetection.computeActiveTokenIndices(
            selectionRange: textView.selectedRange(), tokens: tokens, in: nsDisplay
        )
        context.coordinator.activeTokenIndices = updatedActiveTokenIndices

        let ranges = MarkdownStyler.styleAttributes(
            text: displayText,
            fontName: fontName,
            fontSize: fontSize,
            layoutBridge: context.coordinator.layoutBridge,
            caretLocation: currentCaretLocation,
            activeTokenIndices: updatedActiveTokenIndices,
            precomputedTokens: tokens,
            configuration: activeConfiguration
        )
        for (range, attrs) in ranges {
            for (key, value) in attrs {
                textView.textStorage?.addAttribute(key, value: value, range: range)
            }
        }
        textView.textStorage?.endEditing()
        // Reset typingAttributes to body before the layout pass so the phantom end-of-document line doesn't inherit the previous file's heading metrics.
        textView.typingAttributes = TextStylingService.makeBaseTypingAttributes(
            font: baseFont,
            paragraphStyle: paragraph,
            theme: activeConfiguration.theme
        )
        // Force full layout so paragraph heights stay stable after attribute changes.
        if let tlm = textView.textLayoutManager {
            if isNodeSwitch {
                tlm.invalidateLayout(for: tlm.documentRange)
            }
            tlm.ensureLayout(for: tlm.documentRange)
        }
        if let tv = nsView.documentView as? NativeTextView {
            tv.recalcOverscroll(for: nsView)
            (nsView as? ClampedScrollView)?.clampToInsets()
        }
        DispatchQueue.main.async {
            if let tv = nsView.documentView as? NativeTextView {
                context.coordinator.updateCodeBlockSelection(textView: tv)
            }
        }

        textView.typingAttributes = TextStylingService.makeBaseTypingAttributes(
            font: baseFont,
            paragraphStyle: paragraph,
            theme: activeConfiguration.theme
        )

        context.coordinator.fontName = fontName
        context.coordinator.fontSize = fontSize
        context.coordinator.onCaretRectChange = onCaretRectChange
        context.coordinator.onInlineSelectionChange = onInlineSelectionChange
        context.coordinator.onCodeBlockSelectionChange = onCodeBlockSelectionChange
        context.coordinator.didInitialFormatting = true
    }

    public func makeCoordinator() -> Coordinator {
        let coordinator = NativeTextViewCoordinator(
            text: $text,
            fontName: fontName,
            fontSize: fontSize,
            isWikiLinkActive: $isWikiLinkActive,
            onLinkClick: onLinkClick,
            onInlineSelectionChange: onInlineSelectionChange
        )
        coordinator.documentId = documentId
        coordinator.configuration = configuration
        coordinator.onCodeBlockSelectionChange = onCodeBlockSelectionChange
        return coordinator
    }
}
