import AppKit
import SwiftUI
import Testing
@testable import MarkdownEngine

@MainActor
@Suite("Host-decided link activation")
struct LinkActivationTests {
    private enum CallbackMode: CaseIterable {
        case handled
        case declined
        case absent
    }

    private struct LinkCase {
        let source: String
        let linkText: String
        let kind: MarkdownLinkActivation.Kind
        let destination: String
    }

    private struct Fixture {
        let coordinator: NativeTextViewCoordinator
        let textView: NativeTextView
        let linkValue: Any
        let clickIndex: Int
    }

    private struct ResolvedWikiLinks: WikiLinkResolver {
        func resolve(displayName: String, range: NSRange) -> WikiLinkResolution? {
            WikiLinkResolution(id: displayName, exists: true)
        }
    }

    private let linkCases = [
        LinkCase(source: "[x](my file.md)", linkText: "x", kind: .inlineLink, destination: "my file.md"),
        LinkCase(
            source: #"[Notes \[draft\]](#section)"#,
            linkText: #"Notes \[draft\]"#,
            kind: .inlineLink,
            destination: "#section"
        ),
        LinkCase(
            source: #"[Notes \[draft\]](../My%20file.md)"#,
            linkText: #"Notes \[draft\]"#,
            kind: .inlineLink,
            destination: "../My%20file.md"
        ),
        LinkCase(source: "[x](../Foo Bar/)", linkText: "x", kind: .inlineLink, destination: "../Foo Bar/"),
        LinkCase(
            source: "[Task](../Tasks/Jaron%20vraagt%20na.md)",
            linkText: "Task",
            kind: .inlineLink,
            destination: "../Tasks/Jaron%20vraagt%20na.md"
        ),
        LinkCase(
            source: "[Task](<../Tasks/Jaron vraagt na.md>)",
            linkText: "Task",
            kind: .inlineLink,
            destination: "../Tasks/Jaron vraagt na.md"
        ),
        LinkCase(
            source: "[Task](a.md \"titel\")",
            linkText: "Task",
            kind: .inlineLink,
            destination: "a.md"
        ),
        LinkCase(
            source: "[Task](Map/Notitie.md#Kop)",
            linkText: "Task",
            kind: .inlineLink,
            destination: "Map/Notitie.md#Kop"
        ),
        LinkCase(
            source: "[Site](example.com)",
            linkText: "Site",
            kind: .inlineLink,
            destination: "example.com"
        ),
        LinkCase(
            source: "example.com",
            linkText: "example.com",
            kind: .autolink,
            destination: "example.com"
        ),
        LinkCase(
            source: "[Site](https://x.y/a.md)",
            linkText: "Site",
            kind: .inlineLink,
            destination: "https://x.y/a.md"
        ),
        LinkCase(
            source: "https://x.y/a.md",
            linkText: "https://x.y/a.md",
            kind: .autolink,
            destination: "https://x.y/a.md"
        ),
        LinkCase(
            source: "[Mail](mailto:a@b.c)",
            linkText: "Mail",
            kind: .inlineLink,
            destination: "mailto:a@b.c"
        ),
        LinkCase(
            source: "mailto:a@b.c",
            linkText: "mailto:a@b.c",
            kind: .autolink,
            destination: "mailto:a@b.c"
        ),
        LinkCase(source: "[[Wiki]]", linkText: "Wiki", kind: .wikiLink, destination: "Wiki"),
    ]

    @Test(arguments: [true, false])
    func callbackReceivesSourceTokenAndCanDeclineToLegacyRouting(isEditable: Bool) async throws {
        _ = NSApplication.shared

        for linkCase in linkCases {
            for mode in CallbackMode.allCases {
                var activations: [MarkdownLinkActivation] = []
                var wikiClicks: [String] = []
                let handler: ((MarkdownLinkActivation) -> Bool)? = mode == .absent
                    ? nil
                    : { activation in
                        activations.append(activation)
                        return mode == .handled
                    }
                let fixture = try makeFixture(
                    source: linkCase.source,
                    linkText: linkCase.linkText,
                    isEditable: isEditable,
                    onLinkActivation: handler,
                    onLinkClick: { wikiClicks.append($0) }
                )

                let handled = fixture.coordinator.textView(
                    fixture.textView,
                    clickedOnLink: fixture.linkValue,
                    at: fixture.clickIndex
                )
                await flushMainQueue()

                let hostHandled = mode == .handled
                let legacyWikiRoute = !hostHandled && linkCase.kind == .wikiLink
                #expect(handled == (hostHandled || legacyWikiRoute))
                #expect(fixture.textView.linkClickDidNavigate)
                #expect(wikiClicks == (legacyWikiRoute ? [linkCase.destination] : []))

                if mode == .absent {
                    #expect(activations.isEmpty)
                } else {
                    #expect(activations.count == 1)
                    #expect(
                        activations.first == MarkdownLinkActivation(
                            kind: linkCase.kind,
                            destination: linkCase.destination,
                            sourceRange: NSRange(location: 0, length: (linkCase.source as NSString).length),
                            modifierFlags: [],
                            isEditable: isEditable
                        )
                    )
                }

                if linkCase.source == "[Site](example.com)" {
                    #expect((fixture.linkValue as? URL)?.absoluteString == "https://example.com")
                }
            }
        }
    }

    @Test
    func sourceRangesUseStorageCoordinatesAfterWikiDisplayProjection() async throws {
        _ = NSApplication.shared
        let source = "[[Prior|opaque-id]] [Task](Map/Notitie.md#Kop)"
        var received: [MarkdownLinkActivation] = []
        let fixture = try makeFixture(
            source: source,
            linkText: "Task",
            isEditable: true,
            onLinkActivation: { received.append($0); return true },
            onLinkClick: nil
        )

        #expect(
            fixture.coordinator.textView(
                fixture.textView,
                clickedOnLink: fixture.linkValue,
                at: fixture.clickIndex
            )
        )
        await flushMainQueue()

        let expectedRange = (source as NSString).range(of: "[Task](Map/Notitie.md#Kop)")
        #expect(received.first?.sourceRange == expectedRange)
        #expect(received.first?.destination == "Map/Notitie.md#Kop")
    }

    @Test
    func escapedLinkLabelKeepsSourceCoordinatesAfterProjectedContent() throws {
        _ = NSApplication.shared
        let linkSource = #"[Notes \[draft\]](../My%20file.md#section)"#
        let source = "🌙 [[Prior|opaque-id]] " + linkSource
        var received: [MarkdownLinkActivation] = []
        let fixture = try makeFixture(
            source: source,
            linkText: #"Notes \[draft\]"#,
            isEditable: false,
            onLinkActivation: { received.append($0); return true },
            onLinkClick: nil
        )

        #expect(fixture.coordinator.textView(
            fixture.textView, clickedOnLink: fixture.linkValue, at: fixture.clickIndex
        ))
        #expect(received.count == 1)
        #expect(received.first?.kind == .inlineLink)
        #expect(received.first?.destination == "../My%20file.md#section")
        #expect(received.first?.sourceRange == (source as NSString).range(of: linkSource))
    }

    @Test
    func autolinkInLaterParagraphKeepsItsRawSourceRange() throws {
        _ = NSApplication.shared
        let destination = "https://example.com/later"
        let source = "😀 [[Prior|opaque-id]] https://other.example/first\n\nLater: \(destination)\n\nAfter"
        var received: [MarkdownLinkActivation] = []
        let fixture = try makeFixture(
            source: source,
            linkText: destination,
            isEditable: false,
            onLinkActivation: { received.append($0); return true },
            onLinkClick: nil
        )

        #expect(fixture.coordinator.textView(
            fixture.textView, clickedOnLink: fixture.linkValue, at: fixture.clickIndex
        ))
        #expect(received.count == 1)
        #expect(received.first?.kind == .autolink)
        #expect(received.first?.destination == destination)
        #expect(received.first?.sourceRange == (source as NSString).range(of: destination))
    }

    @Test
    func droppedClickFallbackOffersAutolinkToHostBeforeOpeningWorkspaceURL() throws {
        _ = NSApplication.shared
        let source = "https://example.com"
        var received: [MarkdownLinkActivation] = []
        var openedURLs: [URL] = []
        let fixture = try makeFixture(
            source: source,
            linkText: source,
            isEditable: false,
            onLinkActivation: { received.append($0); return true },
            onLinkClick: nil
        )

        let handled = fixture.textView.dispatchDroppedLinkClickFallback(
            fixture.linkValue,
            at: fixture.clickIndex,
            openURL: { openedURLs.append($0) }
        )

        #expect(handled)
        #expect(openedURLs.isEmpty)
        #expect(received.first?.kind == .autolink)
        #expect(received.first?.destination == source)
        #expect(received.first?.sourceRange == NSRange(location: 0, length: (source as NSString).length))
        #expect(fixture.textView.linkClickDidNavigate)
    }

    @Test
    func declinedDroppedClickKeepsWorkspaceURLFallback() throws {
        _ = NSApplication.shared
        var received: [MarkdownLinkActivation] = []
        var openedURLs: [URL] = []
        let fixture = try makeFixture(
            source: "[Site](https://x.y/a.md)",
            linkText: "Site",
            isEditable: false,
            onLinkActivation: { received.append($0); return false },
            onLinkClick: nil
        )

        let handled = fixture.textView.dispatchDroppedLinkClickFallback(
            fixture.linkValue,
            at: fixture.clickIndex,
            openURL: { openedURLs.append($0) }
        )

        #expect(!handled)
        #expect(received.first?.kind == .inlineLink)
        #expect(openedURLs.map(\.absoluteString) == ["https://x.y/a.md"])
    }

    private func makeFixture(
        source: String,
        linkText: String,
        isEditable: Bool,
        onLinkActivation: ((MarkdownLinkActivation) -> Bool)?,
        onLinkClick: ((String) -> Void)?
    ) throws -> Fixture {
        let configuration = MarkdownEditorConfiguration(
            services: MarkdownEditorServices(wikiLinks: ResolvedWikiLinks())
        )
        let displayState = WikiLinkService.makeDisplayState(from: source)
        let wrapper = NativeTextViewWrapper(
            text: .constant(source),
            configuration: configuration,
            isEditable: isEditable,
            onLinkActivation: onLinkActivation,
            onLinkClick: onLinkClick
        )
        let coordinator = wrapper.makeCoordinator()
        coordinator.wikiLinkMetadata = displayState.metadata
        coordinator.lastComputedStorage = source
        let textView = NativeTextView(frame: NSRect(x: 0, y: 0, width: 320, height: 120))
        textView.string = displayState.display
        textView.configuration = configuration
        textView.isEditable = isEditable
        textView.delegate = coordinator
        coordinator.textView = textView

        let displayNSString = displayState.display as NSString
        let expectedLinkRange = displayNSString.range(of: linkText)
        let styledLink = try #require(
            MarkdownASTStyler.styleAttributes(
                text: displayState.display,
                fontName: NSFont.systemFont(ofSize: 14).fontName,
                fontSize: 14,
                wikiLinkIDProvider: { _ in "Wiki" },
                configuration: configuration
            ).first { $0.range == expectedLinkRange && $0.attributes[.link] != nil }
        )
        let linkValue = try #require(styledLink.attributes[.link])
        let storage = try #require(textView.textStorage)
        storage.addAttributes(styledLink.attributes, range: styledLink.range)

        return Fixture(
            coordinator: coordinator,
            textView: textView,
            linkValue: linkValue,
            clickIndex: styledLink.range.location + max(0, styledLink.range.length / 2)
        )
    }

    private func flushMainQueue() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.main.async { continuation.resume() }
        }
    }
}
