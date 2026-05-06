//
//  NativeTextViewCoordinator+CodeBlocks.swift
//  MarkdownEngine
//
//  Created by Luca Chen on 16.03.26.
//
//  Tracks code-block selections in the document so the host can render the
//  small "copy code" button overlay on top of every fenced code block. Skips
//  blocks the caret is currently inside (`activeTokenIndices`) to avoid the
//  button overlapping the cursor while editing.
//

import AppKit

extension NativeTextViewCoordinator {
    func updateCodeBlockSelection(textView: NSTextView, tokens: [MarkdownToken]? = nil) {
        guard let textContainer = textView.textContainer else {
            onCodeBlockSelectionChange?([])
            return
        }

        if let tokens = tokens {
            cachedCodeBlockTokens = tokens.enumerated()
                .filter { $0.element.kind == .codeBlock }
                .map { (index: $0.offset, token: $0.element) }
        } else if cachedCodeBlockTokens.isEmpty {
            onCodeBlockSelectionChange?([])
            return
        }

        let nsText = textView.string as NSString
        let scrollOffset = textView.enclosingScrollView?.contentView.bounds.origin ?? .zero

        let selections: [CodeBlockSelection] = cachedCodeBlockTokens.compactMap { originalIndex, token in
            guard !activeTokenIndices.contains(originalIndex) else { return nil }
            guard var boundingRect = textView.viewRect(forCharacterRange: token.range, using: layoutBridge) else { return nil }

            boundingRect.origin.x = textView.textContainerOrigin.x - scrollOffset.x
            boundingRect.size.width = textContainer.containerSize.width

            return CodeBlockSelection(
                id: originalIndex,
                rect: boundingRect,
                language: MarkdownTokenizer.extractLanguage(from: token, in: textView.string),
                code: nsText.substring(with: token.contentRange)
            )
        }

        onCodeBlockSelectionChange?(selections)
    }
}
