#if os(iOS)
import SwiftUI
import UIKit

/// SwiftUI bridge for MarkdownEngine's editable UIKit live preview.
public struct NativeTextViewWrapper: UIViewRepresentable {
    @Binding public var text: String
    public var configuration: MarkdownEditorConfiguration
    public var fontName: String
    public var fontSize: CGFloat
    public var documentId: String
    public var isEditable: Bool

    public init(
        text: Binding<String>,
        configuration: MarkdownEditorConfiguration = .default,
        fontName: String = "SF Pro",
        fontSize: CGFloat = 16,
        documentId: String = "default",
        isEditable: Bool = true
    ) {
        self._text = text
        self.configuration = configuration
        self.fontName = fontName
        self.fontSize = fontSize
        self.documentId = documentId
        self.isEditable = isEditable
    }

    public func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    public func makeUIView(context: Context) -> UITextView {
        let textView = UITextView(usingTextLayoutManager: true)
        textView.delegate = context.coordinator
        textView.backgroundColor = .clear
        textView.isEditable = isEditable
        textView.isSelectable = true
        textView.isAccessibilityElement = true
        textView.accessibilityIdentifier = "MarkdownEditor"
        textView.accessibilityLabel = "Markdown editor"
        textView.adjustsFontForContentSizeCategory = true
        textView.textContainer.lineFragmentPadding = 0
        textView.keyboardDismissMode = .interactive
        applyLayout(to: textView)
        context.coordinator.render(text, in: textView, preservingSelection: false)
        return textView
    }

    public func updateUIView(_ textView: UITextView, context: Context) {
        context.coordinator.parent = self
        textView.isEditable = isEditable
        applyLayout(to: textView)
        if textView.text != text || context.coordinator.documentId != documentId {
            context.coordinator.documentId = documentId
            context.coordinator.render(text, in: textView, preservingSelection: false)
        } else if context.coordinator.requiresRestyle(configuration: configuration, fontName: fontName, fontSize: fontSize) {
            context.coordinator.render(text, in: textView, preservingSelection: true)
        }
    }

    public func sizeThatFits(_ proposal: ProposedViewSize, uiView: UITextView, context: Context) -> CGSize? {
        guard configuration.heightBehavior == .fitsContent else { return nil }
        let width = proposal.width ?? uiView.bounds.width
        guard width > 0 else { return nil }
        return uiView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
    }

    private func applyLayout(to textView: UITextView) {
        textView.textContainerInset = UIEdgeInsets(
            top: configuration.textInsets.vertical,
            left: configuration.textInsets.horizontal,
            bottom: configuration.textInsets.vertical,
            right: configuration.textInsets.horizontal
        )
        textView.isScrollEnabled = configuration.heightBehavior == .scrolls
    }

    @MainActor
    public final class Coordinator: NSObject, UITextViewDelegate {
        var parent: NativeTextViewWrapper
        var documentId: String
        private var isRendering = false
        private var lastConfiguration = MarkdownEditorConfiguration.default
        private var lastFontName = ""
        private var lastFontSize: CGFloat = 0

        init(parent: NativeTextViewWrapper) {
            self.parent = parent
            self.documentId = parent.documentId
        }

        func requiresRestyle(configuration: MarkdownEditorConfiguration, fontName: String, fontSize: CGFloat) -> Bool {
            lastFontName != fontName || lastFontSize != fontSize || lastConfiguration.rawSourceMode != configuration.rawSourceMode
        }

        func render(_ source: String, in textView: UITextView, preservingSelection: Bool) {
            guard !isRendering else { return }
            isRendering = true
            let selection = preservingSelection ? textView.selectedRange : NSRange(location: 0, length: 0)
            let safeSelection = NSRange(location: min(selection.location, (source as NSString).length), length: 0)
            let styler = UIKitMarkdownStyler(configuration: parent.configuration, fontName: parent.fontName, fontSize: parent.fontSize)
            textView.attributedText = styler.attributedString(for: source, selection: selection)
            textView.selectedRange = preservingSelection ? selection.clamped(to: (source as NSString).length) : safeSelection
            textView.typingAttributes = [
                .font: UIFont(name: parent.fontName, size: parent.fontSize) ?? UIFont.systemFont(ofSize: parent.fontSize),
                .foregroundColor: parent.configuration.theme.bodyText
            ]
            lastConfiguration = parent.configuration
            lastFontName = parent.fontName
            lastFontSize = parent.fontSize
            isRendering = false
            textView.invalidateIntrinsicContentSize()
        }

        public func textViewDidChange(_ textView: UITextView) {
            guard !isRendering else { return }
            parent.text = textView.text
            render(textView.text, in: textView, preservingSelection: true)
        }

        public func textViewDidChangeSelection(_ textView: UITextView) {
            guard !isRendering else { return }
            render(textView.text, in: textView, preservingSelection: true)
        }

        public func textView(
            _ textView: UITextView,
            shouldChangeTextIn range: NSRange,
            replacementText replacement: String
        ) -> Bool {
            guard replacement == "\n", range.length == 0 else { return true }
            let source = textView.text as NSString
            let lineRange = source.lineRange(for: NSRange(location: min(range.location, source.length), length: 0))
            let beforeCaret = NSRange(location: lineRange.location, length: range.location - lineRange.location)
            let prefixText = source.substring(with: beforeCaret)
            guard let expression = try? NSRegularExpression(pattern: #"^(\s*(?:[-+*]|\d+[.)])\s+(?:\[[ xX]\]\s+)?)"#),
                  let match = expression.firstMatch(in: prefixText, range: NSRange(location: 0, length: (prefixText as NSString).length)) else { return true }

            let prefix = (prefixText as NSString).substring(with: match.range(at: 1))
            let remainder = (prefixText as NSString).substring(from: NSMaxRange(match.range(at: 1)))
            let replacementText: String
            let replacementRange: NSRange
            if remainder.trimmingCharacters(in: .whitespaces).isEmpty {
                replacementText = ""
                replacementRange = NSRange(location: lineRange.location, length: prefix.utf16.count)
            } else {
                replacementText = "\n" + nextListPrefix(prefix)
                replacementRange = range
            }

            let mutable = NSMutableString(string: textView.text)
            mutable.replaceCharacters(in: replacementRange, with: replacementText)
            let caret = replacementRange.location + (replacementText as NSString).length
            textView.text = mutable as String
            textView.selectedRange = NSRange(location: caret, length: 0)
            parent.text = mutable as String
            render(mutable as String, in: textView, preservingSelection: true)
            return false
        }

        private func nextListPrefix(_ prefix: String) -> String {
            guard let expression = try? NSRegularExpression(pattern: #"^(\s*)(\d+)([.)])(\s+)"#),
                  let match = expression.firstMatch(in: prefix, range: NSRange(location: 0, length: (prefix as NSString).length)) else {
                return prefix.replacingOccurrences(of: "[x]", with: "[ ]", options: .caseInsensitive)
            }
            let ns = prefix as NSString
            let number = Int(ns.substring(with: match.range(at: 2))) ?? 0
            return ns.substring(with: match.range(at: 1)) + String(number + 1) + ns.substring(with: match.range(at: 3)) + ns.substring(with: match.range(at: 4))
        }
    }
}

private extension NSRange {
    func clamped(to length: Int) -> NSRange {
        let location = min(max(0, self.location), length)
        return NSRange(location: location, length: min(self.length, length - location))
    }
}
#endif
