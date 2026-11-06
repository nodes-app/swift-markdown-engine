//
//  FileDropTests.swift
//  MarkdownEngineTests
//
//  Files dragged onto the text (`EditorFileDrop`): the embedder decides per drop
//  whether they go into the text, to itself, or nowhere, and text drags are left
//  to AppKit.
//

import AppKit
import Testing
@testable import MarkdownEngine

@MainActor
@Suite("File drop")
struct FileDropTests {

    /// Just enough of a drag for the text view's decisions: a pasteboard and a point.
    private final class FakeDrag: NSObject, NSDraggingInfo {
        let draggingPasteboard: NSPasteboard
        let draggingLocation: NSPoint
        let draggingDestinationWindow: NSWindow?
        init(_ pasteboard: NSPasteboard, at location: NSPoint = .zero, in window: NSWindow? = nil) {
            draggingPasteboard = pasteboard
            draggingLocation = location
            draggingDestinationWindow = window
        }
        var draggingSourceOperationMask: NSDragOperation { .every }
        var draggedImageLocation: NSPoint { .zero }
        var draggedImage: NSImage? { nil }
        var draggingSource: Any? { nil }
        var draggingSequenceNumber: Int { 1 }
        func slideDraggedImage(to screenPoint: NSPoint) {}
        var draggingFormation: NSDraggingFormation = .default
        var animatesToDestination = false
        var numberOfValidItemsForDrop = 1
        func enumerateDraggingItems(options enumOpts: NSDraggingItemEnumerationOptions = [], for view: NSView?,
                                    classes classArray: [AnyClass], searchOptions: [NSPasteboard.ReadingOptionKey: Any] = [:],
                                    using block: (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void) {}
        var springLoadingHighlight: NSSpringLoadingHighlight { .none }
        func resetSpringLoading() {}
    }

    private func pasteboard(files: [URL] = [], text: String? = nil) -> NSPasteboard {
        let pb = NSPasteboard(name: NSPasteboard.Name("file-drop-\(UUID().uuidString)"))
        pb.clearContents()
        if !files.isEmpty { pb.writeObjects(files.map { $0 as NSURL }) }
        if let text { pb.setString(text, forType: .string) }
        return pb
    }

    private let photo = URL(fileURLWithPath: "/tmp/photo.png")
    private let folder = URL(fileURLWithPath: "/tmp/Folder", isDirectory: true)

    /// A text view whose drop decision is `action`, recording what reaches the embedder.
    private func textView(_ text: String, action: EditorFileDropAction,
                          markdown: String? = "![[photo]]") -> (NativeTextView, Recorder) {
        let tv = NativeTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        tv.string = text
        let recorder = Recorder()
        tv.fileDrop = EditorFileDrop(
            action: { files, _ in recorder.asked.append(files); return action },
            markdown: { files in recorder.inserted.append(files); return markdown },
            handOff: { files in recorder.handedOff.append(files) }
        )
        return (tv, recorder)
    }

    private final class Recorder {
        var asked: [[URL]] = []
        var inserted: [[URL]] = []
        var handedOff: [[URL]] = []
    }

    @Test("file URLs become a drag type only with a handler")
    func registersFileURLsOnlyWithAHandler() {
        let base = NativeTextView(frame: .zero).acceptableDragTypes
        let (tv, _) = textView("", action: .insert)
        #expect(tv.acceptableDragTypes.contains(.fileURL))
        tv.fileDrop = nil
        #expect(tv.acceptableDragTypes == base, "without a handler the text view keeps AppKit's own types")
    }

    @Test("an inserting drop puts the embedder's markdown on lines of its own")
    func insertingDropReadsTheFiles() {
        let (tv, recorder) = textView("Before after", action: .insert)
        #expect(tv.insertDroppedFiles([photo], at: 7))   // "Before |after"
        #expect(tv.string == "Before \n![[photo]]\nafter")
        #expect(recorder.inserted == [[photo]])
    }

    @Test("links and embeds go in as their display form, the id beside the name")
    func linksInsertInDisplayForm() {
        let doc = UUID().uuidString, pic = UUID().uuidString
        let (tv, _) = textView("", action: .insert, markdown: "[[Wohngebäude Kündigung|\(doc)]]\n![[photo|\(pic)]]")
        #expect(tv.insertDroppedFiles([photo], at: 0))
        #expect(tv.string == "[[Wohngebäude Kündigung]]\n![[photo]]")
        let ns = tv.string as NSString
        #expect(tv.textStorage?.attribute(.wikiLinkID, at: ns.range(of: "Wohngebäude").location, effectiveRange: nil) as? String == doc)
        #expect(tv.textStorage?.attribute(.wikiLinkID, at: ns.range(of: "photo").location, effectiveRange: nil) as? String == pic)
    }

    @Test("nothing to insert fails the drop and leaves the text")
    func emptyMarkdownInsertsNothing() {
        let (tv, _) = textView("Text", action: .insert, markdown: nil)
        #expect(tv.insertDroppedFiles([photo], at: 0) == false)
        #expect(tv.string == "Text")
    }

    @Test("reading a pasteboard outside a drop never reaches the embedder")
    func pasteIsUntouched() {
        let (tv, recorder) = textView("Text", action: .insert)
        _ = tv.readSelection(from: pasteboard(files: [photo], text: "x"), type: .string)
        _ = tv.readSelection(from: pasteboard(files: [photo]), type: .fileURL)
        #expect(recorder.inserted.isEmpty)
    }

    @Test("a hand-off is accepted without an insertion point and reaches the embedder on drop")
    func handOffGoesToTheEmbedder() {
        let (tv, recorder) = textView("Text", action: .handOff)
        let drag = FakeDrag(pasteboard(files: [folder]))
        #expect(tv.draggingUpdated(drag) == .copy)
        #expect(tv.performDragOperation(drag))
        #expect(recorder.handedOff == [[folder]])
        #expect(recorder.inserted.isEmpty)
        #expect(tv.string == "Text")
    }

    @Test("a refused drop is not accepted")
    func refusedDropIsDeclined() {
        let (tv, recorder) = textView("Text", action: .refuse)
        let drag = FakeDrag(pasteboard(files: [photo]))
        #expect(tv.draggingUpdated(drag) == [])
        #expect(tv.performDragOperation(drag) == false)
        #expect(recorder.handedOff.isEmpty && recorder.inserted.isEmpty)
    }

    @Test("an inserting drag asks AppKit for the insertion point")
    func insertingDragOffersCopy() {
        let (tv, recorder) = textView("Text", action: .insert)
        let drag = FakeDrag(pasteboard(files: [photo]))
        #expect(tv.dragOperation(for: drag, type: .fileURL) == .copy)
        #expect(recorder.asked.last == [photo])
    }

    @Test("a drag of text never reaches the embedder")
    func textDragIsLeftToAppKit() {
        let (tv, recorder) = textView("Text", action: .insert)
        let drag = FakeDrag(pasteboard(text: "dragged words"))
        #expect(tv.fileDropAction(for: drag) == nil)
        _ = tv.draggingUpdated(drag)
        #expect(recorder.asked.isEmpty)
    }

    @Test("the whole document takes file drops: the container passes them to the text")
    func containerForwardsToTheText() {
        let (tv, recorder) = textView("Text", action: .handOff)
        let container = NativeTextViewContainer(frame: NSRect(x: 0, y: 0, width: 800, height: 300))
        container.addSubview(tv)
        container.textView = tv
        #expect(container.registeredDraggedTypes.contains(.fileURL))

        let drag = FakeDrag(pasteboard(files: [folder]))
        #expect(container.draggingUpdated(drag) == .copy)
        #expect(container.performDragOperation(drag))
        #expect(recorder.handedOff == [[folder]])

        tv.fileDrop = nil
        #expect(!container.registeredDraggedTypes.contains(.fileURL), "without a handler the margins take nothing")
    }

    // MARK: - A block under the pointer

    /// "Intro line", a 300pt line standing in for an image (`.latexIsBlock`), "After line",
    /// laid out in a window.
    private func blockStage() -> (NativeTextView, NSWindow, line: CGRect) {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: -30000, y: -30000, width: 500, height: 600),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let (tv, _) = textView("", action: .insert, markdown: "![[new]]")
        tv.frame = NSRect(x: 0, y: 0, width: 500, height: 600)
        tv.textContainer?.lineFragmentPadding = 0
        window.contentView = tv
        let font = NSFont.systemFont(ofSize: 16)
        tv.baseFont = font
        let tall = NSMutableParagraphStyle()
        tall.minimumLineHeight = 300
        tall.maximumLineHeight = 300
        let text = NSMutableAttributedString(string: "Intro line\n", attributes: [.font: font])
        text.append(NSAttributedString(string: "IMG\n", attributes: [.font: font, .paragraphStyle: tall, .latexIsBlock: true,
                                                                   .renderedBlockRange: NSValue(range: NSRange(location: 11, length: 4))]))
        text.append(NSAttributedString(string: "After line", attributes: [.font: font]))
        tv.textStorage?.setAttributedString(text)
        if let tlm = tv.textLayoutManager { tlm.ensureLayout(for: tlm.documentRange) }
        // On screen: TextKit lays the viewport out only for a visible window, and
        // `characterIndexForInsertion` answers from it.
        window.orderFrontRegardless()
        for _ in 0..<10 { RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.01)) }
        Self.windows.append(window)
        return (tv, window, CGRect(x: 0, y: 18, width: 500, height: 300))
    }

    private static var windows: [NSWindow] = []

    @Test("over a block the drop goes above or below it, by the half the pointer is in")
    func blockSnapsToItsEdges() {
        let (tv, _, line) = blockStage()
        let above = tv.fileDropTarget(at: NSPoint(x: 30, y: line.minY + 40))
        let below = tv.fileDropTarget(at: NSPoint(x: 30, y: line.maxY - 40))
        #expect(above.index == 11)   // before "IMG"
        #expect(below.index == 14)   // after "IMG", before its newline
        let caret = ceil(tv.baseFont.ascender - tv.baseFont.descender + tv.baseFont.leading)
        #expect((above.edge?.height ?? 0) <= caret + 0.5, "a normal insertion point, not the block's height")
        #expect(abs((above.edge?.minY ?? -1) - line.minY) < 1)
        #expect(abs((below.edge?.maxY ?? -1) - line.maxY) < 1)
        #expect(tv.fileDropTarget(at: NSPoint(x: 30, y: 8)).edge == nil, "plain text keeps AppKit's insertion point")
    }

    @Test("a drop on a block keeps the block's source whole")
    func dropOnABlockDoesNotCutIt() {
        let (tv, _, line) = blockStage()
        // Inside the block's source ("I|MG"): taken as is, the drop would cut it in two.
        let point = NSPoint(x: 6, y: line.minY + 40)
        #expect((12...13).contains(tv.characterIndexForInsertion(at: point)), "the raw index lies inside the source")
        let target = tv.fileDropTarget(at: point)
        #expect(tv.insertDroppedFiles([photo], at: target.index))
        #expect(tv.string == "Intro line\n![[new]]\nIMG\nAfter line")
    }

    @Test("while dragging, the insertion point follows the pointer with the text caret on the empty last line")
    func dragIndicatorFollowsThePointerNotTheSelection() {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: -30000, y: -30000, width: 500, height: 600),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let (tv, _) = textView("", action: .insert)
        tv.frame = NSRect(x: 0, y: 0, width: 500, height: 600)
        window.contentView = tv
        tv.textStorage?.setAttributedString(NSAttributedString(string: "One\nTwo\nThree\nFour\n",
                                                               attributes: [.font: NSFont.systemFont(ofSize: 16)]))
        if let tlm = tv.textLayoutManager { tlm.ensureLayout(for: tlm.documentRange) }
        window.orderFrontRegardless()
        window.makeFirstResponder(tv)
        tv.setSelectedRange(NSRange(location: (tv.string as NSString).length, length: 0))
        let spin = { for _ in 0..<10 { RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.01)) } }
        spin()
        let drag = { (y: CGFloat) in
            FakeDrag(self.pasteboard(files: [self.photo]), at: tv.convert(NSPoint(x: 40, y: y), to: nil), in: window)
        }
        _ = tv.draggingEntered(drag(120))   // below the text: the drop point is the last line
        // As in the app: the caret's frame observer sits on the indicator the drop point is drawn with.
        tv.isTrackingDrag = false
        tv.fixPhantomTrailingCaret()
        tv.isTrackingDrag = true
        #expect(tv.observedCaretIndicator != nil)
        var tops: [CGFloat] = []
        for y: CGFloat in [8, 28, 48, 68] {
            _ = tv.draggingUpdated(drag(y))
            spin()
            let shown = tv.subviews.compactMap { $0 as? NSTextInsertionIndicator }.first { !$0.isHidden }
            tops.append(shown?.frame.minY ?? -1)
        }
        #expect(Set(tops).count == 4 && tops == tops.sorted(),
                "one insertion point per line under the pointer, not the selection's last line: \(tops)")
        tv.draggingExited(nil)
        #expect(!tv.isTrackingDrag)
        window.orderOut(nil)
    }

    @Test("while dragging over a block the insertion point is a normal one at its edge")
    func dragIndicatorIsShortenedOverABlock() {
        let (tv, window, line) = blockStage()
        window.makeFirstResponder(tv)
        let point = tv.convert(NSPoint(x: 30, y: line.midY + 20), to: nil)
        _ = tv.draggingUpdated(FakeDrag(pasteboard(files: [photo]), at: point, in: window))
        let caret = ceil(tv.baseFont.ascender - tv.baseFont.descender + tv.baseFont.leading)
        let indicators = tv.subviews.compactMap { $0 as? NSTextInsertionIndicator }.filter { !$0.isHidden }
        #expect(!indicators.isEmpty)
        #expect(indicators.allSatisfy { $0.frame.height <= caret + 0.5 })
        tv.draggingExited(nil)
        window.orderOut(nil)
    }

    // MARK: - Blocks over several lines

    /// "Intro line", a `$$` block over three lines (the formula line drawn 300 pt tall,
    /// the marker lines 1 pt, as collapsed), "After line"; laid out in a window.
    private func formulaStage() -> (NativeTextView, NSWindow, block: NSRange) {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: -30000, y: -30000, width: 500, height: 600),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let (tv, _) = textView("", action: .insert, markdown: "![[new]]")
        tv.frame = NSRect(x: 0, y: 0, width: 500, height: 600)
        tv.textContainer?.lineFragmentPadding = 0
        window.contentView = tv
        let font = NSFont.systemFont(ofSize: 16)
        tv.baseFont = font
        let tall = NSMutableParagraphStyle()
        tall.minimumLineHeight = 300
        tall.maximumLineHeight = 300
        let collapsed = NSMutableParagraphStyle()
        collapsed.maximumLineHeight = 1
        let text = NSMutableAttributedString(string: "Intro line\n", attributes: [.font: font])
        let blockStart = text.length
        text.append(NSAttributedString(string: "$$\n", attributes: [.font: font, .paragraphStyle: collapsed]))
        text.append(NSAttributedString(string: "x^2\n", attributes: [.font: font, .paragraphStyle: tall]))
        text.append(NSAttributedString(string: "$$\n", attributes: [.font: font, .paragraphStyle: collapsed]))
        let block = NSRange(location: blockStart, length: text.length - blockStart)
        text.addAttribute(.latexIsBlock, value: true, range: NSRange(location: blockStart + 3, length: 1))
        text.addAttribute(.renderedBlockRange, value: NSValue(range: block), range: block)
        text.append(NSAttributedString(string: "After line", attributes: [.font: font]))
        tv.textStorage?.setAttributedString(text)
        if let tlm = tv.textLayoutManager { tlm.ensureLayout(for: tlm.documentRange) }
        window.orderFrontRegardless()
        for _ in 0..<10 { RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.01)) }
        Self.windows.append(window)
        return (tv, window, block)
    }

    @Test("a drop on a block over several lines goes above or below all of it, never between its lines")
    func multiLineBlockSnapsToItsOuterEdges() {
        let (tv, window, block) = formulaStage()
        let above = tv.fileDropTarget(at: NSPoint(x: 30, y: 80))
        let below = tv.fileDropTarget(at: NSPoint(x: 30, y: 290))
        #expect(above.index == block.location)
        #expect(below.index == NSMaxRange(block) - 1)
        #expect(tv.insertDroppedFiles([photo], at: below.index))
        #expect(tv.string == "Intro line\n$$\nx^2\n$$\n![[new]]\nAfter line", "the formula's source stays whole")
        window.orderOut(nil)
    }

    @Test("a drawn table carries its whole source, all rows, as the block a drop must not cut")
    func tableCarriesItsWholeSource() {
        _ = NSApplication.shared
        let text = "Intro\n\n| A | B |\n|---|---|\n| 1 | 2 |\n\nNext"
        let coordinator = NativeTextViewCoordinator(
            text: .constant(text), fontName: "SF Pro", fontSize: 16,
            isWikiLinkActive: .constant(false), onLinkClick: nil, onInlineSelectionChange: nil
        )
        let tv = NativeTextView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        tv.isEditable = true
        tv.delegate = coordinator
        coordinator.textView = tv
        coordinator.rebuildTextStorageAndStyle(tv, from: text)
        let table = (text as NSString).range(of: "| A | B |\n|---|---|\n| 1 | 2 |\n")
        for row in ["| A |", "|---|", "| 1 |"] {
            let at = (text as NSString).range(of: row).location
            let block = (tv.textStorage?.attribute(.renderedBlockRange, at: at, effectiveRange: nil) as? NSValue)?.rangeValue
            #expect(block == table, "row \(row)")
        }
        #expect(tv.textStorage?.attribute(.renderedBlockRange, at: 0, effectiveRange: nil) == nil)
    }

    // MARK: - Links keep their ids

    @Test("in raw source mode an embed goes in as stored, id and all")
    func rawSourceModeKeepsTheID() {
        let id = UUID().uuidString
        let (tv, _) = textView("", action: .insert, markdown: "![[photo|\(id)]]")
        tv.configuration.rawSourceMode = true
        #expect(tv.insertDroppedFiles([photo], at: 0))
        #expect(tv.string == "![[photo|\(id)]]")
    }

    @Test("a copy carries its links as stored, and our paste puts them back with their ids")
    func copiedLinksKeepTheirIDs() {
        let id = UUID().uuidString
        let source = NativeTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        source.string = "See [[Plan]] here"
        let ns = source.string as NSString
        source.textStorage?.addAttribute(.wikiLinkID, value: id, range: ns.range(of: "Plan"))
        let all = NSRange(location: 0, length: ns.length)
        #expect(source.storageMarkdown(in: all) == "See [[Plan|\(id)]] here")

        let pb = pasteboard()
        MarkdownPasteboardWriter.write(markdown: source.string, storageMarkdown: source.storageMarkdown(in: all), to: pb)
        #expect(pb.string(forType: MarkdownPasteboardWriter.markdownType) == "See [[Plan|\(id)]] here")
        #expect(pb.string(forType: .string) == "See [[Plan]] here", "other apps get the text as shown")

        let target = NativeTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        target.string = "Intro "
        let inserted = target.insertStorageMarkdown(pb.string(forType: MarkdownPasteboardWriter.markdownType) ?? "",
                                                    replacing: NSRange(location: 6, length: 0), actionName: "Paste")
        #expect(inserted == NSRange(location: 6, length: 17))
        #expect(target.string == "Intro See [[Plan]] here")
        let plan = (target.string as NSString).range(of: "Plan")
        #expect(target.textStorage?.attribute(.wikiLinkID, at: plan.location, effectiveRange: nil) as? String == id)
    }

    @Test("a block's edges follow it when the text above changes and nothing restyles the block")
    func blockEdgesFollowEditsAbove() {
        let (tv, window, block) = formulaStage()
        // Typed above: the stored value still says where the block was.
        tv.textStorage?.replaceCharacters(in: NSRange(location: 0, length: 0), with: "New ")
        if let tlm = tv.textLayoutManager { tlm.ensureLayout(for: tlm.documentRange) }
        let above = tv.fileDropTarget(at: NSPoint(x: 30, y: 80))
        let below = tv.fileDropTarget(at: NSPoint(x: 30, y: 290))
        #expect(above.index == block.location + 4)
        #expect(below.index == NSMaxRange(block) + 4 - 1)
        window.orderOut(nil)
    }

    @Test("in front of the header band, file drags go to the text and clicks go through")
    func headerBandPassesFileDragsToTheText() {
        let (tv, recorder) = textView("Text", action: .handOff)
        let container = NativeTextViewContainer(frame: NSRect(x: 0, y: 0, width: 800, height: 300))
        container.addSubview(tv)
        container.textView = tv
        let clip = NSView()
        clip.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(clip)
        let top = clip.topAnchor.constraint(equalTo: container.topAnchor)
        let left = clip.leadingAnchor.constraint(equalTo: container.leadingAnchor)
        let right = clip.trailingAnchor.constraint(equalTo: container.trailingAnchor)
        NSLayoutConstraint.activate([top, left, right, clip.heightAnchor.constraint(equalToConstant: 80)])
        container.pinHeader(clip, top: top, left: left, right: right)

        let index = container.subviews.firstIndex(of: clip) ?? -1
        let front = container.subviews.dropFirst(index + 1).first { $0.registeredDraggedTypes.contains(.fileURL) }
        #expect(front != nil, "a drop view in front of the header")
        #expect(front?.hitTest(NSPoint(x: 10, y: 10)) == nil)
        let drag = FakeDrag(pasteboard(files: [folder]))
        #expect(front?.draggingUpdated(drag) == .copy)
        #expect(front?.performDragOperation(drag) == true)
        #expect(recorder.handedOff == [[folder]])

        tv.fileDrop = nil
        #expect(front?.registeredDraggedTypes.isEmpty == true)
        container.unpinHeader()
        #expect(front?.superview == nil)
    }

    // MARK: - Files still to be written

    @Test("an image dragged in as data, a browser's, is written to a file named after its address and dropped like one")
    func imageDataBecomesAFile() {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: -30000, y: -30000, width: 400, height: 200),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let (tv, recorder) = textView("Hello", action: .insert)
        window.contentView = tv
        window.orderFrontRegardless()
        for _ in 0..<10 { RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.01)) }
        let image = NSImage(size: NSSize(width: 4, height: 4))
        image.lockFocus(); NSColor.red.setFill(); NSRect(x: 0, y: 0, width: 4, height: 4).fill(); image.unlockFocus()
        let pb = NSPasteboard(name: NSPasteboard.Name("file-drop-\(UUID().uuidString)"))
        pb.declareTypes([.URL, .tiff], owner: nil)
        pb.setString("https://example.com/pics/cat.jpg", forType: .URL)
        pb.setData(image.tiffRepresentation, forType: .tiff)
        let drag = FakeDrag(pb, at: tv.convert(NSPoint(x: 300, y: 8), to: nil), in: window)

        #expect(tv.draggingEntered(drag) == .copy)
        #expect(tv.subviews.contains { ($0 as? NSTextInsertionIndicator)?.isHidden == false }, "the insertion point shows")
        #expect(recorder.asked.last?.map(\.lastPathComponent) == ["cat.png"])
        #expect(tv.performDragOperation(drag))
        let file = recorder.inserted.first?.first
        #expect(file?.lastPathComponent == "cat.png")
        #expect(file.flatMap { try? Data(contentsOf: $0) }.map { NSImage(data: $0) != nil } == true)
        #expect(tv.string == "Hello\n![[photo]]")
        window.orderOut(nil)
    }
}
