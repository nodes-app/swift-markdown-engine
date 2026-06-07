//
//  NativeTextViewCoordinator.swift
//  MarkdownEngine
//
//  Created by Luca Chen on 18.02.26.
//

// Keeps the editor in sync while you type, updating formatting, selections,
// links, and other editing behavior in one place.
import AppKit
import SwiftUI

/// `NSTextViewDelegate` that bridges ``NativeTextViewWrapper`` and the
/// underlying `NSTextView`.
///
/// The coordinator is created automatically by SwiftUI; embedders never
/// construct one directly. Behaviors that don't fit in the main file live
/// in extensions (Autocorrect, CodeBlocks, Find, InlineSelection,
/// Notifications, Restyling, TextDelegate, WritingTools).
public final class NativeTextViewCoordinator: NSObject, NSTextViewDelegate {
    var documentId: String?
    @Binding var text: String
    @Binding var isWikiLinkActive: Bool
    var fontName: String
    var fontSize: CGFloat
    var configuration: MarkdownEditorConfiguration = .default {
        didSet {
            subscribeToBusNotifications(replacing: oldValue.services.bus)
            subscribeToAppearanceNotification()
        }
    }
    /// Last `EmbeddedImageProvider.fingerprint()` value we've reflected in
    /// the textView's attributes. We cache it here because embedders that
    /// MUTATE the same provider over time (async URL fetches, etc.) would
    /// otherwise fool the wrapper's "did the embedder hand us a new
    /// fingerprint" check — re-reading the same object twice always
    /// returns the current value, regardless of when state changed.
    var lastImageFingerprint: AnyHashable?
    var lastWikiFingerprint: AnyHashable?
    private var busObservers: [NSObjectProtocol] = []
    private var registeredAppearanceObserverName: Notification.Name?
    weak var textView: NSTextView?
    var layoutBridge: LayoutBridge?
    var layoutDelegate: MarkdownLayoutManagerDelegate?
    var onLinkClick: ((String) -> Void)?
    var onCaretRectChange: ((CGRect) -> Void)?
    var onInlineSelectionChange: ((InlineSelectionState?) -> Void)?
    var onCodeBlockSelectionChange: (([CodeBlockSelection]) -> Void)?
    var didInitialFormatting: Bool = false
    /// One-shot guard so `updateCodeBlockSelection` only forces a full-document layout once per document.
    var didEnsureLayoutForCurrentDocument: Bool = false
    var lastSyncedText: String
    var isProgrammaticEdit: Bool = false
    var isWritingToolsActive: Bool = false
    var wtStartDocumentId: String?
    weak var wtChildWindow: NSWindow?
    var wtInitialChildOrigin: CGPoint?
    var wtInitialSelectionRange: NSRange?
    enum WTMode { case unknown, proofread, rewrite }
    var wtDetectedMode: WTMode = .unknown
    var wtUndoObserverTokens: [NSObjectProtocol] = []
    var wtUndoneDuringSession: Bool = false
    var wtPostUndoSnapshot: String?
    var lastAppliedInlineReplacementID: UUID?
    var activeTokenIndices: Set<Int> = []
    var previousActiveTokenIndices: Set<Int> = []
    var wikiLinkMetadata: [WikiLinkService.RangeKey: WikiLinkService.LinkMetadata] = [:]
    var previousBacktickCount: Int = 0

    var pendingEditedRange: NSRange? = nil
    var pendingPreEditActiveTokenIndices: Set<Int>? = nil
    var previousCaretLocation: Int? = nil
    /// Drag-select suppressed a restyle; replayed on the next non-drag selection change.
    var needsRestyleAfterDrag = false

    var cachedCodeBlockTokens: [(index: Int, token: MarkdownToken)] = []
    var cachedParsedText: String?
    var cachedParsedDocument: ParsedDocument?
    // Skip spellcheck property setters when the state wouldn't change.
    var cachedSpellingDisabled: Bool?

    // Mirrors the user's last-known preference for each spell/grammar toggle.
    // `updateAutocorrectSettings` reads these when restoring outside a
    // suppress zone, so caret movement no longer clobbers a manual "off".
    var userPrefersContinuousSpellChecking: Bool = true
    var userPrefersGrammarChecking: Bool = true
    var userPrefersAutomaticSpellingCorrection: Bool = true

    /// Fires after the user toggles a spell/grammar/auto-correction menu item.
    /// Embedders persist the returned policy (e.g. to `UserDefaults`) and feed
    /// it back via ``MarkdownEditorConfiguration/spellChecking`` on next launch.
    var onSpellCheckingPolicyChanged: ((SpellCheckingPolicy) -> Void)?

    var currentSpellCheckingPolicy: SpellCheckingPolicy {
        SpellCheckingPolicy(
            continuousSpellChecking: userPrefersContinuousSpellChecking,
            grammarChecking: userPrefersGrammarChecking,
            automaticSpellingCorrection: userPrefersAutomaticSpellingCorrection
        )
    }

    /// Called from ``NativeTextView`` toggle overrides after `super` flips the
    /// underlying property. Snapshots the text view's state, refreshes the
    /// cache so the next caret move doesn't immediately overwrite it, and
    /// notifies the embedder.
    func didToggleSpellCheckingPolicy(textView: NSTextView) {
        userPrefersContinuousSpellChecking = textView.isContinuousSpellCheckingEnabled
        userPrefersGrammarChecking = textView.isGrammarCheckingEnabled
        userPrefersAutomaticSpellingCorrection = textView.isAutomaticSpellingCorrectionEnabled
        // Invalidate the "didn't change" short-circuit so the next selection
        // update re-applies the preferences cleanly.
        cachedSpellingDisabled = nil
        onSpellCheckingPolicyChanged?(currentSpellCheckingPolicy)
    }

    struct ParsedDocument {
        let tokens: [MarkdownToken]
        let codeTokens: [MarkdownToken]
        let latexTokens: [MarkdownToken]
        let blockLatexTokens: [MarkdownToken]
        let wikiLinkTokens: [MarkdownToken]
        let imageEmbedTokens: [MarkdownToken]
    }

    enum InlineTokenContext {
        case wikiLink(token: MarkdownToken)
        case imageEmbed(token: MarkdownToken)

        var token: MarkdownToken {
            switch self {
            case .wikiLink(let token), .imageEmbed(let token):
                return token
            }
        }

        var selectionKind: InlineSelectionKind {
            switch self {
            case .wikiLink:
                return .wikiLink
            case .imageEmbed:
                return .imageEmbed
            }
        }
    }

    var isImageEmbedActive: Bool = false

    // Inline selection geometry, image-embed activation, and inline-token
    // detection live in `NativeTextViewCoordinator+InlineSelection.swift`.

    init(text: Binding<String>,
         fontName: String,
         fontSize: CGFloat,
         isWikiLinkActive: Binding<Bool>,
         onLinkClick: ((String) -> Void)?,
         onInlineSelectionChange: ((InlineSelectionState?) -> Void)?) {
        _text = text
        self.fontName = fontName
        self.fontSize = fontSize
        _isWikiLinkActive = isWikiLinkActive
        self.onLinkClick = onLinkClick
        self.onCaretRectChange = nil
        self.onInlineSelectionChange = onInlineSelectionChange
        self.lastSyncedText = text.wrappedValue
        super.init()
        // Init + didSet share this helper so the observer tracks whichever service is current.
        subscribeToAppearanceNotification()
    }

    /// (Re)register the syntax-highlighter appearance observer; idempotent and unsubscribes on nil.
    private func subscribeToAppearanceNotification() {
        let target = configuration.services.syntaxHighlighter.appearanceDidChangeNotification
        if registeredAppearanceObserverName == target { return }
        if let current = registeredAppearanceObserverName {
            NotificationCenter.default.removeObserver(self, name: current, object: nil)
        }
        registeredAppearanceObserverName = nil
        guard let name = target else { return }
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleAppearanceChange(_:)),
            name: name,
            object: nil
        )
        registeredAppearanceObserverName = name
    }

    /// Subscribe to whichever bus notification names the current configuration
    /// supplies. Removes any previous subscriptions first so that swapping
    /// configurations at runtime doesn't double-fire handlers.
    private func subscribeToBusNotifications(replacing previous: MarkdownEditorBus) {
        busObservers.forEach(NotificationCenter.default.removeObserver(_:))
        busObservers.removeAll(keepingCapacity: true)

        let bus = configuration.services.bus
        let center = NotificationCenter.default

        if let name = bus.applyBoldRequest {
            busObservers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] notification in
                self?.handleBoldNotification(notification)
            })
        }
        if let name = bus.applyItalicRequest {
            busObservers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] notification in
                self?.handleItalicNotification(notification)
            })
        }
        if let name = bus.applyHeadingRequest {
            busObservers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] notification in
                self?.handleHeadingNotification(notification)
            })
        }
        if let name = bus.findScrollToRange {
            busObservers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] notification in
                self?.handleFindScrollToRange(notification)
            })
        }
        if let name = bus.findClearHighlights {
            busObservers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] notification in
                self?.handleFindClearHighlights(notification)
            })
        }
    }

    // Find-in-document highlight handlers live in
    // `NativeTextViewCoordinator+Find.swift`.

    func wikiLinkID(for range: NSRange) -> String? {
        wikiLinkMetadata[WikiLinkService.RangeKey(range)]?.id
    }

    func storageRange(forDisplayRange range: NSRange) -> NSRange? {
        wikiLinkMetadata[WikiLinkService.RangeKey(range)]?.storageRange
    }

    func storageRange(containingDisplayLocation location: Int) -> NSRange? {
        for (key, value) in wikiLinkMetadata {
            let displayRange = NSRange(location: key.location, length: key.length)
            if NSLocationInRange(location, displayRange) {
                return value.storageRange
            }
        }
        return nil
    }

    // Methods are split across the following extensions:
    //   - +TextDelegate    — NSTextViewDelegate hot path
    //   - +Restyling       — restyle pipeline + parsedDocument cache
    //   - +InlineSelection — inline-token detection + image-embed activation
    //   - +CodeBlocks      — copy-button overlay
    //   - +Find            — find-in-document highlights
    //   - +Notifications   — bus + appearance bridge
    //   - +Autocorrect     — spell/grammar/quote toggles
    //   - +WritingTools    — macOS 15+ Writing Tools session

    deinit {
        NotificationCenter.default.removeObserver(self)
        busObservers.forEach(NotificationCenter.default.removeObserver(_:))
    }
}

extension NSTextView {
    func viewRect(forCharacterRange range: NSRange, using bridge: LayoutBridge?) -> CGRect? {
        guard range.location != NSNotFound,
              let bridge = bridge,
              let textContainer = textContainer else { return nil }
        var boundingRect = bridge.boundingRect(forCharacterRange: range, in: textContainer)
        let containerOrigin = textContainerOrigin
        // Add the column's offset within its container (0 when the text view is the documentView).
        boundingRect.origin.x += containerOrigin.x + frame.origin.x
        boundingRect.origin.y += containerOrigin.y + frame.origin.y
        if let scrollView = enclosingScrollView {
            let contentOffset = scrollView.contentView.bounds.origin
            boundingRect.origin.x -= contentOffset.x
            boundingRect.origin.y -= contentOffset.y
        }
        return boundingRect
    }
}

