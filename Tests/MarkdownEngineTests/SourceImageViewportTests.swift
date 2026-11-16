//
//  SourceImageViewportTests.swift
//  MarkdownEngineTests
//
//  With its source showing, a block image is drawn below the source line, in the
//  paragraph spacing. TextKit keeps a fragment in the viewport by its frame, which
//  covered only the line: once the line scrolled out, the image vanished while
//  most of it was still on screen.
//

import AppKit
import Testing
@testable import MarkdownEngine

@MainActor
@Suite("Source image viewport", .serialized)
struct SourceImageViewportTests {

    private static let imageHeight: CGFloat = 560
    private static let gap: CGFloat = 8

    private struct Stage {
        let window: NSWindow
        let scrollView: NSScrollView
        let textView: NativeTextView
        let delegate: MarkdownLayoutManagerDelegate
        /// Document range of the image's source line and of the paragraph after it.
        let sourceRange: NSRange
        let nextRange: NSRange
    }

    /// AppKit can still be working on a window after a test returns; keep them alive.
    private static var windows: [NSWindow] = []

    private static func stage(linesAfter: Bool, spacing: CGFloat? = nil) throws -> Stage {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: -30000, y: -30000, width: 500, height: 300),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        windows.append(window)
        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 500, height: 300))
        let textView = NativeTextView(frame: NSRect(x: 0, y: 0, width: 500, height: 300))
        textView.textContainer?.lineFragmentPadding = 0
        textView.isVerticallyResizable = true
        let tlm = try #require(textView.textLayoutManager)
        let delegate = MarkdownLayoutManagerDelegate()
        tlm.delegate = delegate
        scrollView.documentView = textView
        window.contentView = scrollView
        window.orderFrontRegardless()

        let source = "![photo](photo.png)"
        let lines = (1...40).map { "Line \($0)" }.joined(separator: "\n")
        let text = "Intro\n" + source + (linesAfter ? "\n" + lines : "")
        let ns = text as NSString
        let sourceRange = ns.range(of: source)
        let font = NSFont.systemFont(ofSize: 16)
        let lineHeight = ceil(font.ascender - font.descender + font.leading)
        let storage = NSMutableAttributedString(string: text, attributes: [.font: font])
        // What the styler's `.visibleSource` mode emits.
        let para = NSMutableParagraphStyle()
        para.paragraphSpacing = spacing ?? imageHeight + gap
        storage.addAttribute(.paragraphStyle, value: para, range: ns.paragraphRange(for: sourceRange))
        let image = NSImage(size: NSSize(width: 300, height: imageHeight))
        storage.addAttributes([
            .latexImage: image,
            .latexBounds: NSValue(rect: CGRect(x: 0, y: 0, width: 300, height: imageHeight)),
            .latexIsBlock: true,
            .latexBlockOffsetY: lineHeight + gap
        ], range: sourceRange)
        textView.textStorage?.setAttributedString(storage)
        tlm.ensureLayout(for: tlm.documentRange)
        textView.frame.size.height = tlm.usageBoundsForTextContainer.height + 800   // room to scroll past the end, like the editor's overscroll

        let nextStart = min(NSMaxRange(ns.paragraphRange(for: sourceRange)), ns.length)
        return Stage(window: window, scrollView: scrollView, textView: textView, delegate: delegate,
                     sourceRange: sourceRange,
                     nextRange: ns.paragraphRange(for: NSRange(location: nextStart, length: 0)))
    }

    private static func fragment(at offset: Int, in tv: NativeTextView) throws -> NSTextLayoutFragment {
        let tlm = try #require(tv.textLayoutManager)
        let tcs = try #require(tlm.textContentManager)
        let location = try #require(tcs.location(tcs.documentRange.location, offsetBy: offset))
        return try #require(tlm.textLayoutFragment(for: location))
    }

    /// Bottom of the source line itself, whatever the fragment reports as its frame.
    private static func sourceLineMaxY(_ fragment: NSTextLayoutFragment) -> CGFloat {
        fragment.layoutFragmentFrame.minY + (fragment.textLineFragments.last?.typographicBounds.maxY ?? 0)
    }

    @Test("the image stays drawn while its source line is above the viewport", arguments: [false, true])
    func imageFragmentStaysInTheViewport(linesAfter: Bool) throws {
        let stage = try Self.stage(linesAfter: linesAfter)
        let tv = stage.textView
        let tlm = try #require(tv.textLayoutManager)
        let tcs = try #require(tlm.textContentManager)
        let imageFragment = try Self.fragment(at: stage.sourceRange.location, in: tv)
        let lineBottom = Self.sourceLineMaxY(imageFragment)

        // The line well above the visible top (past any overdraw), the image still filling the view.
        let top = lineBottom + Self.gap + 250
        stage.scrollView.contentView.scroll(to: NSPoint(x: 0, y: top))
        stage.scrollView.reflectScrolledClipView(stage.scrollView.contentView)
        tlm.textViewportLayoutController.layoutViewport()

        let viewport = try #require(tlm.textViewportLayoutController.viewportRange, "the image is on screen, so the viewport is not empty")
        let start = tcs.offset(from: tcs.documentRange.location, to: viewport.location)
        let end = tcs.offset(from: tcs.documentRange.location, to: viewport.endLocation)
        #expect(start <= stage.sourceRange.location && stage.sourceRange.location < end,
                "the image's fragment is still laid out in the viewport (viewport \(start)…\(end))")
    }

    @Test("in the middle of a note the frame stays TextKit's own")
    func middleOfTheNoteIsUntouched() throws {
        // Spacing far shorter than the image: reaching down here would push the text below,
        // because TextKit places the next fragment at the previous frame's bottom.
        let stage = try Self.stage(linesAfter: true, spacing: 100)
        let imageFragment = try Self.fragment(at: stage.sourceRange.location, in: stage.textView)
        let next = try Self.fragment(at: stage.nextRange.location, in: stage.textView)
        let lineBottom = Self.sourceLineMaxY(imageFragment)
        #expect(abs(next.layoutFragmentFrame.minY - (lineBottom + 100)) < 1,
                "the next paragraph sits one spacing below the line (at \(next.layoutFragmentFrame.minY), line ends \(lineBottom))")
    }

    @Test("at the end of a note the frame covers the image")
    func lastParagraphFrameCoversTheImage() throws {
        let stage = try Self.stage(linesAfter: false)
        let imageFragment = try Self.fragment(at: stage.sourceRange.location, in: stage.textView)
        let lineBottom = Self.sourceLineMaxY(imageFragment)
        #expect(imageFragment.layoutFragmentFrame.maxY >= lineBottom + Self.gap + Self.imageHeight - 1)
    }

    @Test("the paragraph after the image keeps its place")
    func nextParagraphDoesNotMove() throws {
        let stage = try Self.stage(linesAfter: true)
        let imageFragment = try Self.fragment(at: stage.sourceRange.location, in: stage.textView)
        let next = try Self.fragment(at: stage.nextRange.location, in: stage.textView)
        let lineBottom = Self.sourceLineMaxY(imageFragment)
        // Below the image, and not a second image height further down.
        #expect(next.layoutFragmentFrame.minY >= lineBottom + Self.gap + Self.imageHeight - 0.5)
        #expect(next.layoutFragmentFrame.minY <= lineBottom + Self.gap + Self.imageHeight + 40)
    }

    @Test("swapping the whole text under an image at the end never reads past it")
    func replacingTheDocumentUnderTheImage() throws {
        // A document switch: the frame is asked of the OLD fragments while the
        // storage already holds the new, shorter text.
        let stage = try Self.stage(linesAfter: false)
        let tv = stage.textView
        let tlm = try #require(tv.textLayoutManager)
        let storage = try #require(tv.textStorage)
        // An edit in the image paragraph leaves its fragment laid out afresh, nothing cached.
        storage.replaceCharacters(in: NSRange(location: 0, length: 0), with: "A")
        tlm.ensureLayout(for: tlm.documentRange)
        storage.replaceCharacters(in: NSRange(location: 0, length: storage.length), with: "Short")
        tlm.ensureLayout(for: tlm.documentRange)
        #expect(tv.string == "Short")
    }
}
