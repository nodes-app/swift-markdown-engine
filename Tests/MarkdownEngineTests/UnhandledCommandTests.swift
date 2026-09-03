//
//  UnhandledCommandTests.swift
//  MarkdownEngineTests
//

import AppKit
import SwiftUI
import Testing
@testable import MarkdownEngine

@MainActor
@Suite("Unhandled editor commands")
struct UnhandledCommandTests {
    @Test("Preview consumption wins over the host callback")
    func previewWins() {
        let (coordinator, textView) = makeEditor("[[link]]")
        coordinator.isImageEmbedActive = true
        var previewCalls = 0
        var hostCalls = 0
        coordinator.onInlinePreviewKey = { key in
            previewCalls += 1
            return key == .cancel
        }
        coordinator.onUnhandledCommand = { _ in hostCalls += 1; return true }

        let consumed = coordinator.textView(textView, doCommandBy: #selector(NSResponder.cancelOperation(_:)))

        #expect(consumed)
        #expect(previewCalls == 1)
        #expect(hostCalls == 0)
    }

    @Test("A declined preview offers Escape to the host exactly once")
    func declinedPreviewFallsBackOnce() {
        let (coordinator, textView) = makeEditor("[[link]]")
        coordinator.isImageEmbedActive = true
        var received: [MarkdownEditorCommand] = []
        coordinator.onInlinePreviewKey = { _ in false }
        coordinator.onUnhandledCommand = { received.append($0); return true }

        let consumed = coordinator.textView(textView, doCommandBy: #selector(NSResponder.cancelOperation(_:)))

        #expect(consumed)
        #expect(received == [.escape])
    }

    @Test("A list consumes Tab before the host")
    func listTabWins() {
        let (coordinator, textView) = makeEditor("- item")
        textView.setSelectedRange(NSRange(location: 3, length: 0))
        var hostCalls = 0
        coordinator.onUnhandledCommand = { _ in hostCalls += 1; return true }

        let consumed = coordinator.textView(textView, doCommandBy: #selector(NSResponder.insertTab(_:)))

        #expect(consumed)
        #expect(textView.string == "\t- item")
        #expect(hostCalls == 0)
    }

    @Test("Maximum list depth stays consumed without forwarding")
    func maximumDepthStaysConsumed() {
        let (coordinator, textView) = makeEditor("\t\t\t- item")
        textView.setSelectedRange(NSRange(location: 6, length: 0))
        var hostCalls = 0
        coordinator.onUnhandledCommand = { _ in hostCalls += 1; return true }

        let consumed = coordinator.textView(textView, doCommandBy: #selector(NSResponder.insertTab(_:)))

        #expect(consumed)
        #expect(textView.string == "\t\t\t- item")
        #expect(hostCalls == 0)
    }

    @Test("A nested list consumes Backtab before the host")
    func listBacktabWins() {
        let (coordinator, textView) = makeEditor("\t- item")
        textView.setSelectedRange(NSRange(location: 4, length: 0))
        var hostCalls = 0
        coordinator.onUnhandledCommand = { _ in hostCalls += 1; return true }

        let consumed = coordinator.textView(textView, doCommandBy: #selector(NSResponder.insertBacktab(_:)))

        #expect(consumed)
        #expect(textView.string == "- item")
        #expect(hostCalls == 0)
    }

    @Test("Backtab on a top-level list item reaches the host")
    func topLevelListBacktabFallsBack() {
        let (coordinator, textView) = makeEditor("- item")
        textView.setSelectedRange(NSRange(location: 3, length: 0))
        var received: [MarkdownEditorCommand] = []
        coordinator.onUnhandledCommand = { received.append($0); return true }

        let consumed = coordinator.textView(textView, doCommandBy: #selector(NSResponder.insertBacktab(_:)))

        #expect(consumed)
        #expect(textView.string == "- item")
        #expect(received == [.backtab])
    }

    @Test("Host Bool result controls Tab fallback", arguments: [true, false])
    func hostResult(result: Bool) {
        let (coordinator, textView) = makeEditor("plain")
        var received: [MarkdownEditorCommand] = []
        coordinator.onUnhandledCommand = { received.append($0); return result }

        let consumed = coordinator.textView(textView, doCommandBy: #selector(NSResponder.insertTab(_:)))

        #expect(consumed == result)
        #expect(received == [.tab])
        #expect(textView.string == "plain")
    }

    @Test("Backtab outside a list reaches the host")
    func backtabFallsBack() {
        let (coordinator, textView) = makeEditor("plain")
        var received: [MarkdownEditorCommand] = []
        coordinator.onUnhandledCommand = { received.append($0); return true }

        let consumed = coordinator.textView(textView, doCommandBy: #selector(NSResponder.insertBacktab(_:)))

        #expect(consumed)
        #expect(received == [.backtab])
    }

    @Test("Raw mode skips list handling but still offers Tab to the host")
    func rawModeFallsBack() {
        let (coordinator, textView) = makeEditor("- item", rawSourceMode: true)
        textView.setSelectedRange(NSRange(location: 3, length: 0))
        var received: [MarkdownEditorCommand] = []
        coordinator.onUnhandledCommand = { received.append($0); return true }

        let consumed = coordinator.textView(textView, doCommandBy: #selector(NSResponder.insertTab(_:)))

        #expect(consumed)
        #expect(received == [.tab])
        #expect(textView.string == "- item")
    }

    @Test("Raw mode skips list outdent but still offers Backtab to the host")
    func rawBacktabFallsBack() {
        let (coordinator, textView) = makeEditor("\t- item", rawSourceMode: true)
        textView.setSelectedRange(NSRange(location: 4, length: 0))
        var received: [MarkdownEditorCommand] = []
        coordinator.onUnhandledCommand = { received.append($0); return true }

        let consumed = coordinator.textView(textView, doCommandBy: #selector(NSResponder.insertBacktab(_:)))

        #expect(consumed)
        #expect(received == [.backtab])
        #expect(textView.string == "\t- item")
    }

    @Test("Tab inside a fenced code block reaches the host")
    func codeBlockTabFallsBack() {
        let (coordinator, textView) = makeEditor("```\ncode\n```")
        textView.setSelectedRange(NSRange(location: 6, length: 0))
        var received: [MarkdownEditorCommand] = []
        coordinator.onUnhandledCommand = { received.append($0); return true }

        let consumed = coordinator.textView(textView, doCommandBy: #selector(NSResponder.insertTab(_:)))

        #expect(consumed)
        #expect(received == [.tab])
        #expect(textView.string == "```\ncode\n```")
    }

    @Test("Disabled list helpers leave Tab to the host")
    func disabledListHelpersFallBack() {
        let (coordinator, textView) = makeEditor("- item", listHelpersEnabled: false)
        textView.setSelectedRange(NSRange(location: 3, length: 0))
        var received: [MarkdownEditorCommand] = []
        coordinator.onUnhandledCommand = { received.append($0); return true }

        let consumed = coordinator.textView(textView, doCommandBy: #selector(NSResponder.insertTab(_:)))

        #expect(consumed)
        #expect(received == [.tab])
        #expect(textView.string == "- item")
    }

    @Test("Unrelated selectors are ignored")
    func unrelatedSelector() {
        let (coordinator, textView) = makeEditor("plain")
        var hostCalls = 0
        coordinator.onUnhandledCommand = { _ in hostCalls += 1; return true }

        let consumed = coordinator.textView(textView, doCommandBy: #selector(NSResponder.moveLeft(_:)))

        #expect(consumed == false)
        #expect(hostCalls == 0)
    }

    @Test("Omitting the callback preserves AppKit fallback")
    func omittedCallback() {
        let wrapper = NativeTextViewWrapper(text: .constant(""))
        #expect(wrapper.onUnhandledCommand == nil)

        let (coordinator, textView) = makeEditor("plain")
        let consumed = coordinator.textView(textView, doCommandBy: #selector(NSResponder.cancelOperation(_:)))
        #expect(consumed == false)
    }

    private func makeEditor(
        _ text: String,
        rawSourceMode: Bool = false,
        listHelpersEnabled: Bool = true
    ) -> (NativeTextViewCoordinator, NativeTextView) {
        let textView = NativeTextView(frame: NSRect(x: 0, y: 0, width: 300, height: 120))
        textView.isEditable = true
        textView.string = text
        var configuration = MarkdownEditorConfiguration.default
        configuration.rawSourceMode = rawSourceMode
        configuration.lists.helpersEnabled = listHelpersEnabled
        textView.configuration = configuration

        let coordinator = NativeTextViewCoordinator(
            text: .constant(text),
            fontName: "SF Pro Text",
            fontSize: 14,
            isWikiLinkActive: .constant(false),
            onLinkClick: nil,
            onInlineSelectionChange: nil
        )
        coordinator.configuration = configuration
        coordinator.textView = textView
        textView.delegate = coordinator
        return (coordinator, textView)
    }
}
