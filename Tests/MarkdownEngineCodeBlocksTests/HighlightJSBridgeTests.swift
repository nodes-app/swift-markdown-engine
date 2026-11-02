//
//  HighlightJSBridgeTests.swift
//  MarkdownEngineCodeBlocksTests
//
//  Created by Luca Chen on 16.10.26.
//

import AppKit
import Testing
import MarkdownEngine
import MarkdownEngineCodeBlocks

@Suite("highlight.js bridge")
struct HighlightJSBridgeTests {
    static let keyword = NSColor(srgbRed: 1, green: 0, blue: 0, alpha: 1)
    static let title = NSColor(srgbRed: 1, green: 1, blue: 0, alpha: 1)
    static let function = NSColor(srgbRed: 0, green: 0, blue: 1, alpha: 1)
    static let type = NSColor(srgbRed: 1, green: 0.5, blue: 0, alpha: 1)
    static let languageVariable = NSColor(srgbRed: 0.5, green: 0, blue: 0.5, alpha: 1)
    static let string = NSColor(srgbRed: 0, green: 0.5, blue: 0, alpha: 1)
    static let comment = NSColor(srgbRed: 0.5, green: 0.5, blue: 0.5, alpha: 1)
    static let number = NSColor(srgbRed: 0, green: 0.5, blue: 0.5, alpha: 1)
    static let builtIn = NSColor(srgbRed: 1, green: 0.75, blue: 0.5, alpha: 1)
    static let identifier = NSColor(srgbRed: 0.5, green: 0.75, blue: 1, alpha: 1)
    static let property = NSColor(srgbRed: 0.75, green: 1, blue: 0.5, alpha: 1)
    static let punctuation = NSColor(srgbRed: 0.6, green: 0.6, blue: 0.6, alpha: 1)
    static let operatorColor = NSColor(srgbRed: 0.25, green: 0.25, blue: 1, alpha: 1)
    static let foreground = NSColor(srgbRed: 0, green: 0, blue: 0, alpha: 1)

    static let theme = CodeHighlightTheme(
        foreground: foreground,
        background: .white,
        colors: [
            "keyword": keyword,
            "title": title,
            "title.function": function,
            "title.class": type,
            "identifier": identifier,
            "property": property,
            "punctuation": punctuation,
            "variable.language": languageVariable,
            "string": string,
            "comment": comment,
            "number": number,
            "built_in": builtIn,
            "operator": operatorColor,
        ]
    )

    // One JSContext for the suite: loading highlight.js is the expensive part.
    static let bridge = HighlightJSBridge(lightTheme: theme, darkTheme: theme, autoSwitchAppearance: false)

    /// The colour across every character of the `occurrence`th `token` in `code`; `nil` if it is not uniform.
    private func color(of token: String, occurrence: Int = 1, in code: String, language: String?) throws -> NSColor? {
        let highlighted = try #require(Self.bridge.highlight(code: code, language: language))
        #expect(highlighted.string == code)
        let source = code as NSString
        var range = NSRange(location: 0, length: 0)
        for _ in 0..<occurrence {
            let searchFrom = NSMaxRange(range)
            range = source.range(of: token, range: NSRange(location: searchFrom, length: source.length - searchFrom))
            try #require(range.location != NSNotFound)
        }
        var effective = NSRange(location: 0, length: 0)
        let color = highlighted.attribute(.foregroundColor, at: range.location, effectiveRange: &effective) as? NSColor
        return NSIntersectionRange(effective, range) == range ? color : nil
    }

    @Test("A nested scope keeps its own colour instead of its parent's")
    func nestedScopes() throws {
        let code = """
        class Foo(Bar):
            def best(self):
                return self.x
        """
        #expect(try color(of: "best", in: code, language: "python") == Self.function)
        #expect(try color(of: "Foo", in: code, language: "python") == Self.type)
        // `title.class.inherited` has no entry and falls back to `title.class`.
        #expect(try color(of: "Bar", in: code, language: "python") == Self.type)
        #expect(try color(of: "self", occurrence: 2, in: code, language: "python") == Self.languageVariable)
        // A parameter is plain code inside `params`.
        #expect(try color(of: "self", occurrence: 1, in: code, language: "python") == Self.identifier)
        #expect(try color(of: "return", in: code, language: "python") == Self.keyword)
    }

    @Test("Colours land on exactly the characters highlight.js scoped")
    func offsets() throws {
        let code = """
        s = "<a & b> 'ü' 😀"  # ö &amp; 😀
        n = 42
        """
        #expect(try color(of: #""<a & b> 'ü' 😀""#, in: code, language: "python") == Self.string)
        #expect(try color(of: "# ö &amp; 😀", in: code, language: "python") == Self.comment)
        #expect(try color(of: "42", in: code, language: "python") == Self.number)
        #expect(try color(of: "n", in: code, language: "python") == Self.identifier)
    }

    @Test("The language resolves like a fence's info string", arguments: ["py", "PYTHON", #"python title="x.py""#])
    func languageLabels(label: String) throws {
        #expect(try color(of: "def", in: "def f(): pass", language: label) == Self.keyword)
    }

    @Test("Plain code is lexed into names, calls, members and operators")
    func plainCode() throws {
        let python = """
        if __name__ == '__main__':
            names = sorted(set(load(path)))
            names.append(x.y)
        """
        #expect(try color(of: "__name__", in: python, language: "python") == Self.identifier)
        #expect(try color(of: "names", in: python, language: "python") == Self.identifier)
        #expect(try color(of: "load", in: python, language: "python") == Self.function)
        #expect(try color(of: "append", in: python, language: "python") == Self.function)
        #expect(try color(of: "y", in: python, language: "python") == Self.property)
        // What highlight.js already scoped keeps its colour.
        #expect(try color(of: "sorted", in: python, language: "python") == Self.builtIn)
        #expect(try color(of: "'__main__'", in: python, language: "python") == Self.string)
        #expect(try color(of: "==", in: python, language: "python") == Self.operatorColor)
        #expect(try color(of: "=", occurrence: 3, in: python, language: "python") == Self.operatorColor)
        #expect(try color(of: "(", in: python, language: "python") == Self.punctuation)

        // The same pass, no per-language rules: Go scopes none of this itself.
        let go = "total := fmt.Sprint(count)"
        #expect(try color(of: "total", in: go, language: "go") == Self.identifier)
        #expect(try color(of: "Sprint", in: go, language: "go") == Self.function)
        #expect(try color(of: ":=", in: go, language: "go") == Self.operatorColor)
    }

    @Test("Prose and shell arguments stay plain", arguments: [
        ("markdown", "Some words (here)", "words"),
        ("bash", "echo words here", "words"),
        ("html", "<p>Some words (here)</p>", "words"),
    ])
    func notCode(language: String, code: String, token: String) throws {
        #expect(try color(of: token, in: code, language: language) == Self.foreground)
    }

    @Test("An unknown language falls back to detection")
    func unknownLanguage() throws {
        let code = "def f():\n    return 1"
        #expect(try color(of: "return", in: code, language: "no-such-language") == Self.keyword)
    }

    @Test("An embedded language is coloured")
    func embeddedLanguage() throws {
        #expect(try color(of: "let", in: "<script>let a = 1;</script>", language: "html") == Self.keyword)
    }
}
