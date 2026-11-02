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
        let other = FocusTargetView(frame: NSRect(x: 0, y: 110, width: 200, height: 24))
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
        let other = FocusTargetView(frame: NSRect(x: 0, y: 110, width: 200, height: 24))
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
        let other = FocusTargetView(frame: NSRect(x: 0, y: 110, width: 200, height: 24))
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
        let other = FocusTargetView(frame: NSRect(x: 0, y: 110, width: 200, height: 24))
        let window = makeWindow(containing: textView, other)
        try #require(window.makeFirstResponder(other))
        var changes: [Bool] = []
        textView.onFocusChange = { changes.append($0) }

        try #require(window.makeFirstResponder(textView))
        try #require(window.makeFirstResponder(other))

        #expect(changes == [true, false])
    }

    @Test("The coordinator mirrors focus without echoing equal values")
    func coordinatorBinding() async {
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
        #expect(writes == 0)
        await flushFocusReports()
        coordinator.reportFocusChange(false)
        await flushFocusReports()

        #expect(focused == false)
        #expect(writes == 2)
    }

    @Test("Removing the focused editor clears its binding on the next main-queue turn")
    func removalClearsBinding() async throws {
        var focused = true
        let (textView, coordinator) = wiredEditor(Binding(get: { focused }, set: { focused = $0 }))
        let window = makeWindow(containing: textView)
        try #require(window.firstResponder === textView)
        await flushFocusReports()

        textView.removeFromSuperview()
        #expect(focused) // No state mutation inside the removal/update itself.
        #expect(window.firstResponder !== textView)
        await flushFocusReports()
        #expect(!focused)
        withExtendedLifetime(coordinator) {}
    }

    @Test("Closing the editor's window clears focus without relying on resignFirstResponder")
    func closingWindowClearsBinding() async throws {
        var focused = true
        let (textView, coordinator) = wiredEditor(Binding(get: { focused }, set: { focused = $0 }))
        let window = makeWindow(containing: textView)
        window.isReleasedWhenClosed = false
        try #require(window.firstResponder === textView)
        await flushFocusReports()

        window.close()
        #expect(focused)
        await flushFocusReports()
        #expect(!focused)
        withExtendedLifetime(coordinator) {}
    }

    @Test("A constant true binding does not steal focus on an unrelated update")
    func constantTrueDoesNotReclaimFocus() async throws {
        let (textView, coordinator) = wiredEditor(.constant(true))
        let other = FocusTargetView(frame: .zero)
        let window = makeWindow(containing: textView, other)
        try #require(window.firstResponder === textView)
        try #require(window.makeFirstResponder(other))
        await flushFocusReports()

        // The same assignment and reconciliation used by updateNSView.
        textView.requestedFocus = coordinator.isFocused?.wrappedValue
        textView.reconcileRequestedFocus()
        #expect(window.firstResponder === other)
    }

    @Test("A new false-to-true request still focuses an attached editor")
    func changedRequestCanReclaimFocus() throws {
        let textView = NativeTextView(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
        let other = FocusTargetView(frame: .zero)
        textView.requestedFocus = true
        let window = makeWindow(containing: textView, other)
        try #require(window.makeFirstResponder(other))
        textView.requestedFocus = false
        textView.reconcileRequestedFocus()
        #expect(window.firstResponder === other)
        textView.requestedFocus = true
        textView.reconcileRequestedFocus()
        #expect(window.firstResponder === textView)
    }

    @Test("A withdrawn request is not replayed at window attachment")
    func withdrawnPendingRequest() throws {
        let textView = NativeTextView(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
        textView.requestedFocus = true
        textView.reconcileRequestedFocus()
        textView.requestedFocus = nil
        let other = FocusTargetView(frame: .zero)
        let window = makeWindow(containing: other)
        try #require(window.makeFirstResponder(other))
        window.contentView?.addSubview(textView)
        #expect(window.firstResponder === other)
    }

    @Test("A queued removal report survives teardown of the view and coordinator")
    func removalReportSurvivesTeardown() async {
        var focused = true
        autoreleasepool {
            let (textView, coordinator) = wiredEditor(Binding(get: { focused }, set: { focused = $0 }))
            let window = makeWindow(containing: textView)
            textView.removeFromSuperview()
            withExtendedLifetime((window, coordinator)) {}
        }
        await flushFocusReports()
        #expect(!focused)
    }

    @Test("A new focus transition supersedes a queued removal report")
    func reattachmentDoesNotDeliverStaleBlur() async throws {
        var focused = true
        let (textView, coordinator) = wiredEditor(Binding(get: { focused }, set: { focused = $0 }))
        let window = makeWindow(containing: textView)
        textView.removeFromSuperview()
        window.contentView?.addSubview(textView)
        try #require(window.makeFirstResponder(textView))
        await flushFocusReports()
        #expect(focused)
        withExtendedLifetime(coordinator) {}
    }

    private func wiredEditor(_ binding: Binding<Bool>) -> (NativeTextView, NativeTextViewCoordinator) {
        let coordinator = NativeTextViewWrapper(text: .constant(""), isFocused: binding).makeCoordinator()
        coordinator.isFocused = binding
        let textView = NativeTextView(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
        textView.onFocusChange = { [weak coordinator] in coordinator?.reportFocusChange($0) }
        textView.requestedFocus = binding.wrappedValue
        return (textView, coordinator)
    }

    private func flushFocusReports() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.main.async { continuation.resume() }
        }
    }

    /// Focus ownership needs a responder, not another text input client.
    /// An NSTextField starts a field editor and asynchronous InputMethodKit
    /// setup, which can race the run-loop work in other AppKit test suites.
    private final class FocusTargetView: NSView {
        override var acceptsFirstResponder: Bool { true }
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
