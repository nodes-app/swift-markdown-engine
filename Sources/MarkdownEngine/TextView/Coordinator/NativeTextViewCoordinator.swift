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
    /// Remembered scroll offset (`bounds.origin.y`) per `documentId` — saved on
    /// switch-away, restored on switch-back.
    var scrollOffsets: [String: CGFloat] = [:]
    /// Per-`documentId` undo manager. AppKit reuses a single `NSTextView` across
    /// all open documents, so its built-in (view-wide) undo manager would mix
    /// files together. Keying a manager on the current document gives each file
    /// its own undo stack that survives switching away and back. Vended through
    /// the `undoManager(for:)` delegate method; pruned alongside `scrollOffsets`.
    var undoManagers: [String: UndoManager] = [:]
    /// Per-`documentId` content snapshot (storage form) taken on switch-away. On
    /// switch-back a mismatch means the file was rewritten while backgrounded, so
    /// the now-stale undo stack is dropped. Pruned alongside `undoManagers`.
    var undoContentSnapshots: [String: String] = [:]
    @Binding var text: String
    @Binding var isWikiLinkActive: Bool
    var fontName: String
    var fontSize: CGFloat
    var configuration: MarkdownEditorConfiguration = .default {
        didSet {
            subscribeToBusNotifications(replacing: oldValue.services.bus)
            subscribeToAppearanceNotification()
            // Precompiled registry for the per-keystroke parse path — deriving
            // it from the configuration on every keystroke would rebuild the
            // delimiter arrays + fingerprint string each time.
            cachedExtensionRegistry = configuration.extensionRegistry
        }
    }
    /// Memoized `configuration.extensionRegistry` (see didSet).
    var cachedExtensionRegistry: ExtensionRegistry = .empty
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
    /// Owns the scroll-away header (build, content refresh, collapse/expand,
    /// teardown). Created on first reconcile with a non-nil header.
    var headerController: ScrollingHeaderController?
    var layoutBridge: LayoutBridge?
    var layoutDelegate: MarkdownLayoutManagerDelegate?
    var onLinkClick: ((String) -> Void)?
    var onCaretRectChange: ((CGRect) -> Void)?
    /// Embedder hook to build the right-click menu (the engine ships none). Gets the
    /// default menu + current selection range, returns the menu to show.
    var onBuildContextMenu: ((NSMenu, NSRange) -> NSMenu)?
    var onInlineSelectionChange: ((InlineSelectionState?) -> Void)?
    var onInlinePreviewKey: ((InlinePreviewKey) -> Bool)?
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
    /// Backtick census baseline captured in shouldChangeTextIn: the pre-edit
    /// window count around the proposed edit, so textDidChange can update the
    /// census from the edited window alone instead of rescanning the document.
    var pendingBacktickWindow: (location: Int, oldLength: Int, oldCount: Int)?
    /// Whether the PRE-edit text around the pending edit touched a registered
    /// extension block fence — captured in shouldChangeTextIn so a DELETED
    /// fence still forces the full restyle in textDidChange.
    var pendingExtFenceTouched = false
    /// Set when the storage mutated without the census bookkeeping seeing it
    /// (IME composition) — forces the next census back to a full scan.
    var backtickCensusNeedsRescan = false
    /// DEBUG-only sampling counter for verifying the incremental census.
    var backtickVerifyCounter: UInt = 0
    /// Incremental parse state for this editor (buffer + blocks + tokens
    /// evolve together under the edit descriptor).
    let parseState = DocumentParseState()
    /// Monotonic stamp for fresh ParsedDocument builds (see ParsedDocument.version).
    var parsedDocumentVersion: UInt64 = 0
    /// Single-slot memo for computeActiveTokenIndices — it runs up to three
    /// times per keystroke on identical inputs (pre-edit ask, selection
    /// change, textDidChange). Pure function of (version, selection, suppressed).
    var activeTokenMemo: (version: UInt64, selection: NSRange, suppressed: Bool, result: Set<Int>)?

    /// Display-text length after the previous textDidChange — yields the edit's
    /// length delta without retaining the previous text.
    var previousDisplayLength: Int = -1
    /// Storage form computed by the previous wiki sync, kept synchronously
    /// (unlike `lastSyncedText`, which updates via async dispatch and can lag a
    /// keystroke). This is the splice base for the incremental path.
    var lastComputedStorage: String = ""
    /// DEBUG-only sampling counter for verifying splices against full rebuilds.
    var wikiVerifyCounter: UInt = 0

    var pendingEditedRange: NSRange? = nil
    /// Proposed-edit cycles since the last completed textDidChange. Exactly 1
    /// means the hoisted editedRange/lengthDelta describe a single tracked
    /// edit and incremental fast paths may trust them.
    var pendingEditCount = 0
#if DEBUG
    /// Diagnostic: whether the last completed textDidChange ran with a
    /// trusted single-edit descriptor (fast paths). Read by tests.
    var debugLastEditWasTrusted: Bool? = nil
#endif
    var pendingPreEditActiveTokenIndices: Set<Int>? = nil
    var previousCaretLocation: Int? = nil
    /// Drag-select suppressed a restyle; replayed on the next non-drag selection change.
    var needsRestyleAfterDrag = false

    var cachedCodeBlockTokens: [(index: Int, token: MarkdownToken)] = []
    /// Dedupe key of the last emitted code-block selections — identical
    /// (parse version, scroll, width, active-code set) means identical output,
    /// so the second per-keystroke invocation can skip the geometry work.
    var lastCodeSelKey: (UInt64, CGFloat, CGFloat, Set<Int>)?
    var cachedParsedText: String?
    var cachedParsedDocument: ParsedDocument?
    /// Monotonic edit counter: bumped whenever the text storage can have
    /// changed. Lets `parsedDocument` return cache hits in O(1) instead of an
    /// O(doc) string compare. Any code that mutates the storage directly
    /// (bypassing shouldChangeText/textDidChange) must bump this.
    var parseGeneration: UInt64 = 0
    var cachedParseGeneration: UInt64 = .max
    var cachedParsedLength: Int = -1
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
        /// The block list the tokens were derived from — handed to the restyle
        /// so DocumentAST.parse consumes it instead of re-deriving blocks
        /// (full buffer re-extraction + memcmp per keystroke).
        let blocks: [Block]
        let codeTokens: [MarkdownToken]
        let latexTokens: [MarkdownToken]
        let blockLatexTokens: [MarkdownToken]
        let wikiLinkTokens: [MarkdownToken]
        let imageEmbedTokens: [MarkdownToken]
        let tableTokens: [MarkdownToken]
        /// Code-block tokens with their index into `tokens` (active-token
        /// checks need the original index) — collected in the same single
        /// classification pass instead of a per-call full-token filter.
        let codeBlockTokensWithIndices: [(index: Int, token: MarkdownToken)]
        /// Per-kind indexed token arrays for the styler's NSImage passes, built
        /// in the same single classification pass so the passes iterate small
        /// scope-sliced arrays instead of walking every document token.
        let classified: MarkdownStyler.ClassifiedStyleTokens
        /// Bumped only when a FRESH parse builds this document — cache-hit
        /// returns share the version, so (version, selection, suppressed) is
        /// an exact memo key for pure derivations like active-token indices.
        let version: UInt64
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
        if let name = bus.applyHighlightRequest {
            busObservers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] notification in
                self?.handleHighlightNotification(notification)
            })
        }
        if let name = bus.applyStrikethroughRequest {
            busObservers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] notification in
                self?.handleStrikethroughNotification(notification)
            })
        }
        if let name = bus.applyInlineCodeRequest {
            busObservers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] notification in
                self?.handleInlineCodeNotification(notification)
            })
        }
        if let name = bus.applyBlockquoteRequest {
            busObservers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] notification in
                self?.handleBlockquoteNotification(notification)
            })
        }
        if let name = bus.applyUnorderedListRequest {
            busObservers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] notification in
                self?.handleUnorderedListNotification(notification)
            })
        }
        if let name = bus.applyOrderedListRequest {
            busObservers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] notification in
                self?.handleOrderedListNotification(notification)
            })
        }
        if let name = bus.applyLinkRequest {
            busObservers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] notification in
                self?.handleLinkNotification(notification)
            })
        }
        if let name = bus.applyCodeBlockRequest {
            busObservers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] notification in
                self?.handleCodeBlockNotification(notification)
            })
        }
        if let name = bus.applyHorizontalRuleRequest {
            busObservers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] notification in
                self?.handleHorizontalRuleNotification(notification)
            })
        }
        if let name = bus.applyImageRequest {
            busObservers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] notification in
                self?.handleImageNotification(notification)
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
        if let name = bus.findQuery {
            busObservers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] notification in
                self?.handleFindQuery(notification)
            })
        }
        if let name = bus.replaceCurrent {
            busObservers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] notification in
                self?.handleReplaceCurrent(notification)
            })
        }
        if let name = bus.replaceAll {
            busObservers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] notification in
                self?.handleReplaceAll(notification)
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
        boundingRect.origin.x += containerOrigin.x
        boundingRect.origin.y += containerOrigin.y
        // The text view sits inside a container document view, offset by the header
        // band (y) and the reading-column centering (x), so its glyph rects
        // (text-view-local) must be lifted into the document view's space before
        // subtracting the scroll offset (which is in document-view space).
        // `convert(.zero, to: doc)` covers both offsets and self-zeroes if this text
        // view ever IS the document view.
        if let scrollView = enclosingScrollView {
            if let doc = scrollView.documentView, doc !== self {
                let originInDoc = convert(CGPoint.zero, to: doc)
                boundingRect.origin.x += originInDoc.x
                boundingRect.origin.y += originInDoc.y
            }
            let contentOffset = scrollView.contentView.bounds.origin
            boundingRect.origin.x -= contentOffset.x
            boundingRect.origin.y -= contentOffset.y
        }
        return boundingRect
    }
}

