//
//  IOSMarkdownTextView.swift
//  MarkdownEngine
//
//  UITextView subclass for the iOS markdown editor. Owns the TextKit 2
//  stack and exposes the MarkdownTextViewProtocol surface used by the
//  shared styling pipeline.
//

#if os(iOS)
import UIKit

public final class IOSMarkdownTextView: UITextView {
    var baseFont: UIFont = .systemFont(ofSize: UIFont.systemFontSize)
    weak var layoutBridge: LayoutBridge?
    var configuration: MarkdownEditorConfiguration = .default
}

extension IOSMarkdownTextView: MarkdownTextViewProtocol {
    var markdownTextStorage: NSTextStorage? { textStorage }

    var markdownString: String { text ?? "" }

    var markdownSelectedRange: NSRange { selectedRange }

    func markdownInvalidateDisplay() {
        setNeedsDisplay()
        if let tlm = textLayoutManager {
            tlm.textViewportLayoutController.layoutViewport()
        }
    }
}
#endif
