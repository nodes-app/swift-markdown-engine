//
//  IOSTextViewWrapper.swift
//  MarkdownEngine
//
//  SwiftUI bridge for the iOS markdown editor. API mirrors
//  NativeTextViewWrapper (macOS) with iOS-appropriate parameters.
//

#if os(iOS)
import SwiftUI
import UIKit

/// SwiftUI bridge for MarkdownEngine's UIKit-backed editor on iOS.
public struct IOSTextViewWrapper: UIViewRepresentable {
    public typealias Coordinator = IOSTextViewCoordinator

    @Binding public var text: String
    @Binding public var isWikiLinkActive: Bool
    @Binding public var pendingInlineReplacement: InlineReplacementRequest?

    public var configuration: MarkdownEditorConfiguration
    public var fontName: String
    public var fontSize: CGFloat
    public var documentId: String
    public var isEditable: Bool

    public var onLinkClick: ((String) -> Void)?
    public var onInlineSelectionChange: ((InlineSelectionState?) -> Void)?

    public init(
        text: Binding<String>,
        isWikiLinkActive: Binding<Bool> = .constant(false),
        pendingInlineReplacement: Binding<InlineReplacementRequest?> = .constant(nil),
        configuration: MarkdownEditorConfiguration = .default,
        fontName: String = "SF Pro",
        fontSize: CGFloat = 16,
        documentId: String = "default",
        isEditable: Bool = true,
        onLinkClick: ((String) -> Void)? = nil,
        onInlineSelectionChange: ((InlineSelectionState?) -> Void)? = nil
    ) {
        _text = text
        _isWikiLinkActive = isWikiLinkActive
        _pendingInlineReplacement = pendingInlineReplacement
        self.configuration = configuration
        self.fontName = fontName
        self.fontSize = fontSize
        self.documentId = documentId
        self.isEditable = isEditable
        self.onLinkClick = onLinkClick
        self.onInlineSelectionChange = onInlineSelectionChange
    }

    public func makeUIView(context: Context) -> IOSMarkdownTextView {
        let textView = IOSMarkdownTextView()
        textView.configuration = configuration

        // TextKit 2 layout bridge + custom layout fragment delegate (checkboxes)
        if let tlm = textView.textLayoutManager {
            let bridge = LayoutBridge(tlm)
            context.coordinator.layoutBridge = bridge
            textView.layoutBridge = bridge
            let layoutDelegate = IOSMarkdownLayoutManagerDelegate()
            layoutDelegate.theme = configuration.theme
            tlm.delegate = layoutDelegate
            context.coordinator.layoutManagerDelegate = layoutDelegate
        }

        let font = UIFont(name: fontName, size: fontSize) ?? .systemFont(ofSize: fontSize)
        textView.font = font
        textView.baseFont = font
        textView.isEditable = isEditable
        textView.isSelectable = true
        textView.backgroundColor = .clear
        textView.textContainerInset = UIEdgeInsets(
            top: configuration.textInsets.vertical,
            left: configuration.textInsets.horizontal,
            bottom: configuration.textInsets.vertical,
            right: configuration.textInsets.horizontal
        )
        textView.textContainer.lineFragmentPadding = 0
        textView.autocorrectionType = .default
        textView.autocapitalizationType = .sentences
        textView.delegate = context.coordinator

        let displayState = WikiLinkService.makeDisplayState(from: text)
        context.coordinator.wikiLinkMetadata = displayState.metadata
        context.coordinator.rebuildTextStorageAndStyle(textView, from: text)

        return textView
    }

    public func updateUIView(_ uiView: IOSMarkdownTextView, context: Context) {
        let isNodeSwitch = context.coordinator.documentId != documentId
        if isNodeSwitch {
            context.coordinator.documentId = documentId
            context.coordinator.didInitialFormatting = false
            context.coordinator.cachedParsedDocument = nil
            context.coordinator.cachedParsedText = nil
        }

        if let replacement = pendingInlineReplacement,
           replacement.documentId == documentId,
           context.coordinator.lastAppliedInlineReplacementID != replacement.id {
            applyInlineReplacement(replacement, to: uiView, coordinator: context.coordinator)
            DispatchQueue.main.async {
                if self.pendingInlineReplacement?.id == replacement.id {
                    self.pendingInlineReplacement = nil
                }
            }
            return
        }

        let fontChanged = context.coordinator.fontName != fontName || context.coordinator.fontSize != fontSize
        if context.coordinator.didInitialFormatting
            && context.coordinator.lastSyncedText == text
            && !fontChanged {
            return
        }

        let font = UIFont(name: fontName, size: fontSize) ?? .systemFont(ofSize: fontSize)
        uiView.font = font
        uiView.baseFont = font
        context.coordinator.fontName = fontName
        context.coordinator.fontSize = fontSize
        context.coordinator.configuration = configuration

        context.coordinator.rebuildTextStorageAndStyle(uiView, from: text)
        context.coordinator.didInitialFormatting = true

        uiView.isEditable = isEditable
        context.coordinator.onLinkClick = onLinkClick
        context.coordinator.onInlineSelectionChange = onInlineSelectionChange
    }

    public func makeCoordinator() -> Coordinator {
        let coordinator = IOSTextViewCoordinator(
            text: $text,
            fontName: fontName,
            fontSize: fontSize,
            isWikiLinkActive: $isWikiLinkActive,
            onLinkClick: onLinkClick,
            onInlineSelectionChange: onInlineSelectionChange
        )
        coordinator.documentId = documentId
        coordinator.configuration = configuration
        return coordinator
    }

    // MARK: - Inline replacement

    private func applyInlineReplacement(
        _ request: InlineReplacementRequest,
        to textView: IOSMarkdownTextView,
        coordinator: IOSTextViewCoordinator
    ) {
        coordinator.lastAppliedInlineReplacementID = request.id

        let currentText = textView.text as NSString
        let range = request.selection.displayRange
        guard range.location != NSNotFound,
              range.location + range.length <= currentText.length else { return }

        let replacementDisplay: String
        let linkID: String?
        if request.isImageEmbedMode {
            replacementDisplay = request.storageFragment
            linkID = nil
        } else {
            let info = WikiLinkService.displayFragmentAndID(from: request.storageFragment)
            replacementDisplay = info.display
            linkID = info.id
        }

        coordinator.isProgrammaticEdit = true
        defer { coordinator.isProgrammaticEdit = false }

        textView.textStorage.replaceCharacters(in: range, with: replacementDisplay)

        if let linkID, !linkID.isEmpty {
            let contentLength = max(0, (replacementDisplay as NSString).length - 4)
            if contentLength > 0 {
                let contentRange = NSRange(location: range.location + 2, length: contentLength)
                textView.textStorage.addAttribute(.wikiLinkID, value: linkID, range: contentRange)
            }
        }

        let storageState = WikiLinkService.makeStorageState(
            from: textView.text,
            existingMetadata: coordinator.wikiLinkMetadata,
            textStorage: textView.textStorage
        )
        coordinator.wikiLinkMetadata = storageState.metadata
        coordinator.lastSyncedText = storageState.storage

        let caretRange = WikiLinkService.caretRangeAfterReplacing(
            displayRange: range,
            with: request.storageFragment
        )
        let docLen = (textView.text as NSString).length
        let clamped = NSRange(location: min(max(caretRange.location, 0), docLen), length: 0)
        textView.selectedRange = clamped
    }
}
#endif
