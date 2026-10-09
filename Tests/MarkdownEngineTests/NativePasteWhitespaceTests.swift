import AppKit
import Testing
@testable import MarkdownEngine

@MainActor
@Suite(.serialized)
struct NativePasteWhitespaceTests {
    private func withPasteboard(_ body: (NSPasteboard) throws -> Void) rethrows {
        let board = NSPasteboard.general
        let saved = (board.pasteboardItems ?? []).map { item in
            item.types.compactMap { type in item.data(forType: type).map { (type, $0) } }
        }
        defer {
            board.clearContents()
            let items = saved.map { entries in
                let item = NSPasteboardItem()
                for (type, data) in entries { item.setData(data, forType: type) }
                return item
            }
            if !items.isEmpty { board.writeObjects(items) }
        }
        board.clearContents()
        try body(board)
    }

    private func editor(_ source: String, selection: NSRange? = nil) -> NativeTextView {
        _ = NSApplication.shared
        let view = NativeTextView(frame: NSRect(x: 0, y: 0, width: 500, height: 300))
        view.isEditable = true
        view.allowsUndo = true
        view.string = source
        view.setSelectedRange(selection ?? NSRange(location: (source as NSString).length, length: 0))
        return view
    }

    @Test func preservesParagraphSeparatorsCodeIndentAndHardBreaks() {
        withPasteboard { board in
            let source = "Existing paragraph."
            let paste = "\n\n\n    indented code\ntext  \nnext\n\n\n"
            board.setString(paste, forType: .string)
            let view = editor(source)
            view.paste(nil)
            #expect(view.string == source + paste)
            #expect(view.selectedRange().location == ((source + paste) as NSString).length)
        }
    }

    @Test func privateMarkdownWinsOverLossyHTMLWithoutNormalization() {
        withPasteboard { board in
            let paste = "\n\n• literal glyph\n[[Example|record-id]]  \n\n\n"
            board.setString(paste, forType: MarkdownPasteboardWriter.markdownType)
            board.setString("<ul><li>lossy HTML</li></ul>", forType: .html)
            board.setString("lossy plain text", forType: .string)
            let view = editor("Before")
            view.paste(nil)
            #expect(view.string == "Before" + paste)
        }
    }

    @Test func whitespaceOnlyPasteIsAnIntentionalEdit() {
        withPasteboard { board in
            board.setString("\n\n  ", forType: .string)
            let view = editor("Before")
            view.paste(nil)
            #expect(view.string == "Before\n\n  ")
        }
    }

    @Test func plainBulletGlyphNormalizationRetainsSurroundingWhitespace() {
        withPasteboard { board in
            board.setString("\n\n  • item\n\n\n", forType: .string)
            let view = editor("Before")
            view.paste(nil)
            #expect(view.string == "Before\n\n  - item\n\n\n")
        }
    }

    @Test func selectedUTF16ReplacementAndUndoRetainExactSeparators() throws {
        try withPasteboard { board in
            board.setString("\n\nreplacement\n\n", forType: .string)
            let view = editor("A🌙B", selection: NSRange(location: 1, length: 2))
            let window = NSWindow(contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: false)
            window.contentView = view
            window.makeFirstResponder(view)
            defer { window.orderOut(nil) }
            let undo = try #require(view.undoManager)
            undo.groupsByEvent = false
            undo.beginUndoGrouping()
            view.paste(nil)
            undo.endUndoGrouping()
            #expect(view.string == "A\n\nreplacement\n\nB")
            undo.undo()
            #expect(view.string == "A🌙B")
            undo.redo()
            #expect(view.string == "A\n\nreplacement\n\nB")
        }
    }
}
