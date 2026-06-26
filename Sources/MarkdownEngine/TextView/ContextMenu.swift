//
//  ContextMenu.swift
//  MarkdownEngine
//
//  Created by Luca Chen on 20.06.25.
//
//  Right-click menu with toggleable Markdown formatting actions.
//

import Cocoa
import SwiftUI

extension NativeTextViewWrapper.Coordinator {
    public func textView(_ textView: NSTextView,
                  menu: NSMenu,
                  for event: NSEvent,
                  at charIndex: Int) -> NSMenu? {
        let customMenu = menu.copy() as? NSMenu ?? NSMenu()

        if let fontIndex = customMenu.items.firstIndex(where: { $0.title == "Font" }) {
            customMenu.removeItem(at: fontIndex)
            let formatItem = NSMenuItem(title: "Format", action: nil, keyEquivalent: "")
            let formatSubmenu = NSMenu(title: "Format")
            let boldItem = NSMenuItem(title: "Bold", action: #selector(didMarkdownBold(_:)), keyEquivalent: "")
            boldItem.target = self
            formatSubmenu.addItem(boldItem)
            let italicItem = NSMenuItem(title: "Italic", action: #selector(didMarkdownItalic(_:)), keyEquivalent: "")
            italicItem.target = self
            formatSubmenu.addItem(italicItem)
            formatItem.submenu = formatSubmenu
            customMenu.insertItem(formatItem, at: fontIndex)

            let headingItem = NSMenuItem(title: "Heading", action: nil, keyEquivalent: "")
            let headingSubmenu = NSMenu(title: "Heading")
            for level in 1...3 {
                let item = NSMenuItem(title: "H\(level)", action: #selector(didMarkdownHeading(_:)), keyEquivalent: "")
                item.target = self
                item.tag = level
                headingSubmenu.addItem(item)
            }
            headingItem.submenu = headingSubmenu
            customMenu.insertItem(headingItem, at: fontIndex + 1)

            let listItem = NSMenuItem(title: "Lists", action: nil, keyEquivalent: "")
            let listSubmenu = NSMenu(title: "Lists")
            let unorderedItem = NSMenuItem(title: "Bullet", action: #selector(didMarkdownUnorderedList(_:)), keyEquivalent: "")
            unorderedItem.target = self
            listSubmenu.addItem(unorderedItem)
            let orderedItem = NSMenuItem(title: "Numbered", action: #selector(didMarkdownOrderedList(_:)), keyEquivalent: "")
            orderedItem.target = self
            listSubmenu.addItem(orderedItem)
            listItem.submenu = listSubmenu
            customMenu.insertItem(listItem, at: fontIndex + 2)
            customMenu.insertItem(NSMenuItem.separator(), at: fontIndex + 3)
        }

        return customMenu
    }

    /// Returns the smallest bold or boldItalic token that fully contains the selection, or nil when the selection isn't enclosed by emphasis with a bold trait.
    func enclosingBoldToken(for selection: NSRange, in text: String) -> MarkdownToken? {
        let tokens = parsedDocument(for: text).tokens
        return tokens.first { token in
            (token.kind == .bold || token.kind == .boldItalic) && tokenEncloses(token, selection: selection)
        }
    }

    /// Returns the smallest italic or boldItalic token that fully contains the selection, or nil when the selection isn't enclosed by emphasis with an italic trait.
    func enclosingItalicToken(for selection: NSRange, in text: String) -> MarkdownToken? {
        let tokens = parsedDocument(for: text).tokens
        return tokens.first { token in
            (token.kind == .italic || token.kind == .boldItalic) && tokenEncloses(token, selection: selection)
        }
    }

    func isSelectionBold(in nsText: NSString, range: NSRange) -> Bool {
        return enclosingBoldToken(for: range, in: nsText as String) != nil
    }

    func isSelectionItalic(in nsText: NSString, range: NSRange) -> Bool {
        return enclosingItalicToken(for: range, in: nsText as String) != nil
    }

    func isSelectionStrikethrough(in nsText: NSString, range: NSRange) -> Bool {
        return enclosingToken(of: .strikethrough, for: range, in: nsText as String) != nil
    }

    func isSelectionInlineCode(in nsText: NSString, range: NSRange) -> Bool {
        return enclosingToken(of: .inlineCode, for: range, in: nsText as String) != nil
    }

    /// Returns the smallest token of `kind` that fully contains the selection, or nil.
    private func enclosingToken(of kind: MarkdownTokenKind, for selection: NSRange, in text: String) -> MarkdownToken? {
        let tokens = parsedDocument(for: text).tokens
        return tokens.first { $0.kind == kind && tokenEncloses($0, selection: selection) }
    }

    /// Expands the given text location outward to the nearest alphanumeric
    /// + underscore word boundaries. Returns nil when no word characters
    /// are adjacent to the location.
    private func wordRange(at location: Int, in nsText: NSString) -> NSRange? {
        guard location >= 0, location <= nsText.length else { return nil }
        let charSet = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_"))
        var start = location
        while start > 0 {
            let ch = nsText.character(at: start - 1)
            guard let scalar = Unicode.Scalar(ch), charSet.contains(scalar) else { break }
            start -= 1
        }
        var end = location
        while end < nsText.length {
            let ch = nsText.character(at: end)
            guard let scalar = Unicode.Scalar(ch), charSet.contains(scalar) else { break }
            end += 1
        }
        let length = end - start
        return length > 0 ? NSRange(location: start, length: length) : nil
    }

    private func tokenEncloses(_ token: MarkdownToken, selection: NSRange) -> Bool {
        return selection.location >= token.range.location
            && NSMaxRange(selection) <= NSMaxRange(token.range)
    }

    /// Replaces the marker characters of an emphasis token with `replacement` on each side, preserving the inner content.
    private func unwrapToken(_ token: MarkdownToken, leftReplacement: String, rightReplacement: String) {
        guard let tv = textView else { return }
        let nsText = tv.string as NSString
        let content = nsText.substring(with: token.contentRange)
        let newText = leftReplacement + content + rightReplacement
        if tv.shouldChangeText(in: token.range, replacementString: newText) {
            tv.replaceCharacters(in: token.range, with: newText)
            tv.didChangeText()
            let newSelectionLocation = token.range.location + leftReplacement.count
            tv.setSelectedRange(NSRange(location: newSelectionLocation, length: content.count))
            DispatchQueue.main.async { self.text = tv.string }
        }
    }

    func isSelectionHeading(level: Int, in nsText: NSString, range: NSRange) -> Bool {
        let lineRange = nsText.lineRange(for: range)
        let line = nsText.substring(with: lineRange)
        let trimmedLine = line.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedLine.hasPrefix(String(repeating: "#", count: level) + " ")
    }

    func isSelectionList(in nsText: NSString, range: NSRange) -> Bool {
        let lineRange = nsText.lineRange(for: range)
        let line = nsText.substring(with: lineRange)
        return line.hasPrefix("- ") || line.hasPrefix("* ") || line.hasPrefix("+ ")
            || line.hasPrefix("\t• ") || line.hasPrefix("1. ")
    }

    func isSelectionBlockquote(in nsText: NSString, range: NSRange) -> Bool {
        let lineRange = nsText.lineRange(for: range)
        let line = nsText.substring(with: lineRange)
        return line.hasPrefix("> ")
    }

    private func applyHeading(level: Int) {
        guard let tv = textView else { return }
        let nsText = tv.string as NSString
        let range = tv.selectedRange()
        let lineRange = nsText.lineRange(for: range)
        let originalLine = nsText.substring(with: lineRange)
        let rawLine = originalLine.trimmingCharacters(in: .whitespacesAndNewlines)
        var content = rawLine
        while content.hasPrefix("#") { content.removeFirst() }
        content = content.trimmingCharacters(in: .whitespaces)
        let prefix = String(repeating: "#", count: level) + " "
        // lineRange(for:) includes the trailing line terminator; preserve it so
        // applying a heading to a non-final line doesn't swallow the newline and
        // merge the line with the next one (mirrors applyList's suffix handling).
        let suffix = originalLine.hasSuffix("\n") ? "\n" : ""
        let newLine = prefix + content + suffix
        if tv.shouldChangeText(in: lineRange, replacementString: newLine) {
            tv.replaceCharacters(in: lineRange, with: newLine)
            tv.didChangeText()
            let newSel = NSRange(location: lineRange.location + prefix.count, length: content.count)
            tv.setSelectedRange(newSel)
            DispatchQueue.main.async { self.text = tv.string }
        }
    }

    @objc func didMarkdownHeading(_ sender: NSMenuItem) {
        applyHeading(level: sender.tag)
    }

    private func applyList(prefix: String) {
        guard let tv = textView else { return }
        let nsText = tv.string as NSString
        let selRange = tv.selectedRange()
        let startLine = nsText.lineRange(for: selRange)
        let originalLine = nsText.substring(with: startLine)
        let lineText = originalLine.trimmingCharacters(in: .newlines)
        var content = lineText
        if content.hasPrefix(prefix) {
            content = String(content.dropFirst(prefix.count))
        }
        let newLine = prefix + content
        let suffix = originalLine.hasSuffix("\n") ? "\n" : ""
        let replacement = newLine + suffix
        if tv.shouldChangeText(in: startLine, replacementString: replacement) {
            tv.replaceCharacters(in: startLine, with: replacement)
            tv.didChangeText()
            let newSel = NSRange(location: startLine.location + prefix.count, length: content.count)
            tv.setSelectedRange(newSel)
            DispatchQueue.main.async { self.text = tv.string }
        }
    }

    @objc func didMarkdownUnorderedList(_ sender: Any?) {
        applyList(prefix: "- ")
    }

    @objc func didMarkdownOrderedList(_ sender: Any?) {
        applyList(prefix: "1. ")
    }

    @objc func didMarkdownBold(_ sender: Any?) {
        guard let tv = textView else { return }
        let range = tv.selectedRange()

        if let token = enclosingBoldToken(for: range, in: tv.string) {
            // Toggle off: bold → plain, boldItalic → italic.
            let (left, right) = token.kind == .boldItalic ? ("*", "*") : ("", "")
            unwrapToken(token, leftReplacement: left, rightReplacement: right)
            return
        }

        if range.length == 0, let wr = wordRange(at: range.location, in: tv.string as NSString), wr.length > 0 {
            let cursorOffset = range.location - wr.location
            wrapWordRange(wr, with: "**", cursorOffset: cursorOffset)
            return
        }

        if range.length == 0 {
            insertEmptyMarkers("**")
            return
        }

        wrapSelection(with: "**")
    }

    @objc func didMarkdownItalic(_ sender: Any?) {
        guard let tv = textView else { return }
        let range = tv.selectedRange()

        if let token = enclosingItalicToken(for: range, in: tv.string) {
            // Toggle off: italic → plain, boldItalic → bold.
            let (left, right) = token.kind == .boldItalic ? ("**", "**") : ("", "")
            unwrapToken(token, leftReplacement: left, rightReplacement: right)
            return
        }

        if range.length == 0, let wr = wordRange(at: range.location, in: tv.string as NSString), wr.length > 0 {
            let cursorOffset = range.location - wr.location
            wrapWordRange(wr, with: "*", cursorOffset: cursorOffset)
            return
        }

        if range.length == 0 {
            insertEmptyMarkers("*")
            return
        }

        wrapSelection(with: "*")
    }

    @objc func didMarkdownStrikethrough(_ sender: Any?) {
        guard let tv = textView else { return }
        let range = tv.selectedRange()

        if let token = enclosingToken(of: .strikethrough, for: range, in: tv.string) {
            unwrapToken(token, leftReplacement: "", rightReplacement: "")
            return
        }

        if range.length == 0, let wr = wordRange(at: range.location, in: tv.string as NSString), wr.length > 0 {
            let cursorOffset = range.location - wr.location
            wrapWordRange(wr, with: "~~", cursorOffset: cursorOffset)
            return
        }

        if range.length == 0 {
            insertEmptyMarkers("~~")
            return
        }

        wrapSelection(with: "~~")
    }

    @objc func didMarkdownInlineCode(_ sender: Any?) {
        guard let tv = textView else { return }
        let range = tv.selectedRange()

        if let token = enclosingToken(of: .inlineCode, for: range, in: tv.string) {
            unwrapToken(token, leftReplacement: "", rightReplacement: "")
            return
        }

        if range.length == 0, let wr = wordRange(at: range.location, in: tv.string as NSString), wr.length > 0 {
            let cursorOffset = range.location - wr.location
            wrapWordRange(wr, with: "`", cursorOffset: cursorOffset)
            return
        }

        if range.length == 0 {
            insertEmptyMarkers("`")
            return
        }

        wrapSelection(with: "`")
    }

    @objc func didMarkdownBlockquote(_ sender: Any?) {
        guard let tv = textView else { return }
        let nsText = tv.string as NSString
        let range = tv.selectedRange()
        let lineRange = nsText.lineRange(for: range)
        let originalLine = nsText.substring(with: lineRange)

        if originalLine.hasPrefix("> ") {
            let stripped = String(originalLine.dropFirst(2))
            let needsNewline = originalLine.hasSuffix("\n") && !stripped.hasSuffix("\n")
            let replacement = stripped + (needsNewline ? "\n" : "")
            if tv.shouldChangeText(in: lineRange, replacementString: replacement) {
                tv.replaceCharacters(in: lineRange, with: replacement)
                tv.didChangeText()
                let newLoc = max(lineRange.location, range.location - 2)
                tv.setSelectedRange(NSRange(location: newLoc, length: 0))
                DispatchQueue.main.async { self.text = tv.string }
            }
        } else {
            let newLine = "> " + originalLine
            if tv.shouldChangeText(in: lineRange, replacementString: newLine) {
                tv.replaceCharacters(in: lineRange, with: newLine)
                tv.didChangeText()
                tv.setSelectedRange(NSRange(location: lineRange.location + 2, length: range.length))
                DispatchQueue.main.async { self.text = tv.string }
            }
        }
    }

    @objc func didMarkdownLink(_ sender: Any?) {
        guard let tv = textView else { return }
        let range = tv.selectedRange()
        let url = (sender as? NSNotification)?.userInfo?["url"] as? String ?? ""

        if range.length > 0 {
            let nsText = tv.string as NSString
            let selected = nsText.substring(with: range)
            let newText = "[\(selected)](\(url))"
            if tv.shouldChangeText(in: range, replacementString: newText) {
                tv.replaceCharacters(in: range, with: newText)
                tv.didChangeText()
                tv.setSelectedRange(NSRange(location: range.location + newText.count, length: 0))
                DispatchQueue.main.async { self.text = tv.string }
            }
        } else {
            let insertion = "[](\(url))"
            if tv.shouldChangeText(in: range, replacementString: insertion) {
                tv.replaceCharacters(in: range, with: insertion)
                tv.didChangeText()
                tv.setSelectedRange(NSRange(location: range.location + 1, length: 0))
                DispatchQueue.main.async { self.text = tv.string }
            }
        }
    }

    @objc func didMarkdownCodeBlock(_ sender: Any?) {
        guard let tv = textView else { return }
        let range = tv.selectedRange()
        let nsText = tv.string as NSString
        let lineRange = nsText.lineRange(for: range)
        let prefix = range.location > lineRange.location ? "\n" : ""
        let insertion = "\(prefix)```\n\n```\n"
        if tv.shouldChangeText(in: range, replacementString: insertion) {
            tv.replaceCharacters(in: range, with: insertion)
            tv.didChangeText()
            let cursorLoc = range.location + prefix.count + 4
            tv.setSelectedRange(NSRange(location: cursorLoc, length: 0))
            DispatchQueue.main.async { self.text = tv.string }
        }
    }

    @objc func didMarkdownHorizontalRule(_ sender: Any?) {
        guard let tv = textView else { return }
        let range = tv.selectedRange()
        let nsText = tv.string as NSString
        let lineRange = nsText.lineRange(for: range)
        let prefix = range.location > lineRange.location ? "\n" : ""
        let insertion = "\(prefix)---\n"
        if tv.shouldChangeText(in: range, replacementString: insertion) {
            tv.replaceCharacters(in: range, with: insertion)
            tv.didChangeText()
            let cursorLoc = range.location + insertion.count
            tv.setSelectedRange(NSRange(location: cursorLoc, length: 0))
            DispatchQueue.main.async { self.text = tv.string }
        }
    }

    @objc func didMarkdownImage(_ sender: Any?) {
        guard let tv = textView else { return }
        let range = tv.selectedRange()
        let url = (sender as? NSNotification)?.userInfo?["url"] as? String ?? ""
        let insertion = "![](\(url))"
        if tv.shouldChangeText(in: range, replacementString: insertion) {
            tv.replaceCharacters(in: range, with: insertion)
            tv.didChangeText()
            tv.setSelectedRange(NSRange(location: range.location + insertion.count, length: 0))
            DispatchQueue.main.async { self.text = tv.string }
        }
    }

    /// Wraps the range with markers while preserving the cursor's relative
    /// offset within the original text. For example `wo|rd` with `**`
    /// becomes `**wo|rd**`.
    private func wrapWordRange(_ range: NSRange, with marker: String, cursorOffset: Int) {
        guard let tv = textView else { return }
        let nsText = tv.string as NSString
        let original = nsText.substring(with: range)
        let newText = marker + original + marker
        if tv.shouldChangeText(in: range, replacementString: newText) {
            tv.replaceCharacters(in: range, with: newText)
            tv.didChangeText()
            tv.setSelectedRange(NSRange(location: range.location + marker.count + cursorOffset, length: 0))
            DispatchQueue.main.async { self.text = tv.string }
        }
    }

    private func insertEmptyMarkers(_ marker: String) {
        guard let tv = textView else { return }
        let range = tv.selectedRange()
        let insertion = marker + marker
        if tv.shouldChangeText(in: range, replacementString: insertion) {
            tv.replaceCharacters(in: range, with: insertion)
            tv.didChangeText()
            tv.setSelectedRange(NSRange(location: range.location + marker.count, length: 0))
            DispatchQueue.main.async { self.text = tv.string }
        }
    }

    private func wrapSelection(with marker: String) {
        guard let tv = textView else { return }
        let nsText = tv.string as NSString
        let range = tv.selectedRange()
        let original = nsText.substring(with: range)
        let leadingWS = original.prefix { $0.isWhitespace }.count
        let trailingWS = original.reversed().prefix { $0.isWhitespace }.count
        let coreStart = original.index(original.startIndex, offsetBy: leadingWS)
        let coreEnd = original.index(original.endIndex, offsetBy: -trailingWS)
        let core = coreStart <= coreEnd ? String(original[coreStart..<coreEnd]) : ""
        let leading = String(original[..<coreStart])
        let trailing = String(original[coreEnd...])
        let newText = leading + marker + core + marker + trailing
        if tv.shouldChangeText(in: range, replacementString: newText) {
            tv.replaceCharacters(in: range, with: newText)
            tv.didChangeText()
            let newRange = NSRange(location: range.location + leadingWS + marker.count, length: core.count)
            tv.setSelectedRange(newRange)
            DispatchQueue.main.async { self.text = tv.string }
        }
    }
}

// MARK: - Menu Item Validation
extension NativeTextViewWrapper.Coordinator: NSMenuItemValidation {
    public func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        guard let tv = textView else { return true }
        let nsText = tv.string as NSString
        let range = tv.selectedRange()
        switch menuItem.action {
        case #selector(didMarkdownBold(_:)):
            menuItem.state = enclosingBoldToken(for: range, in: tv.string) != nil ? .on : .off
            return true
        case #selector(didMarkdownItalic(_:)):
            menuItem.state = enclosingItalicToken(for: range, in: tv.string) != nil ? .on : .off
            return true
        case #selector(didMarkdownStrikethrough(_:)):
            menuItem.state = isSelectionStrikethrough(in: nsText, range: range) ? .on : .off
            return true
        case #selector(didMarkdownInlineCode(_:)):
            menuItem.state = isSelectionInlineCode(in: nsText, range: range) ? .on : .off
            return true
        case #selector(didMarkdownBlockquote(_:)):
            return !isSelectionBlockquote(in: nsText, range: range)
        case #selector(didMarkdownHeading(_:)):
            return !isSelectionHeading(level: menuItem.tag, in: nsText, range: range)
        case #selector(didMarkdownUnorderedList(_:)),
             #selector(didMarkdownOrderedList(_:)):
            return !isSelectionList(in: nsText, range: range)
        default:
            return true
        }
    }
}
