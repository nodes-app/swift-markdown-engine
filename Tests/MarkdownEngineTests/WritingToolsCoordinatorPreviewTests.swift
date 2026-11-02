//
//  WritingToolsCoordinatorPreviewTests.swift
//  MarkdownEngineTests
//
//  The doubled words and missing paragraphs of an inline rewrite on macOS 27:
//  Writing Tools animates from snapshots of the text view (the viewport before
//  the edit, then the text below the new text), and without the display pass in
//  `NativeTextView+WritingTools` they show lines that are not drawn yet or not
//  moved yet. Drives NSWritingToolsCoordinator with a hand-made WTSession (no
//  Apple Intelligence), checks every line of both snapshots against where
//  TextKit has it at that moment, and counts what the text view draws below
//  and above the edit. Also covers a document switch mid-slide, and the path of
//  an off-screen suggestion when a proofread selects it.
//
//  Skips, not passes, when the machinery is absent or shaped differently from
//  macOS 27.0.1 (`drivenABI`), or never asks for a snapshot (a CI VM).
//

import AppKit
import ObjectiveC
import SwiftUI
import Testing
@testable import MarkdownEngine

@MainActor
@Suite("Writing Tools remainder snapshot", .serialized)
struct WritingToolsCoordinatorPreviewTests {

    @Test(.enabled("no Writing Tools coordinator machinery in this process") { await CoordinatorDrive.cachedLongReport() != nil })
    func longerRewriteSnapshotsTheTextBelowWhereItLands() async throws {
        let report = try #require(await CoordinatorDrive.cachedLongReport())
        check(report)
    }

    @Test(.enabled("no Writing Tools coordinator machinery in this process") { await CoordinatorDrive.cachedLongReport() != nil })
    func shorterRewriteInAReadingColumnUnderAHeader() async throws {
        try await check(.init(readingWidth: 650, header: true, longRewrite: false, fromTop: false))
    }

    /// The paragraphs being rewritten come back undrawn when the "thinking"
    /// animation ends, right before the viewport snapshot.
    @Test(.enabled("no Writing Tools coordinator machinery in this process") { await CoordinatorDrive.cachedLongReport() != nil })
    func rewriteOfTheFirstParagraphsKeepsThemInThePreEditSnapshot() async throws {
        try await check(.init(readingWidth: nil, header: false, longRewrite: true, fromTop: true))
    }

    /// A proofread's context is one paragraph, so Apple's ranges are relative to it:
    /// read as document offsets they hid text above the edit.
    @Test(.enabled("no Writing Tools coordinator machinery in this process") { await CoordinatorDrive.cachedLongReport() != nil })
    func proofreadMidDocumentHidesOnlyTheTextBelow() async throws {
        let variant = CoordinatorDrive.Variant(readingWidth: 650, header: true, longRewrite: false, fromTop: false, proofread: true)
        var report = await CoordinatorDrive.run(variant)
        if report == nil { report = await CoordinatorDrive.run(variant) }
        let proofread = try #require(report)
        check(proofread)
        // The proofread path skips textDidChange's reset; a leftover swallows the next keystroke's mutation.
        #expect(proofread.pendingEditsAfterEnd == 0)
    }

    /// Bullets, tasks, quote bars, code backgrounds, rules and tables are painted by
    /// the fragment, not as glyphs: a clear foreground alone left them doubled.
    @Test(.enabled("no Writing Tools coordinator machinery in this process") { await CoordinatorDrive.cachedLongReport() != nil })
    func rewriteHidesFragmentDrawnBlocksBelow() async throws {
        try await check(.init(readingWidth: 650, header: true, longRewrite: true, fromTop: false, blocksBelow: true),
                        snapshotLines: false)
    }

    /// Opening another document mid-slide waits for the session to end, and the
    /// binding already belongs to that document: the session's text must not reach it.
    @Test(.enabled("no Writing Tools coordinator machinery in this process") { await CoordinatorDrive.cachedLongReport() != nil })
    func documentSwitchMidSlideLeavesTheNextDocumentAlone() async throws {
        let report = try #require(await CoordinatorDrive.run(
            .init(readingWidth: nil, header: false, longRewrite: true, fromTop: false, switchMidSlide: true)))
        #expect(report.foreignWrites == 0, "the rewritten document's text was written into the next document's binding")
        #expect(report.switchApplied == true, "the next document never reached the text view")
    }

    /// Proofreading scrolls the next suggestion into view in the select completion and
    /// reads its path right there to anchor the explanation panel.
    @Test(.enabled("no Writing Tools coordinator machinery in this process") { await CoordinatorDrive.cachedLongReport() != nil })
    func offscreenSuggestionHasItsPathWhenSelected() async throws {
        guard #available(macOS 15.2, *) else { return }
        let path = try #require(await CoordinatorDrive.selectFarBelow())
        #expect(!path.isEmpty, "the selected suggestion had no bounding path when proofreading asked for it")
    }

    /// A switch while a proofread's suggestion shows: ending the session afterwards
    /// replayed it with this document's ranges into the next one (NSRangeException),
    /// and until then the next document took no updates.
    @Test(.enabled("no Writing Tools coordinator machinery in this process") { await CoordinatorDrive.cachedLongReport() != nil },
          arguments: [true, false])
    func switchWhileAProofreadRestsLeavesTheNextDocumentAlone(accepted: Bool) async throws {
        guard #available(macOS 15.2, *) else { return }
        let end = try #require(await CoordinatorDrive.switchWhileProofreadRests(accepted: accepted))
        #expect(end.stepApplied, "the next document never reached the text view")
        #expect(end.outsideEditArrived, "an edit to the next document never reached the text view")
        #expect(end.text == end.expected)
        #expect(end.binding == end.expected)
        #expect(end.foreignWrites == 0)
    }

    /// ⌘Z during a rewrite: AppKit's own session end then threw on the undone text.
    @Test(.enabled("no Writing Tools coordinator machinery in this process") { await CoordinatorDrive.cachedLongReport() != nil },
          arguments: [true, false])
    func undoDuringARewriteEndsOnTheUndoneText(accepted: Bool) async throws {
        guard #available(macOS 15.2, *) else { return }
        let end = try #require(await CoordinatorDrive.undoDuringRewrite(accepted: accepted))
        #expect(end.stepApplied, "⌘Z did not restore the text")
        #expect(end.text == end.expected)
        #expect(end.binding == end.expected)
    }

    private func check(_ variant: CoordinatorDrive.Variant, snapshotLines: Bool = true) async throws {
        var report = await CoordinatorDrive.run(variant)
        if report == nil { report = await CoordinatorDrive.run(variant) }
        check(try #require(report), snapshotLines: snapshotLines)
    }

    private func check(_ report: CoordinatorDrive.Report, snapshotLines: Bool = true) {
        if snapshotLines {
            #expect(report.inkOffset != nil, "could not read the glyph offset off the pre-edit snapshot: \(report)")
            #expect(report.preEditMissingLineTops.isEmpty,
                    "pre-edit snapshot lacks lines \(report.preEditMissingLineTops); bands \(report.preEditBands)")
            #expect(report.expectedLineTops.count >= 3, "too few lines below the edit to judge: \(report)")
            #expect(report.missingLineTops.isEmpty,
                    "remainder snapshot lacks lines at their current positions \(report.missingLineTops); bands \(report.bands)")
        }
        // What the text view draws: nothing below the edit under the sliding snapshot,
        // all of it afterwards, and the text above the edit throughout.
        #expect(report.inkBelowDuringSlide == 0, "the text below the edit drew \(report.inkBelowDuringSlide) px under its sliding snapshot")
        #expect(report.inkBelowAfterwards > 0, "the text below the edit stayed hidden")
        #expect(report.inkAboveDuringSlide != 0, "the text above the edit was hidden")
    }
}

// MARK: - The drive

@MainActor
private enum CoordinatorDrive {
    struct Variant {
        let readingWidth: CGFloat?
        let header: Bool
        let longRewrite: Bool
        /// Rewrite the first three paragraphs after a long "thinking" phase, as a real session does.
        let fromTop: Bool
        /// Proofread one suggestion instead of rewriting the paragraph.
        var proofread = false
        /// A list, task, quote, code block, rule and table right below the edit.
        var blocksBelow = false
        /// Open another document mid-slide instead of finishing the session.
        var switchMidSlide = false
    }

    struct Report: CustomStringConvertible {
        /// Ink band tops of the remainder snapshot, points from its top.
        var bands: [CGFloat] = []
        var preEditBands: [CGFloat] = []
        var preEditMissingLineTops: [CGFloat] = []
        /// Tops of the lines below the edit, as TextKit had them when AppKit asked.
        var expectedLineTops: [CGFloat] = []
        var missingLineTops: [CGFloat] = []
        /// Glyph ink below a line's top, read off the pre-edit snapshot.
        var inkOffset: CGFloat?
        /// Ink pixels the text view draws below the edit (and in the line above it); -1 = none to judge.
        var inkBelowDuringSlide = -1
        var inkBelowAfterwards = -1
        var inkAboveDuringSlide = -1
        /// Writes of anything but the next document's text into its binding.
        var foreignWrites = 0
        var switchApplied: Bool?
        /// Edits the coordinator still counts as pending once the session ended.
        var pendingEditsAfterEnd = -1
        var description: String { "bands \(bands) expected \(expectedLineTops) inkOffset \(String(describing: inkOffset))" }
    }

    /// Probe + cache in one: serves the gate and the first test.
    private static var longReport: Report??

    static func cachedLongReport() async -> Report? {
        if let cached = longReport { return cached }
        let report = await run(.init(readingWidth: nil, header: false, longRewrite: true, fromTop: false))
        longReport = .some(report)
        return report
    }

    // MARK: Gate

    /// Every private method the drive calls, with its type encoding as measured on
    /// macOS 27.0.1; any other shape skips instead of corrupting the stack.
    private static let drivenABI: [(cls: String, sel: String, encoding: String)] = [
        ("NSTextView", "_ensureWritingToolsCoordinatorCreated", "@16@0:8"),
        ("NSTextView", "writingToolsCoordinator:requestsPreviewForRect:inContext:completion:", "v72@0:8@16{CGRect={CGPoint=dd}{CGSize=dd}}24@56@?64"),
        ("NSWritingToolsCoordinator", "willBeginWritingToolsSession:requestContexts:", "v32@0:8@16@?24"),
        ("NSWritingToolsCoordinator", "didBeginWritingToolsSession:contexts:", "v32@0:8@16@24"),
        ("NSWritingToolsCoordinator", "writingToolsSession:didReceiveAction:", "v32@0:8@16q24"),
        ("NSWritingToolsCoordinator", "compositionSession:didReceiveText:replacementRange:inContext:finished:", "v60@0:8@16@24{_NSRange=QQ}32@48B56"),
        ("NSWritingToolsCoordinator", "didEndWritingToolsSession:accepted:", "v28@0:8@16B24"),
        ("WTSession", "initWithType:textViewDelegate:", "@32@0:8q16@24"),
        ("WTSession", "setCompositionSessionType:", "v24@0:8q16"),
        ("WTContext", "range", "{_NSRange=QQ}16@0:8"),
        ("WTContext", "attributedText", "@16@0:8"),
        ("WTTextSuggestion", "initWithOriginalRange:replacement:", "@40@0:8{_NSRange=QQ}16@32"),
        ("NSWritingToolsCoordinator", "proofreadingSession:didReceiveSuggestions:processedRange:inContext:finished:", "v60@0:8@16@24{_NSRange=QQ}32@48B56"),
        ("NSTextView", "writingToolsCoordinator:requestsContextsForScope:completion:", "v40@0:8@16q24@?32"),
        ("NSTextView", "writingToolsCoordinator:selectRanges:inContext:completion:", "v48@0:8@16@24@32@?40"),
        ("NSTextView", "writingToolsCoordinator:requestsBoundingBezierPathsForRange:inContext:completion:", "v56@0:8@16{_NSRange=QQ}24@40@?48"),
    ]

    private static var machineryPresent: Bool {
        guard #available(macOS 15.2, *) else { return false }
        return drivenABI.allSatisfy { entry in
            guard let cls = NSClassFromString(entry.cls),
                  let method = class_getInstanceMethod(cls, NSSelectorFromString(entry.sel)),
                  let encoding = method_getTypeEncoding(method) else { return false }
            return String(cString: encoding) == entry.encoding
        }
    }

    // MARK: Recording hook (installed once per process; calls NSTextView's IMP)

    private struct Snapshot {
        let rect: CGRect
        let lineTops: [CGFloat]
        var bands: [CGFloat]?
    }
    private final class Recorder {
        var snapshots: [ObjectIdentifier: [Snapshot]] = [:]
    }
    private static let recorder = Recorder()
    private static var hookInstalled = false

    private static func installHook() -> Bool {
        if hookInstalled { return true }
        guard #available(macOS 15.2, *) else { return false }
        let cls: AnyClass = NativeTextView.self
        let sel = NSSelectorFromString("writingToolsCoordinator:requestsPreviewForRect:inContext:completion:")
        guard let method = class_getInstanceMethod(cls, sel),
              let original = class_getMethodImplementation(cls, sel) else { return false }
        typealias Completion = @convention(block) (NSTextPreview?) -> Void
        typealias Original = @convention(c) (AnyObject, Selector, AnyObject, NSRect, AnyObject, Completion) -> Void
        let call = unsafeBitCast(original, to: Original.self)
        let block: @convention(block) (AnyObject, AnyObject, NSRect, AnyObject, @escaping Completion) -> Void = { me, coordinator, rect, context, done in
            let key = ObjectIdentifier(me)
            let tops = (me as? NSTextView).map { lineTops($0, in: rect) } ?? []
            recorder.snapshots[key, default: []].append(Snapshot(rect: rect, lineTops: tops))
            let index = recorder.snapshots[key]!.count - 1
            call(me, sel, coordinator, rect, context) { preview in
                if let image = preview?.previewImage {
                    recorder.snapshots[key]?[index].bands = inkBandTops(image, pointsTall: rect.height)
                }
                done(preview)
            }
        }
        class_replaceMethod(cls, sel, imp_implementationWithBlock(block), method_getTypeEncoding(method))
        hookInstalled = true
        return true
    }

    /// Tops of the lines with text inside `rect`, points from its top.
    private static func lineTops(_ tv: NSTextView, in rect: CGRect) -> [CGFloat] {
        guard let tlm = tv.textLayoutManager else { return [] }
        let origin = tv.textContainerOrigin
        var tops: [CGFloat] = []
        tlm.enumerateTextLayoutFragments(from: tlm.documentRange.location, options: []) { fragment in
            let frame = fragment.layoutFragmentFrame.offsetBy(dx: origin.x, dy: origin.y)
            if frame.minY > rect.maxY { return false }
            if frame.maxY >= rect.minY {
                // Blank paragraphs carry no ink, so no band to find.
                for line in fragment.textLineFragments
                where !line.attributedString.attributedSubstring(from: line.characterRange).string
                    .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    tops.append(frame.minY + line.typographicBounds.minY - rect.minY)
                }
            }
            return true
        }
        return tops
    }

    /// Tops of the horizontal bands that carry ink, points from the image's top.
    private static func inkBandTops(_ image: CGImage, pointsTall: CGFloat) -> [CGFloat] {
        let width = image.width, height = image.height
        guard width > 0, height > 0,
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let data = context.data else { return [] }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        let pixels = data.bindMemory(to: UInt8.self, capacity: width * height * 4)
        let scale = CGFloat(height) / pointsTall
        var tops: [CGFloat] = []
        var inInk = false
        for row in 0..<height {   // memory row 0 is the image's top
            var ink = false
            for x in 0..<width where pixels[(row * width + x) * 4 + 3] > 40 { ink = true; break }
            if ink && !inInk { tops.append(CGFloat(row) / scale) }
            inInk = ink
        }
        return tops
    }

    // MARK: Hosting

    /// One text for whichever document is open, bound the way Nodes binds it.
    private final class Document: ObservableObject {
        static let next = (1...30).map { "Other note \($0). Different content." }.joined(separator: "\n\n")
        @Published var id = "A"
        @Published var text: String {
            didSet { if id != "A" && text != Self.next && text != outsideEdit { foreignWrites += 1 } }
        }
        /// An edit to the next document made outside the editor, not a foreign write.
        var outsideEdit: String?
        var foreignWrites = 0
        init(text: String) { self.text = text }
    }

    private struct Host: View {
        @ObservedObject var document: Document
        let readingWidth: CGFloat?
        let header: Bool
        var body: some View {
            var config = MarkdownEditorConfiguration.default
            config.readingWidth = readingWidth
            return NativeTextViewWrapper(
                text: $document.text,
                configuration: config,
                documentId: document.id,
                header: header ? AnyView(Color.gray.frame(height: 60)) : nil
            )
        }
    }

    private static func markdown(blocksBelow: Bool) -> String {
        var paragraphs = (1...120).map {
            "Paragraph \($0). The quick brown fox jumps over the lazy dog while the writing tools think about it."
        }
        if blocksBelow {
            paragraphs.insert(contentsOf: ["- bullet one\n- bullet two", "- [ ] a task", "> a quote", "```\ncode\n```", "---",
                                           "| a | b |\n|---|---|\n| 1 | 2 |"], at: 40)
        }
        return paragraphs.joined(separator: "\n\n")
    }

    /// AppKit keeps effect work in flight past the session; a torn-down window under it crashes the host.
    private static var windows: [NSWindow] = []

    private static func findViews(_ root: NSView) -> (NSScrollView, NativeTextView)? {
        if let sv = root as? NSScrollView, let tv = sv.nativeTextView { return (sv, tv) }
        for sub in root.subviews {
            if let found = findViews(sub) { return found }
        }
        return nil
    }

    private static func runLoopSlice() {
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.01))
    }

    /// Async on purpose: the coordinator answers through the main queue, which a
    /// run loop nested inside a main-actor test body never drains. Sleeping hands
    /// the main queue back; the run-loop slice keeps timers and CA commits going.
    private static func spin(_ seconds: TimeInterval) async {
        let deadline = Date(timeIntervalSinceNow: seconds)
        while Date() < deadline {
            runLoopSlice()
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
    }

    private static func spin(until condition: () -> Bool, limit: TimeInterval) async -> Bool {
        let deadline = Date(timeIntervalSinceNow: limit)
        while Date() < deadline {
            if condition() { return true }
            await spin(0.02)
        }
        return condition()
    }

    // MARK: The session

    private final class ContextBox {
        var contexts: [NSObject]?
    }

    /// The editor in a window, hosted the way Nodes hosts it.
    private struct Stage {
        let window: NSWindow
        let document: Document
        let scrollView: NSScrollView
        let textView: NativeTextView
    }

    private static func stage(readingWidth: CGFloat?, header: Bool, blocksBelow: Bool = false) async -> Stage? {
        _ = NSApplication.shared
        let window = NSWindow(
            contentRect: NSRect(x: -30000, y: -30000, width: 900, height: 600),
            styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        let document = Document(text: markdown(blocksBelow: blocksBelow))
        window.contentView = NSHostingView(rootView: Host(document: document, readingWidth: readingWidth, header: header))
        window.orderFrontRegardless()
        windows.append(window)
        var found: (NSScrollView, NativeTextView)?
        guard await spin(until: { found = findViews(window.contentView!); return found != nil }, limit: 3),
              let (sv, tv) = found else {
            window.orderOut(nil)
            return nil
        }
        await spin(0.4)
        return Stage(window: window, document: document, scrollView: sv, textView: tv)
    }

    /// Paragraph 40 (or the first three) selected and scrolled near the top, with plenty of text below.
    private static func selectEditTarget(in stage: Stage, fromTop: Bool) async -> NSRange? {
        let tv = stage.textView, sv = stage.scrollView
        guard let tlm = tv.textLayoutManager else { return nil }
        let ns = tv.string as NSString
        let paragraph = ns.paragraphRange(for: NSRange(location: ns.range(of: "Paragraph 40.").location, length: 0))
        let selection = fromTop
            ? NSRange(location: 0, length: ns.range(of: "Paragraph 4.").location - 1)
            : NSRange(location: paragraph.location, length: paragraph.length - 1)
        tv.setSelectedRange(selection)
        tlm.ensureLayout(for: tlm.documentRange)
        guard let start = tlm.location(tlm.documentRange.location, offsetBy: selection.location),
              let fragment = tlm.textLayoutFragment(for: start) else { return nil }
        let top = tv.rectInClipView(fragment.layoutFragmentFrame.offsetBy(dx: 0, dy: tv.textContainerOrigin.y)).minY
        sv.contentView.scroll(to: NSPoint(x: 0, y: max(0, top - 100)))
        sv.reflectScrolledClipView(sv.contentView)
        stage.window.makeFirstResponder(tv)
        stage.window.displayIfNeeded()
        await spin(0.1)
        return selection
    }

    /// The private calls the Writing Tools service makes on a text view's coordinator.
    private struct Session {
        let coordinator: NSObject
        let session: NSObject
        let contexts: [NSObject]

        var contextRange: NSRange? { (contexts.first?.value(forKey: "range") as? NSValue)?.rangeValue }

        func didBegin() {
            let sel = NSSelectorFromString("didBeginWritingToolsSession:contexts:")
            typealias DidBegin = @convention(c) (AnyObject, Selector, AnyObject, NSArray) -> Void
            guard let imp = coordinator.method(for: sel) else { return }
            unsafeBitCast(imp, to: DidBegin.self)(coordinator, sel, session, contexts as NSArray)
        }

        func action(_ action: Int) {
            let sel = NSSelectorFromString("writingToolsSession:didReceiveAction:")
            typealias Action = @convention(c) (AnyObject, Selector, AnyObject, Int) -> Void
            guard let imp = coordinator.method(for: sel) else { return }
            unsafeBitCast(imp, to: Action.self)(coordinator, sel, session, action)
        }

        func deliver(_ text: NSAttributedString, replacing range: NSRange) {
            let sel = NSSelectorFromString("compositionSession:didReceiveText:replacementRange:inContext:finished:")
            typealias Deliver = @convention(c) (AnyObject, Selector, AnyObject, NSAttributedString, NSRange, AnyObject, Bool) -> Void
            guard let imp = coordinator.method(for: sel), let context = contexts.first else { return }
            unsafeBitCast(imp, to: Deliver.self)(coordinator, sel, session, text, range, context, true)
        }

        /// One suggestion replacing `word` in the context's first `processed` characters.
        func suggest(_ replacement: String, for word: String, processed: NSRange) -> Bool {
            let text = (contexts.first?.value(forKey: "attributedText") as? NSAttributedString)?.string as NSString? ?? ""
            guard processed.location <= text.length else { return false }
            let found = text.range(of: word, options: [], range: NSRange(
                location: processed.location, length: min(processed.length, text.length - processed.location)))
            let initSel = NSSelectorFromString("initWithOriginalRange:replacement:")
            typealias SuggestionInit = @convention(c) (AnyObject, Selector, NSRange, NSString) -> Unmanaged<AnyObject>
            let sel = NSSelectorFromString("proofreadingSession:didReceiveSuggestions:processedRange:inContext:finished:")
            typealias Deliver = @convention(c) (AnyObject, Selector, AnyObject, NSArray, NSRange, AnyObject, Bool) -> Void
            guard found.location != NSNotFound, let cls = NSClassFromString("WTTextSuggestion") as? NSObject.Type,
                  let allocated = cls.perform(NSSelectorFromString("alloc"))?.takeUnretainedValue(),
                  let initIMP = class_getMethodImplementation(cls, initSel),
                  let imp = coordinator.method(for: sel), let context = contexts.first else { return false }
            let suggestion = unsafeBitCast(initIMP, to: SuggestionInit.self)(allocated, initSel, found, replacement as NSString)
                .takeRetainedValue()
            unsafeBitCast(imp, to: Deliver.self)(coordinator, sel, session, [suggestion] as NSArray, processed, context, true)
            return true
        }

        func end(accepted: Bool) {
            let sel = NSSelectorFromString("didEndWritingToolsSession:accepted:")
            typealias DidEnd = @convention(c) (AnyObject, Selector, AnyObject, Bool) -> Void
            guard let imp = coordinator.method(for: sel) else { return }
            unsafeBitCast(imp, to: DidEnd.self)(coordinator, sel, session, accepted)
        }
    }

    /// Starts a session on `tv` and waits for its contexts. Type 1 = proofread,
    /// 2 = composition; composition type 10 = the animated inline replace.
    private static func begin(on tv: NativeTextView, proofread: Bool) async -> Session? {
        let ensureSel = NSSelectorFromString("_ensureWritingToolsCoordinatorCreated")
        let initSel = NSSelectorFromString("initWithType:textViewDelegate:")
        let willBegin = NSSelectorFromString("willBeginWritingToolsSession:requestContexts:")
        typealias Getter = @convention(c) (AnyObject, Selector) -> Unmanaged<AnyObject>?
        typealias Init = @convention(c) (AnyObject, Selector, Int, AnyObject?) -> Unmanaged<AnyObject>
        typealias WillBegin = @convention(c) (AnyObject, Selector, AnyObject, @escaping @convention(block) (NSArray?) -> Void) -> Void
        guard let ensureIMP = tv.method(for: ensureSel),
              let coordinator = unsafeBitCast(ensureIMP, to: Getter.self)(tv, ensureSel)?.takeUnretainedValue() as? NSObject,
              let sessionCls = NSClassFromString("WTSession") as? NSObject.Type,
              let allocated = sessionCls.perform(NSSelectorFromString("alloc"))?.takeUnretainedValue(),
              let initIMP = class_getMethodImplementation(sessionCls, initSel),
              let willBeginIMP = coordinator.method(for: willBegin) else { return nil }
        let session = unsafeBitCast(initIMP, to: Init.self)(allocated, initSel, proofread ? 1 : 2, nil).takeRetainedValue() as! NSObject
        if !proofread { session.setValue(10, forKey: "compositionSessionType") }
        let box = ContextBox()
        unsafeBitCast(willBeginIMP, to: WillBegin.self)(coordinator, willBegin, session) { box.contexts = $0 as? [NSObject] ?? [] }
        guard await spin(until: { box.contexts != nil }, limit: 1.5), let contexts = box.contexts, !contexts.isEmpty else { return nil }
        return Session(coordinator: coordinator, session: session, contexts: contexts)
    }

    private static func writingToolsActive(_ tv: NSTextView) -> Bool {
        if #available(macOS 15.0, *) { return tv.isWritingToolsActive }
        return false
    }

    /// `nil` = the machinery is absent or never asked for the remainder snapshot.
    static func run(_ variant: Variant) async -> Report? {
        guard machineryPresent, installHook(),
              let stage = await stage(readingWidth: variant.readingWidth, header: variant.header,
                                      blocksBelow: variant.blocksBelow) else { return nil }
        defer { stage.window.orderOut(nil) }
        let tv = stage.textView
        let key = ObjectIdentifier(tv)
        recorder.snapshots[key] = []
        guard let selection = await selectEditTarget(in: stage, fromTop: variant.fromTop),
              let wt = await begin(on: tv, proofread: variant.proofread) else { return nil }
        defer { withExtendedLifetime(wt) {} }
        wt.didBegin()
        let contextRange = wt.contextRange ?? selection
        await spin(0.1)

        // Action 3 ("pondering") is where the coordinator installs its effect view.
        wt.action(3)
        await spin(variant.fromTop ? 1.6 : 0.6)

        if variant.proofread {
            // One short suggestion, so the engine takes its proofread branch.
            guard wt.suggest("fast", for: "quick", processed: contextRange) else { return nil }
        } else {
            // Deliver with the paragraph's own attributes, as Writing Tools does.
            let body = variant.longRewrite
                ? (0..<5).map { "Rewritten sentence \($0) that is longer than the original paragraph was." }.joined(separator: " ")
                : "A much shorter rewrite."
            let attributes = tv.textStorage?.attributes(at: selection.location, effectiveRange: nil) ?? [:]
            wt.deliver(NSAttributedString(string: body, attributes: attributes), replacing: contextRange)
        }

        // The pre-edit viewport snapshot, then the remainder below the new text.
        _ = await spin(until: { (recorder.snapshots[key] ?? []).filter { $0.bands != nil }.count >= 2 }, limit: 1.5)
        let snapshots = recorder.snapshots[key] ?? []

        if variant.switchMidSlide {
            await spin(0.5)
            stage.document.text = Document.next
            stage.document.id = "B"
            await spin(0.05)
            // The real service ends the session when the engine stops it; this one is told to.
            wt.end(accepted: false)
            var result = Report()
            result.switchApplied = await spin(until: { tv.string.hasPrefix("Other note") }, limit: 4)
            await spin(0.3)
            result.foreignWrites = stage.document.foreignWrites
            return result
        }

        // Mid-slide, then after the animation (the session and the window go last).
        await spin(0.3)
        // The remainder rect starts at the end of the new text; skip the caret line.
        let below = (snapshots.last?.rect ?? .zero).insetBy(dx: 0, dy: 15).offsetBy(dx: 0, dy: 15).intersection(tv.visibleRect)
        let inkBelowDuringSlide = inkCount(tv, in: below)
        // The last line of the paragraph above the edit (none when rewriting from the top).
        let inkAboveDuringSlide = variant.fromTop ? -1 : inkCount(tv, in: lineAbove(selection, in: tv))
        _ = await spin(until: { inkCount(tv, in: below) > 0 }, limit: 2)
        let inkBelowAfterwards = inkCount(tv, in: below)
        wt.end(accepted: true)
        _ = await spin(until: { !writingToolsActive(tv) }, limit: 1)
        await spin(0.1)

        guard snapshots.count >= 2, let before = snapshots.first, let beforeBands = before.bands,
              let remainder = snapshots.last, let bands = remainder.bands else { return nil }
        var result = report(before: before.lineTops, beforeBands: beforeBands,
                            after: remainder.lineTops, afterBands: bands, height: remainder.rect.height)
        result.inkBelowDuringSlide = inkBelowDuringSlide
        result.inkBelowAfterwards = inkBelowAfterwards
        result.inkAboveDuringSlide = inkAboveDuringSlide
        result.pendingEditsAfterEnd = (tv.delegate as? NativeTextViewCoordinator)?.pendingEditCount ?? -1
        return result
    }

    /// What the text view and the binding hold once a session has ended.
    struct SessionEnd {
        /// The step before the end took effect: the switch, or the undo.
        var stepApplied = false
        /// An edit to the next document from outside reached the text view.
        var outsideEditArrived = false
        var expected = ""
        var text = ""
        var binding = ""
        var foreignWrites = 0
    }

    /// A proofread whose suggestion shows, then a switch to the next document, an edit
    /// to it from outside, and the end of the session.
    @available(macOS 15.2, *)
    static func switchWhileProofreadRests(accepted: Bool) async -> SessionEnd? {
        guard machineryPresent, let stage = await stage(readingWidth: 650, header: true) else { return nil }
        defer { stage.window.orderOut(nil) }
        let tv = stage.textView
        guard let selection = await selectEditTarget(in: stage, fromTop: false),
              let wt = await begin(on: tv, proofread: true) else { return nil }
        defer { withExtendedLifetime(wt) {} }
        wt.didBegin()
        wt.action(3)
        await spin(0.6)
        guard wt.suggest("fast", for: "quick", processed: wt.contextRange ?? selection),
              await spin(until: { tv.writingToolsCoordinator?.state == .interactiveResting }, limit: 3) else { return nil }

        var result = SessionEnd()
        stage.document.text = Document.next
        stage.document.id = "B"
        result.stepApplied = await spin(until: { tv.string == Document.next }, limit: 4)
        let edited = Document.next + "\n\nAn edit from outside."
        stage.document.outsideEdit = edited
        stage.document.text = edited
        result.outsideEditArrived = await spin(until: { tv.string == edited }, limit: 1)
        // The real service ends the session when the engine stops it; this one is told to.
        wt.end(accepted: accepted)
        await spin(0.5)
        result.expected = edited
        result.text = tv.string
        result.binding = stage.document.text
        result.foreignWrites = stage.document.foreignWrites
        return result
    }

    /// A rewrite at rest, ⌘Z, and the end of the session.
    @available(macOS 15.2, *)
    static func undoDuringRewrite(accepted: Bool) async -> SessionEnd? {
        guard machineryPresent, let stage = await stage(readingWidth: 650, header: true) else { return nil }
        defer { stage.window.orderOut(nil) }
        let tv = stage.textView
        let original = tv.string
        guard let selection = await selectEditTarget(in: stage, fromTop: false),
              let wt = await begin(on: tv, proofread: false) else { return nil }
        defer { withExtendedLifetime(wt) {} }
        wt.didBegin()
        wt.action(3)
        await spin(0.6)
        let attributes = tv.textStorage?.attributes(at: selection.location, effectiveRange: nil) ?? [:]
        wt.deliver(NSAttributedString(string: "A much shorter rewrite.", attributes: attributes),
                   replacing: wt.contextRange ?? selection)
        guard await spin(until: { tv.writingToolsCoordinator?.state == .interactiveResting }, limit: 3) else { return nil }

        var result = SessionEnd()
        tv.undoManager?.undo()
        result.stepApplied = await spin(until: { tv.string == original }, limit: 1)
        wt.end(accepted: accepted)
        _ = await spin(until: { stage.document.text == original }, limit: 1)
        result.expected = original
        result.text = tv.string
        result.binding = stage.document.text
        return result
    }

    /// Selects a paragraph far below the viewport the way proofreading steps to its next
    /// suggestion, and returns the bounding box of the path it then asks for at once.
    @available(macOS 15.2, *)
    static func selectFarBelow() async -> NSRect? {
        guard machineryPresent, installContextHook(),
              let stage = await stage(readingWidth: 650, header: true) else { return nil }
        defer { stage.window.orderOut(nil) }
        let tv = stage.textView
        // A proofread of paragraphs 40-110 with the viewport at the top.
        let ns = tv.string as NSString
        let first = ns.range(of: "Paragraph 40.").location, last = ns.range(of: "Paragraph 111.").location - 2
        tv.setSelectedRange(NSRange(location: first, length: last - first))
        stage.window.makeFirstResponder(tv)
        await spin(0.1)

        capturedContexts = []
        guard let wt = await begin(on: tv, proofread: true) else { return nil }
        defer { withExtendedLifetime(wt) {} }
        guard let context = capturedContexts.first as? NSWritingToolsCoordinator.Context,
              let contextStart = tv.writingToolsContextStarts[context.identifier] else { return nil }
        wt.didBegin()
        await spin(0.1)

        let target = NSRange(location: ns.range(of: "Paragraph 100.").location - contextStart, length: 14)
        let select = NSSelectorFromString("writingToolsCoordinator:selectRanges:inContext:completion:")
        let bounding = NSSelectorFromString("writingToolsCoordinator:requestsBoundingBezierPathsForRange:inContext:completion:")
        typealias Select = @convention(c) (AnyObject, Selector, AnyObject, NSArray, AnyObject, @escaping @convention(block) () -> Void) -> Void
        typealias Bounding = @convention(c) (AnyObject, Selector, AnyObject, NSRange, AnyObject, @escaping @convention(block) (NSArray) -> Void) -> Void
        guard let selectIMP = tv.method(for: select), let boundingIMP = tv.method(for: bounding) else { return nil }
        var result: NSRect?
        unsafeBitCast(selectIMP, to: Select.self)(tv, select, wt.coordinator, [NSValue(range: target)] as NSArray, context) {
            unsafeBitCast(boundingIMP, to: Bounding.self)(tv, bounding, wt.coordinator, target, context) { paths in
                result = (paths as? [NSBezierPath] ?? []).reduce(NSRect.null) { $0.union($1.bounds) }
            }
        }
        let answered = await spin(until: { result != nil }, limit: 1)
        wt.end(accepted: false)
        await spin(0.3)
        guard answered, let result else { return nil }
        return result.isNull ? .zero : result
    }

    /// The contexts NSTextView hands the coordinator; select and paths only answer for those.
    private static var capturedContexts: [AnyObject] = []
    private static var contextHookInstalled = false

    private static func installContextHook() -> Bool {
        if contextHookInstalled { return true }
        let cls: AnyClass = NativeTextView.self
        let sel = NSSelectorFromString("writingToolsCoordinator:requestsContextsForScope:completion:")
        guard let method = class_getInstanceMethod(cls, sel),
              let original = class_getMethodImplementation(cls, sel) else { return false }
        typealias Completion = @convention(block) (NSArray) -> Void
        typealias Original = @convention(c) (AnyObject, Selector, AnyObject, Int, Completion) -> Void
        let call = unsafeBitCast(original, to: Original.self)
        let block: @convention(block) (AnyObject, AnyObject, Int, @escaping Completion) -> Void = { me, coordinator, scope, done in
            call(me, sel, coordinator, scope) { contexts in
                capturedContexts = contexts as [AnyObject]
                done(contexts)
            }
        }
        class_replaceMethod(cls, sel, imp_implementationWithBlock(block), method_getTypeEncoding(method))
        contextHookInstalled = true
        return true
    }

    /// Pixels with ink in a fresh draw of `rect` (the text view draws no background here).
    private static func inkCount(_ tv: NSTextView, in rect: NSRect) -> Int {
        let area = rect.intersection(tv.bounds)
        guard !area.isEmpty, let rep = tv.bitmapImageRepForCachingDisplay(in: area) else { return -1 }
        tv.cacheDisplay(in: area, to: rep)
        return rep.cgImage.map(inkPixels) ?? -1
    }

    private static func inkPixels(_ image: CGImage) -> Int {
        let width = image.width, height = image.height
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let data = context.data else { return -1 }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        let pixels = data.bindMemory(to: UInt8.self, capacity: width * height * 4)
        return (0..<(width * height)).reduce(0) { $0 + (pixels[$1 * 4 + 3] > 40 ? 1 : 0) }
    }

    /// The paragraph just above `selection`'s, in text view coordinates.
    private static func lineAbove(_ selection: NSRange, in tv: NSTextView) -> NSRect {
        guard selection.location >= 3, let tlm = tv.textLayoutManager, let content = tlm.textContentManager,
              let above = content.location(content.documentRange.location, offsetBy: selection.location - 3),
              let fragment = tlm.textLayoutFragment(for: above) else { return .zero }
        return fragment.layoutFragmentFrame.offsetBy(dx: tv.textContainerOrigin.x, dy: tv.textContainerOrigin.y)
    }

    /// The glyph offset is the one shift that puts the most pre-edit line tops onto
    /// pre-edit bands; the remainder must then show each of its lines there.
    private static func report(before: [CGFloat], beforeBands: [CGFloat],
                               after: [CGFloat], afterBands: [CGFloat], height: CGFloat) -> Report {
        var report = Report()
        report.bands = afterBands
        report.preEditBands = beforeBands
        func hits(_ offset: CGFloat) -> Int {
            before.filter { top in beforeBands.contains { abs($0 - (top + offset)) <= 1 } }.count
        }
        let candidates = before.flatMap { top in beforeBands.map { $0 - top } }.filter { $0 >= 0 && $0 <= 12 }
        guard let best = candidates.max(by: { hits($0) < hits($1) }), hits(best) >= 3 else { return report }
        report.inkOffset = best
        report.preEditMissingLineTops = before.filter { $0 + best >= 1 && $0 + best <= height - 30 }.filter { top in
            !beforeBands.contains { abs($0 - (top + best)) <= 1.5 }
        }
        report.expectedLineTops = Array(after.filter { $0 + best >= 1 && $0 + best <= height - 30 }.prefix(4))
        report.missingLineTops = report.expectedLineTops.filter { top in
            !afterBands.contains { abs($0 - (top + best)) <= 1.5 }
        }
        return report
    }
}
