#if os(macOS)
//
//  CodeBlockButton.swift
//  MarkdownEngine
//
//  Created by Luca Chen on 15.12.25
//  Purpose: Shows a small copy button overlay for each code block.
//

import SwiftUI

/// Position and content of a single fenced code block currently visible in
/// the editor.
///
/// Delivered to embedders through
/// ``NativeTextViewWrapper/onCodeBlockSelectionChange`` so they can overlay
/// a copy button (see ``CodeBlockButton``) at the right place.
public struct CodeBlockSelection: Identifiable, Sendable {
    /// Index of the source token, stable for as long as the block exists.
    public let id: Int
    /// Frame of the rendered code block in the text view's coordinate space.
    public let rect: CGRect
    /// Language tag declared after the opening fence (`` ```swift ``).
    public let language: String?
    /// Plain text content of the block, suitable for putting on the
    /// pasteboard.
    public let code: String

    public init(id: Int, rect: CGRect, language: String?, code: String) {
        self.id = id
        self.rect = rect
        self.language = language
        self.code = code
    }
}

/// Drop-in SwiftUI overlay that renders a small copy-to-pasteboard button
/// in the top-right corner of a fenced code block.
///
/// Embedders typically place one of these per ``CodeBlockSelection`` they
/// receive from the editor. The view positions itself absolutely using
/// ``CodeBlockSelection/rect``.
public struct CodeBlockButton: View {
    /// The code block this button is attached to.
    public let selection: CodeBlockSelection
    /// Vertical inset from the code block's top edge, in points. Positive
    /// values push the button down into the code block.
    public let topInset: CGFloat
    /// Horizontal inset from the code block's trailing edge, in points.
    /// Positive values keep the button inside the code block; negative
    /// values let it overflow into a parent's gutter (the legacy Nodes
    /// look).
    public let trailingInset: CGFloat
    /// Closure invoked when the user clicks the button.
    public let onCopy: () -> Void

    public init(
        selection: CodeBlockSelection,
        topInset: CGFloat = 6,
        trailingInset: CGFloat = 8,
        onCopy: @escaping () -> Void
    ) {
        self.selection = selection
        self.topInset = topInset
        self.trailingInset = trailingInset
        self.onCopy = onCopy
    }

    public var body: some View {
        // Invisible frame matching code block position & size
        Color.clear
            .frame(width: selection.rect.width, height: selection.rect.height)
            .overlay(alignment: .topTrailing) {
                Button(action: onCopy) {
                    HStack(spacing: 6) {
                        if let lang = selection.language, !lang.isEmpty {
                            Text(lang.uppercased())
                                .font(.system(size: 10, weight: .medium))
                                .foregroundColor(.white.opacity(0.8))
                        }
                        Image(systemName: "doc.on.doc")
                            .font(.system(size: 10))
                            .foregroundColor(.white.opacity(0.8))
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.black.opacity(0.3))
                    .cornerRadius(6)
                }
                .buttonStyle(.plain)
                .padding(.top, topInset)
                .padding(.trailing, trailingInset)
            }
            .position(
                x: selection.rect.midX,
                y: selection.rect.midY
            )
    }
}
#endif
