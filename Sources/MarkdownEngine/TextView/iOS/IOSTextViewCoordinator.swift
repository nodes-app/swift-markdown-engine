//
//  IOSTextViewCoordinator.swift
//  MarkdownEngine
//
//  UITextViewDelegate that drives markdown restyling on iOS.
//  Mirrors the essential restyling logic from NativeTextViewCoordinator
//  (macOS), without the macOS-specific features (Writing Tools, spell
//  policy menu, code-block copy buttons, overscroll).
//

#if os(iOS)
import UIKit
import SwiftUI

public final class IOSTextViewCoordinator: NSObject, UITextViewDelegate {
    @Binding var text: String
    @Binding var isWikiLinkActive: Bool

    var fontName: String
    var fontSize: CGFloat
    var configuration: MarkdownEditorConfiguration = .default
    var documentId: String?
    var layoutBridge: LayoutBridge?

    var onLinkClick: ((String) -> Void)?
    var onInlineSelectionChange: ((InlineSelectionState?) -> Void)?
    var layoutManagerDelegate: IOSMarkdownLayoutManagerDelegate?

    var didInitialFormatting: Bool = false
    var lastSyncedText: String
    var isProgrammaticEdit: Bool = false
    var activeTokenIndices: Set<Int> = []
    var wikiLinkMetadata: [WikiLinkService.RangeKey: WikiLinkService.LinkMetadata] = [:]
    var cachedParsedText: String?
    var cachedParsedDocument: ParsedDocument?
    var lastAppliedInlineReplacementID: UUID?

    struct ParsedDocument {
        let tokens: [MarkdownToken]
    }

    init(
        text: Binding<String>,
        fontName: String,
        fontSize: CGFloat,
        isWikiLinkActive: Binding<Bool>,
        onLinkClick: ((String) -> Void)?,
        onInlineSelectionChange: ((InlineSelectionState?) -> Void)?
    ) {
        _text = text
        self.fontName = fontName
        self.fontSize = fontSize
        _isWikiLinkActive = isWikiLinkActive
        self.onLinkClick = onLinkClick
        self.onInlineSelectionChange = onInlineSelectionChange
        self.lastSyncedText = text.wrappedValue
        super.init()
    }

    // MARK: - Restyling

    func parsedDocument(for text: String) -> ParsedDocument {
        if cachedParsedText == text, let doc = cachedParsedDocument { return doc }
        let doc = ParsedDocument(tokens: MarkdownTokenizer.parseTokens(in: text))
        cachedParsedText = text
        cachedParsedDocument = doc
        return doc
    }

    func rebuildTextStorageAndStyle(_ textView: IOSMarkdownTextView, from storageText: String) {
        let displayState = WikiLinkService.makeDisplayState(from: storageText)
        let displayText = displayState.display
        wikiLinkMetadata = displayState.metadata

        if textView.text != displayText {
            isProgrammaticEdit = true
            textView.text = displayText
            isProgrammaticEdit = false
        }
        lastSyncedText = storageText

        let nsDisplay = displayText as NSString
        let fullRange = NSRange(location: 0, length: nsDisplay.length)
        let (baseFont, paragraph) = TextStylingService.makeBaseFontAndStyle(
            fontName: fontName,
            fontSize: fontSize,
            layoutBridge: layoutBridge,
            configuration: configuration
        )

        textView.textStorage.beginEditing()
        textView.textStorage.removeAttribute(.link, range: fullRange)
        textView.textStorage.setAttributes([
            .font: baseFont,
            .foregroundColor: configuration.theme.bodyText,
            .paragraphStyle: paragraph
        ], range: fullRange)

        let tokens = parsedDocument(for: displayText).tokens
        activeTokenIndices = MarkdownDetection.computeActiveTokenIndices(
            selectionRange: textView.selectedRange,
            tokens: tokens,
            in: nsDisplay
        )

        let ranges = MarkdownStyler.styleAttributes(
            text: displayText,
            fontName: fontName,
            fontSize: fontSize,
            layoutBridge: layoutBridge,
            caretLocation: textView.selectedRange.location,
            activeTokenIndices: activeTokenIndices,
            precomputedTokens: tokens,
            configuration: configuration
        )
        for (range, attrs) in ranges {
            for (key, value) in attrs {
                textView.textStorage.addAttribute(key, value: value, range: range)
            }
        }
        textView.textStorage.endEditing()

        textView.typingAttributes = TextStylingService.makeBaseTypingAttributes(
            font: baseFont,
            paragraphStyle: paragraph,
            theme: configuration.theme
        )
    }

    func restyleAffectedParagraphs(in textView: IOSMarkdownTextView, editedRange: NSRange) {
        let nsText = textView.text as NSString
        guard nsText.length > 0 else { return }

        var paragraphs: [NSRange] = []
        let end = min(NSMaxRange(editedRange), nsText.length)
        var cursor = min(editedRange.location, max(0, nsText.length - 1))
        while cursor < end {
            let para = nsText.paragraphRange(for: NSRange(location: cursor, length: 0))
            paragraphs.append(para)
            let next = NSMaxRange(para)
            if next <= cursor { break }
            cursor = next
        }
        if paragraphs.isEmpty {
            paragraphs.append(nsText.paragraphRange(for: NSRange(location: max(0, nsText.length - 1), length: 0)))
        }

        let tokens = parsedDocument(for: textView.text).tokens
        activeTokenIndices = MarkdownDetection.computeActiveTokenIndices(
            selectionRange: textView.selectedRange,
            tokens: tokens,
            in: nsText
        )

        let (baseFont, paragraphStyle) = TextStylingService.makeBaseFontAndStyle(
            fontName: fontName,
            fontSize: fontSize,
            layoutBridge: layoutBridge,
            configuration: configuration
        )

        TextStylingService.restyle(
            textView: textView,
            layoutBridge: layoutBridge,
            paragraphCandidates: paragraphs,
            baseFont: baseFont,
            paragraphStyle: paragraphStyle,
            caretLocation: textView.selectedRange.location,
            activeTokenIndices: activeTokenIndices,
            wikiLinkIDProvider: { [weak self] range in
                self?.wikiLinkMetadata[WikiLinkService.RangeKey(range)]?.id
            },
            precomputedTokens: tokens,
            configuration: configuration
        )
    }

    // MARK: - Regexes for list input handling

    private static let listRegex = try! NSRegularExpression(
        pattern: #"^\s*((?:(\d+)\.|[-•])(?:\s+\[[ xX]\])?\s+)"#
    )
    private static let leadingWhitespaceRegex = try! NSRegularExpression(pattern: #"^\s*"#)

    // MARK: - Input Handling

    public func textView(_ textView: UITextView, shouldChangeTextIn range: NSRange, replacementText text: String) -> Bool {
        guard !isProgrammaticEdit else { return true }
        let nsText = (textView.text ?? "") as NSString

        // Space: convert "- " at line start to "  • " (2-space indent + bullet)
        if text == " " && range.length == 0 && range.location > 0 {
            let prevCharRange = NSRange(location: range.location - 1, length: 1)
            if nsText.length > prevCharRange.location,
               nsText.substring(with: prevCharRange) == "-" {
                let beforePrev = range.location - 2
                let isAtLineStart = beforePrev < 0
                    || nsText.substring(with: NSRange(location: beforePrev, length: 1)) == "\n"
                if isAtLineStart {
                    // Replace "- " (the "-" + the space we're about to insert) with "  • "
                    // so first-level items match what Enter-continuation produces.
                    performEdit(textView, replace: prevCharRange, with: "  • ")
                    textView.selectedRange = NSRange(location: range.location + 3, length: 0)
                    syncAndRestyle(textView, editedRange: prevCharRange)
                    return false
                }
            }
        }

        // Tab: indent list item by prepending 2 spaces at line start
        if text == "\t" && range.length == 0 {
            let safeLocation = min(range.location, max(0, nsText.length - 1))
            let currentLineRange = nsText.lineRange(for: NSRange(location: safeLocation, length: 0))
            let listLine = nsText.substring(with: currentLineRange)
            if Self.listRegex.firstMatch(in: listLine, range: NSRange(location: 0, length: listLine.utf16.count)) != nil {
                let insertRange = NSRange(location: currentLineRange.location, length: 0)
                performEdit(textView, replace: insertRange, with: "  ")
                textView.selectedRange = NSRange(location: range.location + 2, length: 0)
                syncAndRestyle(textView, editedRange: NSRange(location: currentLineRange.location, length: currentLineRange.length + 2))
                return false
            }
        }

        // Enter: list continuation / exit
        if text == "\n" && range.length == 0 {
            let safeLocation = min(range.location, max(0, nsText.length - 1))
            let currentLineRange = nsText.lineRange(for: NSRange(location: safeLocation, length: 0))
            let listLine = nsText.substring(with: currentLineRange)
            let lineLen = listLine.utf16.count

            if let match = Self.listRegex.firstMatch(in: listLine, range: NSRange(location: 0, length: lineLen)) {
                let afterMarker = match.range.location + match.range.length
                let contentText = (listLine as NSString)
                    .substring(with: NSRange(location: afterMarker, length: lineLen - afterMarker))
                    .trimmingCharacters(in: .whitespacesAndNewlines)

                if contentText.isEmpty {
                    // Empty list item — exit the list
                    var removalLen = afterMarker
                    let lineEnd = currentLineRange.location + currentLineRange.length
                    if lineEnd > currentLineRange.location,
                       nsText.substring(with: NSRange(location: lineEnd - 1, length: 1)) == "\n" {
                        removalLen = min(removalLen, currentLineRange.length - 1)
                    }
                    let removalRange = NSRange(location: currentLineRange.location, length: removalLen)
                    performEdit(textView, replace: removalRange, with: "")
                    textView.selectedRange = NSRange(location: currentLineRange.location, length: 0)
                    syncAndRestyle(textView, editedRange: removalRange)
                    return false
                }

                // Continue the list with a new item
                let leadingWS: String
                if let wsMatch = Self.leadingWhitespaceRegex.firstMatch(
                    in: listLine, range: NSRange(location: 0, length: lineLen)) {
                    leadingWS = (listLine as NSString).substring(with: wsMatch.range)
                } else {
                    leadingWS = ""
                }

                let markerRaw = (listLine as NSString).substring(with: match.range(at: 1))
                let marker = markerRaw.trimmingCharacters(in: .whitespaces)
                let hasCheckbox = marker.range(of: #"\[[ xX]\]"#, options: .regularExpression) != nil
                let newItem: String
                if match.range(at: 2).location != NSNotFound,
                   let n = Int((listLine as NSString).substring(with: match.range(at: 2))) {
                    newItem = hasCheckbox
                        ? "\n\(leadingWS)\(n + 1). [ ] "
                        : "\n\(leadingWS)\(n + 1). "
                } else {
                    let bullet = marker.hasPrefix("•") ? "•" : "-"
                    newItem = hasCheckbox
                        ? "\n\(leadingWS)\(bullet) [ ] "
                        : "\n\(leadingWS)\(bullet) "
                }

                performEdit(textView, replace: range, with: newItem)
                let newCursor = range.location + (newItem as NSString).length
                textView.selectedRange = NSRange(location: newCursor, length: 0)
                syncAndRestyle(textView, editedRange: NSRange(location: range.location, length: (newItem as NSString).length))
                return false
            }
        }

        return true
    }

    private func performEdit(_ textView: UITextView, replace range: NSRange, with string: String) {
        isProgrammaticEdit = true
        textView.textStorage.replaceCharacters(in: range, with: string)
        isProgrammaticEdit = false
    }

    private func syncAndRestyle(_ textView: UITextView, editedRange: NSRange) {
        let displayText = textView.text ?? ""
        let storageState = WikiLinkService.makeStorageState(
            from: displayText,
            existingMetadata: wikiLinkMetadata,
            textStorage: textView.textStorage
        )
        wikiLinkMetadata = storageState.metadata
        if text != storageState.storage { text = storageState.storage }
        lastSyncedText = storageState.storage
        if let tv = textView as? IOSMarkdownTextView {
            restyleAffectedParagraphs(in: tv, editedRange: editedRange)
        }
    }

    // MARK: - UITextViewDelegate

    public func textViewDidChange(_ textView: UITextView) {
        guard !isProgrammaticEdit, let tv = textView as? IOSMarkdownTextView else { return }

        let displayText = textView.text ?? ""
        let storageState = WikiLinkService.makeStorageState(
            from: displayText,
            existingMetadata: wikiLinkMetadata,
            textStorage: textView.textStorage
        )
        wikiLinkMetadata = storageState.metadata
        let storageText = storageState.storage

        if text != storageText {
            text = storageText
        }
        lastSyncedText = storageText

        let editedRange = NSRange(location: 0, length: (displayText as NSString).length)
        restyleAffectedParagraphs(in: tv, editedRange: editedRange)
    }

    public func textViewDidChangeSelection(_ textView: UITextView) {
        guard let tv = textView as? IOSMarkdownTextView else { return }
        let nsText = textView.text as NSString
        let tokens = parsedDocument(for: textView.text ?? "").tokens
        let newActive = MarkdownDetection.computeActiveTokenIndices(
            selectionRange: textView.selectedRange,
            tokens: tokens,
            in: nsText
        )
        guard newActive != activeTokenIndices else { return }
        let previous = activeTokenIndices
        activeTokenIndices = newActive

        // Restyle paragraphs whose active state changed
        var paragraphs: [NSRange] = []
        for idx in newActive.union(previous) where idx < tokens.count {
            paragraphs.append(nsText.paragraphRange(for: tokens[idx].range))
        }
        if !paragraphs.isEmpty {
            let (baseFont, paragraphStyle) = TextStylingService.makeBaseFontAndStyle(
                fontName: fontName,
                fontSize: fontSize,
                layoutBridge: layoutBridge,
                configuration: configuration
            )
            TextStylingService.restyle(
                textView: tv,
                layoutBridge: layoutBridge,
                paragraphCandidates: paragraphs,
                baseFont: baseFont,
                paragraphStyle: paragraphStyle,
                caretLocation: textView.selectedRange.location,
                activeTokenIndices: activeTokenIndices,
                wikiLinkIDProvider: { [weak self] range in
                    self?.wikiLinkMetadata[WikiLinkService.RangeKey(range)]?.id
                },
                precomputedTokens: tokens,
                configuration: configuration
            )
        }

        // Update wiki-link active state
        let isInWikiLink = tokens.enumerated().contains { (i, token) in
            token.kind == .wikiLink && newActive.contains(i)
        }
        if isWikiLinkActive != isInWikiLink {
            isWikiLinkActive = isInWikiLink
        }
    }
}
#endif
