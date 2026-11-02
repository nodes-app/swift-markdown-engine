//
//  HighlightJSBridge.swift
//  MarkdownEngineCodeBlocks
//
//  Created by Luca Chen on 16.10.26.
//
//  Ready-made SyntaxHighlighter conformance backed by highlight.js.
//
//  `Resources/highlight.min.js` is highlight.js 11.11.1 with all 192
//  languages, byte-identical to the build HighlighterSwift 3.1.0 shipped, so
//  dropping that package changed no tokens. Updating it means a full build
//  (`node tools/build.js -t browser :all`): the CDN's `highlight.min.js` holds
//  only the common languages.
//

import AppKit
import Foundation
import JavaScriptCore
import MarkdownEngine

extension Notification.Name {
    /// Posted by ``HighlightJSBridge`` after the macOS appearance flips; the engine subscribes via ``SyntaxHighlighter/appearanceDidChangeNotification`` to invalidate cached attributes.
    public static let markdownEngineHighlighterDidChangeAppearance =
        Notification.Name("MarkdownEngineHighlighterDidChangeAppearance")
}

/// Drop-in ``SyntaxHighlighter`` that runs the bundled highlight.js in
/// JavaScriptCore and colours its tokens from a ``CodeHighlightTheme``.
///
/// The token tree is read directly, never through highlight.js's HTML and a
/// CSS theme, so a nested scope keeps its own colour: `title.function` is not
/// `title`, and `variable.language` (`self`, `this`) is not `variable`.
///
/// Defaults match the Nodes app's look: opaque light/dark code-block
/// backgrounds and an `SF Mono → Menlo → system monospace` font chain. Pass
/// `nil` for a background to take the theme's own.
///
/// When `autoSwitchAppearance` is `true`, the bridge colours with `darkTheme`
/// under a dark appearance and posts
/// ``Notification/Name/markdownEngineHighlighterDidChangeAppearance`` when the
/// system appearance flips, so the engine can re-render code blocks.
public final class HighlightJSBridge: SyntaxHighlighter, @unchecked Sendable {
    private let highlightJS: HighlightJS?
    private let lightTheme: CodeHighlightTheme
    private let darkTheme: CodeHighlightTheme
    private let autoSwitchAppearance: Bool
    private let lightBackground: NSColor
    private let darkBackground: NSColor
    private let preferredFontNames: [String]

    // A JSContext must not run two scripts at once.
    private let lock = NSLock()
    // highlight.js is expensive — cache by (appearance, language, code).
    private let highlightCache = NSCache<NSString, NSAttributedString>()

    /// - Parameters:
    ///   - lightTheme: Token colours in light mode.
    ///   - darkTheme: Token colours in dark mode.
    ///   - autoSwitchAppearance: When `true`, follows the appearance and
    ///     swaps themes automatically. Set to `false` to pin to `lightTheme`.
    ///   - lightBackground: Code-block background in light mode. Pass `nil`
    ///     to use `lightTheme.background` instead.
    ///   - darkBackground: Code-block background in dark mode. Pass `nil`
    ///     to use `darkTheme.background` instead.
    ///   - preferredFontNames: PostScript font names tried in order before
    ///     falling back to the system monospace font.
    public init(
        lightTheme: CodeHighlightTheme = .githubLight,
        darkTheme: CodeHighlightTheme = .githubDark,
        autoSwitchAppearance: Bool = true,
        lightBackground: NSColor? = NSColor(calibratedWhite: 0.95, alpha: 1.0),
        darkBackground: NSColor? = NSColor(calibratedWhite: 0.13, alpha: 1.0),
        preferredFontNames: [String] = ["SF Mono", "Menlo"]
    ) {
        self.highlightJS = HighlightJS()
        self.lightTheme = lightTheme
        self.darkTheme = darkTheme
        self.autoSwitchAppearance = autoSwitchAppearance
        self.lightBackground = lightBackground ?? lightTheme.background
        self.darkBackground = darkBackground ?? darkTheme.background
        self.preferredFontNames = preferredFontNames
        highlightCache.countLimit = 256
        highlightCache.totalCostLimit = 2_000_000

        if autoSwitchAppearance {
            DistributedNotificationCenter.default.addObserver(
                forName: NSNotification.Name("AppleInterfaceThemeChangedNotification"),
                object: nil,
                queue: .main
            ) { [weak self] _ in
                guard self != nil else { return }
                NotificationCenter.default.post(
                    name: .markdownEngineHighlighterDidChangeAppearance,
                    object: nil
                )
            }
        }
    }

    /// Drops the internal highlight cache.
    public func clearCache() {
        highlightCache.removeAllObjects()
    }

    private func isDarkAppearance() -> Bool {
        guard autoSwitchAppearance else { return false }
        let appearance = NSApp.keyWindow?.effectiveAppearance ?? NSApp.effectiveAppearance
        return appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    }

    // MARK: - SyntaxHighlighter

    public var appearanceDidChangeNotification: Notification.Name? {
        autoSwitchAppearance ? .markdownEngineHighlighterDidChangeAppearance : nil
    }

    public func codeFont(size: CGFloat) -> NSFont {
        for name in preferredFontNames {
            if let font = NSFont(name: name, size: size) {
                return font
            }
        }
        return .monospacedSystemFont(ofSize: size, weight: .regular)
    }

    public func backgroundColor() -> NSColor {
        isDarkAppearance() ? darkBackground : lightBackground
    }

    public func highlight(code: String, language: String?) -> NSAttributedString? {
        guard let highlightJS else { return nil }
        let dark = isDarkAppearance()
        let theme = dark ? darkTheme : lightTheme
        // The info string's first word is the language (```python title="x.py").
        let name = language?.split(whereSeparator: \.isWhitespace).first?.lowercased() ?? ""
        let cacheKey = "\(dark ? "dark" : "light")|\(name)|\(code)" as NSString

        if let cached = highlightCache.object(forKey: cacheKey) {
            return cached
        }

        lock.lock()
        let tokens = highlightJS.tokens(in: code, language: name)
        lock.unlock()
        guard let tokens else { return nil }

        let highlighted = NSMutableAttributedString(
            string: code,
            attributes: [.foregroundColor: theme.foreground]
        )
        var colors: [String: NSColor?] = [:]
        for token in tokens {
            let color: NSColor?
            if let resolved = colors[token.scopes] {
                color = resolved
            } else {
                color = theme.color(forScopes: token.scopes.split(separator: " ").map(String.init))
                colors[token.scopes] = color
            }
            if let color {
                highlighted.addAttribute(.foregroundColor, value: color, range: token.range)
            }
        }

        // Immutable copy so the cached entry can't be mutated by callers.
        let result = NSAttributedString(attributedString: highlighted)
        highlightCache.setObject(result, forKey: cacheKey, cost: code.utf16.count)
        return result
    }
}

// MARK: - highlight.js

/// highlight.js loaded into its own JSContext. Not thread-safe; the bridge serialises calls.
private final class HighlightJS {
    struct Token {
        let range: NSRange
        /// Enclosing scopes, outermost first, space-separated: `"params built_in"`.
        let scopes: String
    }

    private let context: JSContext
    private let tokenize: JSValue

    // Walks `_emitter.rootNode`, the tree highlight.js renders its HTML from:
    // its leaves are the unescaped source, so offsets are UTF-16 offsets into
    // `code`. `_emitter` is private API, safe only because the build is pinned
    // (no tree → no highlighting, never misplaced colours). `language:<name>`
    // nodes only wrap an embedded language (JS in HTML). ignoreIllegals keeps
    // a half-typed or mislabelled fence coloured instead of plain.
    //
    // highlight.js leaves most of a program unscoped (Python: every name, call
    // and operator), so in code languages that plain text is lexed the way
    // CodeMirror's modes do it: `identifier`, `title.function.invoke`,
    // `property`, `operator`, `punctuation`. Markup, data and shells are left
    // alone - their plain text is prose, values or command arguments. Lexing
    // runs after detection, so it cannot sway `highlightAuto`.
    private static let tokenizeScript = #"""
    var __markdownEngineCodeLanguages = ["python", "javascript", "typescript", "swift", "go", "rust",
      "java", "kotlin", "c", "cpp", "csharp", "objectivec", "ruby", "php", "scala", "dart", "lua",
      "perl", "r", "julia", "groovy", "elixir", "matlab"]
      .map(function (name) { return hljs.getLanguage(name); })
      .filter(function (language) { return !!language; });

    var __markdownEngineTokenize = function (code, language) {
      var result = language && hljs.getLanguage(language)
        ? hljs.highlight(code, { language: language, ignoreIllegals: true })
        : hljs.highlightAuto(code);
      var root = result._emitter && result._emitter.rootNode;
      if (!root) { return null; }
      var tokens = [];
      var position = 0;

      var isCode = function (name) {
        return __markdownEngineCodeLanguages.indexOf(hljs.getLanguage(name)) !== -1;
      };
      // Outside every scope, or only inside ones that wrap code: parameters,
      // an arrow function, a string's `${…}`.
      var isPlain = function (scopes) {
        for (var i = scopes.length - 1; i >= 0; i--) {
          if (scopes[i] === "subst") { return true; }
          if (scopes[i] !== "params" && scopes[i] !== "function" && scopes[i] !== "class") { return false; }
        }
        return true;
      };
      var lexeme = /([A-Za-z_][A-Za-z0-9_]*)|(->|=>|::|:=|\*\*=?|\/\/=?|<<=?|>>=?|&&|\|\||\?\?|[=!]==?|[<>]=|[-+*\/%&|^~!<>=?]=?)|([()[\]{},;:.])/g;
      var lex = function (text, start, scopes) {
        lexeme.lastIndex = 0;
        var match;
        while ((match = lexeme.exec(text)) !== null) {
          var at = start + match.index;
          var scope = match[3] ? "punctuation" : match[2] ? "operator" : null;
          if (!scope) {
            var after = at + match[1].length;
            while (code[after] === " " || code[after] === "\t") { after++; }
            var before = at;
            while (code[before - 1] === " " || code[before - 1] === "\t") { before--; }
            var member = code[before - 1] === "." || (code[before - 1] === ">" && code[before - 2] === "-");
            scope = code[after] === "(" ? "title.function.invoke" : member ? "property" : "identifier";
          }
          tokens.push(at, match[0].length, scopes.concat([scope]).join(" "));
        }
      };

      var walk = function (node, scopes, lexes) {
        for (var i = 0; i < node.children.length; i++) {
          var child = node.children[i];
          if (typeof child === "string") {
            if (child.length > 0) {
              if (scopes.length > 0) { tokens.push(position, child.length, scopes.join(" ")); }
              if (lexes && isPlain(scopes)) { lex(child, position, scopes); }
            }
            position += child.length;
          } else if (child.scope && child.scope.indexOf("language:") === 0) {
            walk(child, scopes, isCode(child.scope.slice(9)));
          } else {
            walk(child, child.scope ? scopes.concat([child.scope]) : scopes, lexes);
          }
        }
      };
      walk(root, [], isCode(result.language || language));
      return JSON.stringify({ length: position, tokens: tokens });
    };
    """#

    init?() {
        guard let url = Bundle.module.url(forResource: "highlight.min", withExtension: "js"),
              let source = try? String(contentsOf: url, encoding: .utf8),
              let context = JSContext() else {
            return nil
        }
        context.evaluateScript(source)
        context.evaluateScript(Self.tokenizeScript)
        guard context.exception == nil,
              let tokenize = context.objectForKeyedSubscript("__markdownEngineTokenize"),
              tokenize.isObject else {
            return nil
        }
        self.context = context
        self.tokenize = tokenize
    }

    /// Scoped runs of `code`, or `nil` when highlight.js failed. Text outside every scope is left out.
    func tokens(in code: String, language: String) -> [Token]? {
        context.exception = nil
        let value = tokenize.call(withArguments: [code, language])
        guard context.exception == nil,
              let value, value.isString,
              let data = value.toString().data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let length = object["length"] as? Int,
              length == (code as NSString).length,
              let flat = object["tokens"] as? [Any],
              flat.count % 3 == 0 else {
            return nil
        }
        var tokens: [Token] = []
        tokens.reserveCapacity(flat.count / 3)
        var index = 0
        while index < flat.count {
            guard let location = flat[index] as? Int,
                  let tokenLength = flat[index + 1] as? Int,
                  let scopes = flat[index + 2] as? String else {
                return nil
            }
            tokens.append(Token(range: NSRange(location: location, length: tokenLength), scopes: scopes))
            index += 3
        }
        return tokens
    }
}
