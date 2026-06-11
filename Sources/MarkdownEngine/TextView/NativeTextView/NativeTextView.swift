//
//  NativeTextView.swift
//  MarkdownEngine
//
//  Created by Luca Chen on 18.02.26.
//
//  AppKit `NSTextView` subclass used by the markdown editor. Stored state
//  lives here; behavior is split across `NativeTextView+<Feature>.swift`
//  files in this folder (frame & overscroll, caret workarounds, click remap,
//  paste handling, drag-select boost, task checkbox, spelling policy).
//
//  Bottom-overscroll math lives in `BottomOverscrollPolicy.swift`.
//  Pasteboard image inspection lives in `PasteboardImageReader.swift`.
//

import AppKit
import UniformTypeIdentifiers

final class NativeTextView: NSTextView {
    // MARK: Frame & overscroll state
    var baseContentHeight: CGFloat = 0
    var activeBottomOverscroll: CGFloat = 0
    var isApplyingManagedFrameSize = false
    /// Set on switch/resize to force full-layout height measurement until the cascade settles.
    var pendingFullLayoutMeasure = false
    /// Coalesces wide-table overlay updates to once per runloop (resize fires many per frame).
    var pendingWideTableOverlayUpdate = false
    var suppressAutoRevealOnce: Bool = false

    // MARK: Configuration
    var configuration: MarkdownEditorConfiguration = .default {
        didSet {
            overscrollPercent = configuration.overscroll.percent
            maxOverscrollPoints = configuration.overscroll.maxPoints
            minOverscrollPoints = configuration.overscroll.minPoints
        }
    }
    var overscrollPercent: CGFloat = MarkdownEditorConfiguration.default.overscroll.percent
    var maxOverscrollPoints: CGFloat = MarkdownEditorConfiguration.default.overscroll.maxPoints
    var minOverscrollPoints: CGFloat = MarkdownEditorConfiguration.default.overscroll.minPoints

    // MARK: Editor wiring
    var onPasteImage: ((NSPasteboard) -> String?)?
    weak var layoutBridge: LayoutBridge?
    var baseFont: NSFont = NSFont.systemFont(ofSize: NSFont.systemFontSize)

    // MARK: Caret-workaround state
    var caretIndicatorObservation: NSKeyValueObservation?
    weak var observedCaretIndicator: NSView?
    var isApplyingCaretShift: Bool = false

    // MARK: Drag-select state
    var dragStartMouseScreenLoc: NSPoint?

    // MARK: Placeholder state
    /// Click-through ghost-text label shown while the document is empty;
    /// managed by `NativeTextView+Placeholder.swift`.
    weak var placeholderView: PlaceholderLabelView?

    // MARK: Wide-table overlay state
    /// Live NSScrollView per wide table; keyed by source-ID hash.
    var wideTableOverlays: [Int: WideTableOverlay] = [:]
    /// Persisted horizontal scroll offset per wide table; survives restyles.
    var tableHorizontalScrollOffsets: [Int: CGFloat] = [:]

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        // Forward appearance changes to the embedder's highlighter via its registered notification.
        if let name = configuration.services.syntaxHighlighter.appearanceDidChangeNotification {
            NotificationCenter.default.post(name: name, object: self)
        }
    }

    // setMarkedText skips textDidChange, so restyle the marked paragraph to apply markdown attrs.
    override func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        super.setMarkedText(string, selectedRange: selectedRange, replacementRange: replacementRange)
        guard hasMarkedText(),
              let coord = delegate as? NativeTextViewCoordinator else { return }
        let marked = markedRange()
        guard marked.location != NSNotFound, marked.length > 0 else { return }
        let nsText = self.string as NSString
        let paragraph = nsText.paragraphRange(for: marked)
        coord.restyleParagraphs([paragraph], in: self)
    }

    deinit { caretIndicatorObservation?.invalidate() }
}
