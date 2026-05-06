//
//  NativeTextView+PasteHandling.swift
//  MarkdownEngine
//
//  Created by Luca Chen on 16.03.26.
//
//

import AppKit

extension NativeTextView {
    private static let pastableTextExtensions: Set<String> = [
        "md", "markdown", "mdown", "mkd", "txt", "text"
    ]

    override func paste(_ sender: Any?) {
        guard isEditable else {
            super.paste(sender)
            return
        }

        let pasteboard = NSPasteboard.general

        if let imageEmbed = onPasteImage?(pasteboard), !imageEmbed.isEmpty {
            insertBlockEmbed(imageEmbed)
            return
        }

        if let pasted = pasteboard.string(forType: .string) {
            let sanitized = sanitizePastedText(pasted)
            if !sanitized.isEmpty {
                insertText(sanitized, replacementRange: selectedRange())
                return
            }
        }

        if let fileText = textFromPastedFileURL(pasteboard: pasteboard) {
            let sanitized = sanitizePastedText(fileText)
            if !sanitized.isEmpty {
                insertText(sanitized, replacementRange: selectedRange())
                return
            }
        }

        pasteAsPlainText(sender)
    }

    private func insertBlockEmbed(_ embed: String) {
        let sel = selectedRange()
        let nsText = string as NSString
        var prefix = ""
        var suffix = ""
        if sel.location > 0, nsText.character(at: sel.location - 1) != 0x0A {
            prefix = "\n"
        }
        let afterLocation = sel.location + sel.length
        if afterLocation < nsText.length, nsText.character(at: afterLocation) != 0x0A {
            suffix = "\n"
        }
        insertText(prefix + embed + suffix, replacementRange: sel)
    }

    /// Reads the textual content of a pasted markdown/text file URL — the
    /// fallback that makes iOS Universal Clipboard pastes useful.
    private func textFromPastedFileURL(pasteboard: NSPasteboard) -> String? {
        let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: nil) as? [URL] ?? []
        for url in urls where url.isFileURL {
            guard Self.pastableTextExtensions.contains(url.pathExtension.lowercased()) else { continue }
            if let s = try? String(contentsOf: url, encoding: .utf8) { return s }
            if let s = try? String(contentsOf: url) { return s }
        }
        return nil
    }

    private func sanitizePastedText(_ s: String) -> String {
        var out = s
        if let regex = try? NSRegularExpression(pattern: "\\n{3,}") {
            let nsRange = NSRange(location: 0, length: (out as NSString).length)
            out = regex.stringByReplacingMatches(in: out, range: nsRange, withTemplate: "\n\n")
        }
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    override func validateUserInterfaceItem(_ item: any NSValidatedUserInterfaceItem) -> Bool {
        if item.action == #selector(paste(_:)) {
            let pasteboard = NSPasteboard.general
            if PasteboardImageReader.canPasteImage(from: pasteboard) { return true }
            if textFromPastedFileURL(pasteboard: pasteboard) != nil { return true }
        }
        return super.validateUserInterfaceItem(item)
    }
}
