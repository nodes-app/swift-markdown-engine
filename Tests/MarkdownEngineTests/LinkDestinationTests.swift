import Testing
@testable import MarkdownEngine

struct LinkDestinationTests {
    @Test(arguments: [
        ("my file.md", "my file.md"),
        ("../Foo Bar/", "../Foo Bar/"),
        ("a.md \"t\"", "a.md"),
        ("a.md 't'", "a.md"),
        ("a.md (t)", "a.md"),
        ("my file.md \"t\"", "my file.md"),
        ("<a b.md>", "a b.md"),
        ("<a b.md> \"t\"", "a b.md"),
        ("a.md \"onafgesloten", "a.md \"onafgesloten"),
        (" \t a.md \n ", "a.md"),
        ("a.md \"t\" suffix", "a.md \"t\" suffix"),
        ("a.md \"a \\\"quote\\\"\"", "a.md"),
    ])
    func keepsSpacesUnlessACompleteTitleFollows(raw: String, expected: String) {
        #expect(InlineParser.markdownLinkDestination(from: raw) == expected)
    }
}
