//
//  ThemedSyntaxHighlighter.swift
//  MarkdownEngineCodeBlocks
//
//  A SyntaxHighlighter that tokenizes with highlight.js (vendored, run via
//  JavaScriptCore) and colors each token from a caller-supplied palette — so the
//  host's exact theme colors are used, rather than a bundled CSS theme.
//

import AppKit
import Foundation
import JavaScriptCore
import MarkdownEngine

/// The host's syntax colors, by lexical role. Mirrors the buckets a typical
/// editor theme exposes; highlight.js scopes are mapped onto these.
public struct SyntaxPalette: Sendable {
    public var text: NSColor
    public var keyword: NSColor
    public var string: NSColor
    public var number: NSColor
    public var comment: NSColor
    public var function: NSColor
    public var type: NSColor
    public var variable: NSColor
    public var constant: NSColor
    public var op: NSColor
    public var punctuation: NSColor
    public var error: NSColor
    public var warning: NSColor

    public init(text: NSColor, keyword: NSColor, string: NSColor, number: NSColor,
                comment: NSColor, function: NSColor, type: NSColor, variable: NSColor,
                constant: NSColor, op: NSColor, punctuation: NSColor,
                error: NSColor, warning: NSColor) {
        self.text = text; self.keyword = keyword; self.string = string
        self.number = number; self.comment = comment; self.function = function
        self.type = type; self.variable = variable; self.constant = constant
        self.op = op; self.punctuation = punctuation; self.error = error
        self.warning = warning
    }
}

/// `SyntaxHighlighter` backed by highlight.js, colored from a `SyntaxPalette`.
public final class ThemedSyntaxHighlighter: SyntaxHighlighter, @unchecked Sendable {
    private let palette: SyntaxPalette
    private let background: NSColor
    private let fontNames: [String]

    private let context: JSContext?
    private let hljs: JSValue?

    private let cache = NSCache<NSString, NSAttributedString>()
    private var unsupported: Set<String> = []
    private let lock = NSLock()

    public init(palette: SyntaxPalette, background: NSColor, fontNames: [String] = ["SF Mono", "Menlo"]) {
        self.palette = palette
        self.background = background
        self.fontNames = fontNames
        cache.countLimit = 256

        // Load the vendored highlight.js into a JS context once.
        if let ctx = JSContext(),
           let path = Bundle.module.path(forResource: "highlight.min", ofType: "js"),
           let js = try? String(contentsOfFile: path, encoding: .utf8) {
            ctx.evaluateScript(js)
            self.context = ctx
            self.hljs = ctx.globalObject.objectForKeyedSubscript("hljs")
        } else {
            self.context = nil
            self.hljs = nil
        }
    }

    // MARK: - SyntaxHighlighter

    /// Colors come from the host palette (re-supplied on theme change), not the
    /// system appearance, so there's nothing for the engine to observe here.
    public var appearanceDidChangeNotification: Notification.Name? { nil }

    public func codeFont(size: CGFloat) -> NSFont {
        for name in fontNames {
            if let f = NSFont(name: name, size: size) { return f }
        }
        return .monospacedSystemFont(ofSize: size, weight: .regular)
    }

    public func backgroundColor() -> NSColor { background }

    public func highlight(code: String, language: String?) -> NSAttributedString? {
        guard let hljs else { return nil }
        let lang = language?.lowercased().trimmingCharacters(in: .whitespaces)
        let langKey = (lang?.isEmpty == false) ? lang! : "auto"
        let cacheKey = "\(langKey)|\(code)" as NSString

        lock.lock()
        if let cached = cache.object(forKey: cacheKey) { lock.unlock(); return cached }
        let skip = lang.map { unsupported.contains($0) } ?? true
        lock.unlock()

        // Run highlight.js: explicit language when known + supported, else auto.
        var html: String?
        if let lang, !lang.isEmpty, !skip {
            let opts = ["language": lang, "ignoreIllegals": true] as [String: Any]
            if let r = hljs.invokeMethod("highlight", withArguments: [code, opts]),
               let v = r.objectForKeyedSubscript("value"), !v.isUndefined {
                html = v.toString()
            }
            if html == nil || html == "undefined" {
                lock.lock(); unsupported.insert(lang); lock.unlock()
                html = nil
            }
        }
        if html == nil {
            if let r = hljs.invokeMethod("highlightAuto", withArguments: [code]),
               let v = r.objectForKeyedSubscript("value"), !v.isUndefined {
                html = v.toString()
            }
        }
        guard let html, html != "undefined" else { return nil }

        let attributed = attributedString(fromHLJSHTML: html)
        lock.lock(); cache.setObject(attributed, forKey: cacheKey); lock.unlock()
        return attributed
    }

    // MARK: - HTML → attributed string
    //
    // highlight.js returns inner HTML: nested `<span class="hljs-…">…</span>` over
    // the source, with only `& < > " '` escaped. We walk it, tracking the active
    // scope color on a stack (innermost wins), and decode the five entities — so
    // the produced text is character-identical to the input code and the styler's
    // range mapping stays aligned.
    private func attributedString(fromHLJSHTML html: String) -> NSAttributedString {
        let result = NSMutableAttributedString()
        var stack: [NSColor] = []
        var run = ""
        let chars = Array(html.unicodeScalars)
        var i = 0
        let n = chars.count

        func currentColor() -> NSColor { stack.last ?? palette.text }
        func flush() {
            if !run.isEmpty {
                result.append(NSAttributedString(string: run, attributes: [.foregroundColor: currentColor()]))
                run = ""
            }
        }

        while i < n {
            let c = chars[i]
            if c == "<" {
                flush()
                // Read up to '>'
                var j = i + 1
                while j < n && chars[j] != ">" { j += 1 }
                let tag = String(String.UnicodeScalarView(chars[(i + 1)..<min(j, n)]))
                if tag.hasPrefix("span") {
                    stack.append(color(forSpanTag: tag) ?? currentColor())
                } else if tag.hasPrefix("/span") {
                    if !stack.isEmpty { stack.removeLast() }
                }
                i = j + 1
            } else if c == "&" {
                // Decode one entity.
                var j = i + 1
                while j < n && chars[j] != ";" && j - i < 8 { j += 1 }
                let name = String(String.UnicodeScalarView(chars[(i + 1)..<min(j, n)]))
                run.append(decodeEntity(name))
                i = (j < n && chars[j] == ";") ? j + 1 : i + 1
            } else {
                run.unicodeScalars.append(c)
                i += 1
            }
        }
        flush()
        return result
    }

    private func decodeEntity(_ name: String) -> Character {
        switch name {
        case "amp":  return "&"
        case "lt":   return "<"
        case "gt":   return ">"
        case "quot": return "\""
        case "#39", "#x27", "apos": return "'"
        default:
            if name.hasPrefix("#x"), let v = UInt32(name.dropFirst(2), radix: 16),
               let s = Unicode.Scalar(v) { return Character(s) }
            if name.hasPrefix("#"), let v = UInt32(name.dropFirst()), let s = Unicode.Scalar(v) {
                return Character(s)
            }
            return "&"   // unknown — leave the ampersand (rare)
        }
    }

    /// Map a `<span class="hljs-… …">` tag to a palette color, or nil to inherit
    /// the parent scope. Handles compound classes ("hljs-title function_").
    private func color(forSpanTag tag: String) -> NSColor? {
        // Pull the class attribute value.
        guard let r = tag.range(of: "class=\"") else { return nil }
        let rest = tag[r.upperBound...]
        guard let end = rest.firstIndex(of: "\"") else { return nil }
        let classes = rest[..<end]
        for raw in classes.split(separator: " ") {
            let scope = raw.replacingOccurrences(of: "hljs-", with: "")
                           .replacingOccurrences(of: "_", with: "")
            if let c = mappedColor(scope) { return c }
        }
        return nil
    }

    private func mappedColor(_ scope: String) -> NSColor? {
        switch scope {
        case "keyword", "name", "selector-tag", "tag", "section", "builtin", "built-in",
             "meta", "meta-keyword", "keyword.flow":
            return palette.keyword
        case "string", "regexp", "char", "char.escape", "subst.string", "formula", "template-tag":
            return palette.string
        case "number":
            return palette.number
        case "comment", "quote", "doctag":
            return palette.comment
        case "title", "function", "title.function", "title.function.invoke":
            return palette.function
        case "type", "class", "title.class", "title.class.inherited", "params.type", "selector-class":
            return palette.type
        case "variable", "attr", "attribute", "property", "template-variable",
             "variable.language", "variable.constant", "selector-attr", "selector-pseudo", "params":
            return palette.variable
        case "literal", "symbol", "bullet", "link":
            return palette.constant
        case "operator", "punctuation.operator":
            return palette.op
        case "punctuation":
            return palette.punctuation
        case "deletion":
            return palette.error
        case "addition":
            return palette.warning
        default:
            return nil
        }
    }
}
