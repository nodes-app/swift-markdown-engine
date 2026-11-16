//
//  NativeTextView+FileDrop.swift
//  MarkdownEngine
//
//  Created by Luca Chen on 06.11.26.
//
//  Files dragged onto the text (`EditorFileDrop`). While dragging, AppKit's own
//  machinery draws the insertion point and scrolls at the edges, and the caret
//  workarounds stay out (`isTrackingDrag`, any drag); on drop the engine inserts at
//  that point itself. A file still to be written (a promise from Photos or a browser,
//  or bare image data) is written to a temporary folder on drop and goes the same way. Over a block drawn in place of its source (an
//  image, a formula, a table) the drop goes above or below it instead.
//

import AppKit
import UniformTypeIdentifiers

extension NativeTextView {

    /// What a file drop can arrive as: files, promises of files, bare image data.
    static let fileDropTypes: [NSPasteboard.PasteboardType] = [.fileURL, .png, .tiff]
        + NSFilePromiseReceiver.readableDraggedTypes.map { NSPasteboard.PasteboardType($0) }

    override var acceptableDragTypes: [NSPasteboard.PasteboardType] {
        let types = super.acceptableDragTypes
        guard fileDrop != nil else { return types }
        return types + Self.fileDropTypes.filter { !types.contains($0) }
    }

    /// The files a drag carries, read once per drag; nil for a drag without any (text
    /// keeps AppKit's handling).
    func draggedFiles(for sender: NSDraggingInfo) -> DraggedFiles? {
        guard fileDrop != nil else { return nil }
        let pasteboard = sender.draggingPasteboard
        let key = "\(sender.draggingSequenceNumber) \(pasteboard.name.rawValue) \(pasteboard.changeCount)"
        if let cache = draggedFilesCache, cache.key == key { return cache.files }
        let files = DraggedFiles(pasteboard)
        draggedFilesCache = (key, files)
        return files
    }

    /// The drop this drag would make, with its files; nil when it is not a file drop.
    func fileDropAction(for sender: NSDraggingInfo) -> (action: EditorFileDropAction, files: DraggedFiles)? {
        guard let fileDrop, isEditable, let files = draggedFiles(for: sender) else { return nil }
        return (fileDrop.action(files.urls, NSEvent.modifierFlags), files)
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        isTrackingDrag = true
        guard let drop = fileDropAction(for: sender) else { return super.draggingEntered(sender) }
        guard drop.action == .insert else { return operation(for: drop.action, sender) }
        let result = super.draggingEntered(sender)
        placeDragIndicator(for: sender)
        return result
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        isTrackingDrag = true
        guard let drop = fileDropAction(for: sender) else { return super.draggingUpdated(sender) }
        guard drop.action == .insert else { return operation(for: drop.action, sender) }
        let result = super.draggingUpdated(sender)
        placeDragIndicator(for: sender)
        return result
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        stopTrackingDrag()
        super.draggingExited(sender)
    }

    override func draggingEnded(_ sender: NSDraggingInfo) {
        stopTrackingDrag()
        super.draggingEnded(sender)
    }

    /// The text caret is back: its workarounds place it again once AppKit has restored it.
    private func stopTrackingDrag() {
        guard isTrackingDrag else { return }
        isTrackingDrag = false
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.isTrackingDrag else { return }
            self.applyBlockImageCaretPolicy()
            self.fixPhantomTrailingCaret()
            self.placeCaretPastMargin()
        }
    }

    /// A drop that does not insert shows no insertion point: one left from before
    /// ⌥ went down is cleared.
    private func operation(for action: EditorFileDropAction, _ sender: NSDraggingInfo) -> NSDragOperation {
        super.draggingExited(sender)
        return action == .handOff ? .copy : []
    }

    /// AppKit asks this to decide the operation, and draws the insertion point when
    /// the answer is not none. Its own answer runs first: skipping it for a type such
    /// as `NSFilenamesPboardType` left no insertion point at all (measured).
    override func dragOperation(for dragInfo: NSDraggingInfo, type: NSPasteboard.PasteboardType) -> NSDragOperation {
        let operation = super.dragOperation(for: dragInfo, type: type)
        return fileDropAction(for: dragInfo)?.action == .insert ? .copy : operation
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        stopTrackingDrag()
        guard let drop = fileDropAction(for: sender) else { return super.performDragOperation(sender) }
        super.draggingExited(sender)
        switch drop.action {
        case .insert:
            let target = fileDropTarget(at: convert(sender.draggingLocation, from: nil))
            guard drop.files.isPending else { return insertDroppedFiles(drop.files.urls, at: target.index) }
            let document = (delegate as? NativeTextViewCoordinator)?.documentId
            let textAtDrop = string
            drop.files.write(from: sender.draggingPasteboard) { [weak self] urls in
                // Still the document it was dropped on. Edited while the files were being
                // written: the drop point has moved, so they go where the caret is.
                guard let self, (self.delegate as? NativeTextViewCoordinator)?.documentId == document else { return }
                let index = self.string == textAtDrop ? target.index : self.selectedRange().location
                _ = self.insertDroppedFiles(urls, at: index)
            }
            return true
        case .handOff:
            guard drop.files.isPending else {
                fileDrop?.handOff(drop.files.urls)
                return true
            }
            drop.files.write(from: sender.draggingPasteboard) { [weak self] urls in self?.fileDrop?.handOff(urls) }
            return true
        case .refuse:
            return false
        }
    }

    /// Puts what the embedder makes of `files` at `index`, on lines of its own.
    func insertDroppedFiles(_ files: [URL], at index: Int) -> Bool {
        guard !files.isEmpty, let markdown = fileDrop?.markdown(files), !markdown.isEmpty else { return false }
        window?.makeFirstResponder(self)
        setSelectedRange(NSRange(location: min(index, (string as NSString).length), length: 0))
        insertBlockEmbed(markdown, actionName: "Drop")
        return true
    }

    // MARK: - Where the drop lands

    /// Where a file drop at `viewPoint` goes: AppKit's insertion index, except inside
    /// a block drawn in place of its source (`.renderedBlockRange`: an image, a formula,
    /// a table, all of its lines), where the drop goes above or below the whole block
    /// by the half the pointer is in; inside, it would cut the block's source in two.
    /// `edge` is then where the insertion point shows, a normal one: AppKit draws it as
    /// tall as the line, and the block's other lines are 1 pt high.
    func fileDropTarget(at viewPoint: NSPoint) -> (index: Int, edge: CGRect?) {
        let index = characterIndexForInsertion(at: viewPoint)
        let ns = string as NSString
        guard ns.length > 0, let ts = textStorage,
              let block = drawnBlock(around: index, in: ts),
              let top = caretRect(at: block.location),
              let bottom = caretRect(at: NSMaxRange(block) - 1) else { return (index, nil) }
        let endsInNewline = ns.character(at: NSMaxRange(block) - 1) == 0x0A
        let below = viewPoint.y >= (top.minY + max(top.maxY, bottom.maxY)) / 2
        let target = below ? NSMaxRange(block) - (endsInNewline ? 1 : 0) : block.location
        guard let edge = caretRect(at: target) else { return (target, nil) }
        let height = ceil(baseFont.ascender - baseFont.descender + baseFont.leading)
        let y = below ? edge.maxY - height : edge.minY
        return (target, CGRect(x: edge.minX, y: y, width: 0, height: height))
    }

    /// The drawn block whose source holds `index`. Read as the attribute's run, which
    /// moves with the text: its value is where the block was when last styled, and an
    /// edit above it restyles only the lines around the edit.
    private func drawnBlock(around index: Int, in ts: NSTextStorage) -> NSRange? {
        let probe = min(index, ts.length - 1)
        var block = NSRange()
        guard ts.attribute(.renderedBlockRange, at: probe, longestEffectiveRange: &block,
                           in: NSRange(location: 0, length: ts.length)) != nil,
              block.length > 0, isDrawnBlock(block, in: ts) else { return nil }
        return block
    }

    /// Still drawn: a restyle that took the block apart may leave the range on a line it skipped.
    private func isDrawnBlock(_ range: NSRange, in ts: NSTextStorage) -> Bool {
        var block = false
        ts.enumerateAttributes(in: range, options: []) { attributes, _, stop in
            if attributes[.latexIsBlock] as? Bool == true || attributes[.scrollableBlockNaturalWidth] != nil {
                block = true
                stop.pointee = true
            }
        }
        return block
    }

    /// TextKit's insertion point at `offset`, in view coordinates.
    private func caretRect(at offset: Int) -> CGRect? {
        guard let tlm = textLayoutManager, let tcs = tlm.textContentManager,
              let location = tcs.location(tcs.documentRange.location, offsetBy: offset) else { return nil }
        var frame: CGRect?
        tlm.enumerateTextSegments(in: NSTextRange(location: location), type: .selection,
                                  options: [.rangeNotRequired]) { _, rect, _, _ in
            frame = rect
            return false
        }
        let origin = textContainerOrigin
        return frame?.offsetBy(dx: origin.x, dy: origin.y)
    }

    /// Over a block, the insertion point AppKit just placed moves to the block's edge.
    private func placeDragIndicator(for sender: NSDraggingInfo) {
        guard let edge = fileDropTarget(at: convert(sender.draggingLocation, from: nil)).edge else { return }
        for case let indicator as NSTextInsertionIndicator in subviews where !indicator.isHidden {
            isApplyingCaretShift = true
            indicator.frame = CGRect(x: edge.minX, y: edge.minY, width: indicator.frame.width, height: edge.height)
            isApplyingCaretShift = false
        }
    }
}

/// The files a drag carries. On disk already (`urls`), or still to be written: a
/// promise (Photos, Mail, a browser) or bare image data (a browser) becomes a file
/// only on drop. Until then `urls` are stand-ins, not on disk, named and typed like
/// the files to come, so the embedder decides the drop the same way.
struct DraggedFiles {
    var urls: [URL]
    var promises: [NSFilePromiseReceiver] = []
    var isImageData = false

    var isPending: Bool { !promises.isEmpty || isImageData }

    init?(_ pasteboard: NSPasteboard) {
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self],
                                             options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty {
            self.urls = urls
            return
        }
        let standIns = FileManager.default.temporaryDirectory.appendingPathComponent("MarkdownEngineDrop", isDirectory: true)
        if let promises = pasteboard.readObjects(forClasses: [NSFilePromiseReceiver.self], options: nil) as? [NSFilePromiseReceiver],
           !promises.isEmpty {
            self.promises = promises
            urls = promises.flatMap(\.fileTypes).enumerated().map { index, type in
                let ext = UTType(type)?.preferredFilenameExtension ?? "data"
                return standIns.appendingPathComponent("File \(index + 1).\(ext)")
            }
            return
        }
        // Rich text with an image in it (a selection out of a document or a page) is text.
        guard pasteboard.availableType(from: [.png, .tiff]) != nil,
              pasteboard.availableType(from: [.rtf, .rtfd, MarkdownPasteboardWriter.markdownType]) == nil else { return nil }
        isImageData = true
        urls = [standIns.appendingPathComponent(Self.imageName(on: pasteboard) + ".png")]
    }

    /// A browser's image is named after its address; anything else is "Image".
    private static func imageName(on pasteboard: NSPasteboard) -> String {
        let address = (pasteboard.readObjects(forClasses: [NSURL.self], options: nil) as? [URL])?.first
        let base = address?.deletingPathExtension().lastPathComponent
            .replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-") ?? ""
        return base.isEmpty || base == "/" ? "Image" : base
    }

    /// Writes the files into a folder of their own, then calls `finish` on the main
    /// queue with those that arrived (none: not called).
    func write(from pasteboard: NSPasteboard, then finish: @escaping ([URL]) -> Void) {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("MarkdownEngineDrop-\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        } catch { return }
        if isImageData {
            guard let name = urls.first?.lastPathComponent,
                  let data = PasteboardImageReader.imageData(from: pasteboard) else { return }
            let url = folder.appendingPathComponent(name)
            guard (try? data.write(to: url)) != nil else { return }
            finish([url])
            return
        }
        // Receiving can take a while (Photos exports the original): off the main queue.
        let queue = OperationQueue()
        let expected = promises.reduce(0) { $0 + max(1, $1.fileTypes.count) }
        var received: [URL] = []
        var answered = 0
        for promise in promises {
            promise.receivePromisedFiles(atDestination: folder, options: [:], operationQueue: queue) { url, error in
                DispatchQueue.main.async {
                    if error == nil { received.append(url) }
                    answered += 1
                    if answered == expected, !received.isEmpty { finish(received) }
                }
            }
        }
    }
}
