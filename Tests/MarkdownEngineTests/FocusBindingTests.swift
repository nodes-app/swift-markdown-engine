//
//  FocusBindingTests.swift
//  MarkdownEngineTests
//

import AppKit
import SwiftUI
import Testing
@testable import MarkdownEngine

@MainActor
@Suite("Embedder focus binding", .serialized)
struct FocusBindingTests {
    @Test("A pending focus request is fulfilled after window attachment")
    func pendingRequest() {
        let textView = NativeTextView(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
        textView.requestedFocus = true

        let window = makeWindow(containing: textView)

        #expect(window.firstResponder === textView)
    }

    @Test("An attached editor fulfills a true request during reconciliation")
    func attachedRequest() throws {
        let textView = NativeTextView(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
        let other = NSTextField(frame: NSRect(x: 0, y: 110, width: 200, height: 24))
        let window = makeWindow(containing: textView, other)
        try #require(window.makeFirstResponder(other))

        textView.requestedFocus = true
        textView.reconcileRequestedFocus()

        #expect(window.firstResponder === textView)
    }

    @Test("False releases this editor when it owns focus")
    func falseReleasesEditor() throws {
        let textView = NativeTextView(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
        let window = makeWindow(containing: textView)
        try #require(window.makeFirstResponder(textView))

        textView.requestedFocus = false
        textView.reconcileRequestedFocus()

        #expect(window.firstResponder !== textView)
    }

    @Test("False only resigns this editor")
    func falseDoesNotDisturbAnotherResponder() throws {
        let textView = NativeTextView(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
        let other = NSTextField(frame: NSRect(x: 0, y: 110, width: 200, height: 24))
        let window = makeWindow(containing: textView, other)
        try #require(window.makeFirstResponder(other))
        let otherResponder = try #require(window.firstResponder)

        textView.requestedFocus = false
        textView.reconcileRequestedFocus()

        #expect(window.firstResponder === otherResponder)
        #expect(window.firstResponder !== textView)
    }

    @Test("Omitting focus state leaves AppKit ownership unchanged")
    func omittedBindingCompatibility() throws {
        let wrapper = NativeTextViewWrapper(text: .constant(""))
        #expect(wrapper.isFocused == nil)

        let textView = NativeTextView(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
        let other = NSTextField(frame: NSRect(x: 0, y: 110, width: 200, height: 24))
        let window = makeWindow(containing: textView, other)
        try #require(window.makeFirstResponder(other))
        let otherResponder = try #require(window.firstResponder)

        textView.requestedFocus = nil
        textView.reconcileRequestedFocus()

        #expect(window.firstResponder === otherResponder)
        #expect(window.firstResponder !== textView)
    }

    @Test("First-responder changes are reported once per transition")
    func reportsTransitions() throws {
        let textView = NativeTextView(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
        let other = NSTextField(frame: NSRect(x: 0, y: 110, width: 200, height: 24))
        let window = makeWindow(containing: textView, other)
        try #require(window.makeFirstResponder(other))
        var changes: [Bool] = []
        textView.onFocusChange = { changes.append($0) }

        try #require(window.makeFirstResponder(textView))
        try #require(window.makeFirstResponder(other))

        #expect(changes == [true, false])
    }

    @Test("The coordinator mirrors focus without echoing equal values")
    func coordinatorBinding() {
        var focused = false
        var writes = 0
        let binding = Binding(
            get: { focused },
            set: { focused = $0; writes += 1 }
        )
        let coordinator = NativeTextViewCoordinator(
            text: .constant(""),
            fontName: "SF Pro Text",
            fontSize: 14,
            isWikiLinkActive: .constant(false),
            onLinkClick: nil,
            onInlineSelectionChange: nil
        )
        coordinator.isFocused = binding

        coordinator.reportFocusChange(true)
        coordinator.reportFocusChange(true)
        coordinator.reportFocusChange(false)

        #expect(focused == false)
        #expect(writes == 2)
    }

    private func makeWindow(containing views: NSView...) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 200),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        let content = NSView(frame: window.contentView?.bounds ?? .zero)
        views.forEach { content.addSubview($0) }
        window.contentView = content
        return window
    }
}
