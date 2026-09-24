//
//  TableWidthChangeRestyleTests.swift
//  MarkdownEngine
//

import AppKit
import Foundation
import SwiftUI
import Testing
@testable import MarkdownEngine

@MainActor
@Suite("Table width-change restyling", .serialized)
struct TableWidthChangeRestyleTests {

    private static let wrappingTable = """
        # Width-change fixture

        | Novel | Opening line |
        |---|---|
        | Der Zauberberg (1924) | Ein einfacher junger Mensch reiste im Hochsommer von Hamburg, seiner Vaterstadt, nach Davos-Platz im Graubündischen. |
        | The Master and Margarita (1966–67) | At the sunset hour of one warm spring day two men were to be seen at Patriarch's Ponds. |
        | The Picture of Dorian Gray (1890) | The studio was filled with the rich odour of roses, and when the light summer wind stirred amidst the trees of the garden. |

        ## Tail

        The table remains inactive while its container changes width.
        """

    private static let wideTable = """
        # Wide-table overlay fixture

        | PositionIdentifierThatCannotBreakAcrossLines | MarketViewIdentifierThatCannotBreakAcrossLines | MaximumLossAtExpiryIdentifierThatCannotBreakAcrossLines | UpsideAtExpiryIdentifierThatCannotBreakAcrossLines |
        |---|---|---|---|
        | LongCallIdentifierThatCannotBreakAcrossLines | BullishWithLimitedDownsideIdentifierThatCannotBreakAcrossLines | PremiumPaidIdentifierThatCannotBreakAcrossLines | TheoreticallyUnlimitedIdentifierThatCannotBreakAcrossLines |
        | ShortCallIdentifierThatCannotBreakAcrossLines | NeutralOrBearishIdentifierThatCannotBreakAcrossLines | TheoreticallyUnlimitedIdentifierThatCannotBreakAcrossLines | PremiumReceivedIdentifierThatCannotBreakAcrossLines |

        ## Tail

        The table stays inactive while its visible overlay changes width.
        """

    private static let optionPricingTable = """
        # Option pricing fixture

        | Position | Market view | Maximum loss at expiry | Upside at expiry |
        |:--|:--|--:|:--|
        | Long call | Bullish, with limited downside | Premium paid | Theoretically unlimited |
        | Short call | Neutral or bearish | Theoretically unlimited | Premium received |
        | Long put | Bearish or protective | Premium paid | Limited by $S_T \\ge 0$ |
        | Short put | Neutral or bullish | Large but limited | Premium received |

        ## Tail

        The table stays inactive while its visible geometry changes width.
        """

    private static func tables(count: Int) -> String {
        (0..<count).map { index in
            """
            ## Table \(index)

            | Identifier | Description |
            |---|---|
            | Entry \(index) | This uniquely numbered table contains enough breakable prose to change its rasterized width and height when the editor narrows. |
            """
        }.joined(separator: "\n\n") + "\n\n## Tail\n\nTrailing prose."
    }

    private static let manyTables = tables(count: 24)

    @MainActor
    private final class Harness {
        let window: NSWindow
        let textView: NativeTextView
        private let coordinator: NativeTextViewCoordinator

        init(
            source requestedSource: String? = nil,
            horizontalTextInset: CGFloat = 0,
            readingWidth: CGFloat? = nil,
            rendersTablesDuringLiveResize: Bool = true
        ) throws {
            _ = NSApplication.shared
            let source = requestedSource ?? TableWidthChangeRestyleTests.wrappingTable
            let frame = NSRect(x: 0, y: 0, width: 900, height: 650)
            let scrollView = ClampedScrollView(frame: frame)
            scrollView.hasVerticalScroller = false
            scrollView.hasHorizontalScroller = false
            scrollView.drawsBackground = false

            let textView = NativeTextView(frame: .zero)
            let textContainer = try #require(textView.textContainer)
            let textLayoutManager = try #require(textView.textLayoutManager)
            textContainer.lineFragmentPadding = 0
            textContainer.heightTracksTextView = false

            var configuration = MarkdownEditorConfiguration.default
            configuration.textInsets = TextInsets(
                horizontal: horizontalTextInset,
                vertical: 0
            )
            configuration.readingWidth = readingWidth
            configuration.rendersTablesDuringLiveResize = rendersTablesDuringLiveResize
            if let readingWidth {
                textContainer.widthTracksTextView = false
                textContainer.size = NSSize(
                    width: readingWidth,
                    height: .greatestFiniteMagnitude
                )
            } else {
                textContainer.widthTracksTextView = true
            }
            let font = NSFont.systemFont(ofSize: 16)
            let coordinator = NativeTextViewCoordinator(
                text: .constant(source),
                fontName: font.fontName,
                fontSize: font.pointSize,
                isWikiLinkActive: .constant(false),
                onLinkClick: nil,
                onInlineSelectionChange: nil
            )
            coordinator.configuration = configuration
            let layoutDelegate = MarkdownLayoutManagerDelegate()
            coordinator.layoutDelegate = layoutDelegate
            textLayoutManager.delegate = layoutDelegate
            let layoutBridge = LayoutBridge(textLayoutManager)
            coordinator.layoutBridge = layoutBridge

            textView.configuration = configuration
            textView.textContainerInset = NSSize(
                width: horizontalTextInset,
                height: 0
            )
            textView.baseFont = font
            textView.font = font
            textView.isEditable = true
            textView.isSelectable = true
            textView.isRichText = true
            textView.isVerticallyResizable = true
            textView.maxSize = NSSize(
                width: CGFloat.greatestFiniteMagnitude,
                height: CGFloat.greatestFiniteMagnitude
            )
            textView.layoutBridge = layoutBridge
            textView.string = source
            textView.setSelectedRange(NSRange(location: 0, length: 0))
            textView.delegate = coordinator

            let container = NativeTextViewContainer(frame: frame)
            container.autoresizingMask = [.width]
            container.clipsToBounds = true
            container.textView = textView
            let initialWidth = readingWidth == nil
                ? frame.width
                : textView.readingColumnWidth
            textView.frame = NSRect(
                x: 0,
                y: 0,
                width: initialWidth,
                height: 0
            )
            container.addSubview(textView)
            scrollView.documentView = container

            let window = NSWindow(
                contentRect: frame,
                styleMask: [.titled, .resizable],
                backing: .buffered,
                defer: false
            )
            window.contentView = scrollView
            window.orderFrontRegardless()

            coordinator.textView = textView
            coordinator.rebuildTextStorageAndStyle(
                textView,
                from: source,
                invalidateLayout: true
            )
            textView.recalcOverscroll(for: scrollView)
            if readingWidth != nil {
                textView.centerReadingColumn(forClipWidth: frame.width)
            }

            self.window = window
            self.textView = textView
            self.coordinator = coordinator
            Self.drain(mode: .default, duration: 0.05)
            textView.updateWideTableOverlays(immediately: true)
            _ = try #require(Self.renderedTable(in: textView))
        }

        func close() {
            window.orderOut(nil)
        }

        struct RenderedTable {
            let image: NSImage
            let bounds: CGRect
        }

        static func renderedTable(in textView: NSTextView) -> RenderedTable? {
            guard let storage = textView.textStorage,
                  storage.length > 0 else { return nil }
            var result: RenderedTable?
            storage.enumerateAttribute(
                .scrollableBlockFullRange,
                in: NSRange(location: 0, length: storage.length),
                options: []
            ) { value, range, stop in
                guard value != nil,
                      let image = storage.attribute(
                        .latexImage,
                        at: range.location,
                        effectiveRange: nil
                      ) as? NSImage,
                      let bounds = (
                        storage.attribute(
                            .latexBounds,
                            at: range.location,
                            effectiveRange: nil
                        ) as? NSValue
                      )?.rectValue else { return }
                result = RenderedTable(image: image, bounds: bounds)
                stop.pointee = true
            }
            return result
        }

        static func renderedTables(
            in textView: NSTextView
        ) -> [NSRange: RenderedTable] {
            guard let storage = textView.textStorage,
                  storage.length > 0 else { return [:] }
            var result: [NSRange: RenderedTable] = [:]
            storage.enumerateAttribute(
                .scrollableBlockFullRange,
                in: NSRange(location: 0, length: storage.length),
                options: []
            ) { value, range, _ in
                guard let fullRange = (value as? NSValue)?.rangeValue,
                      result[fullRange] == nil,
                      let image = storage.attribute(
                        .latexImage,
                        at: range.location,
                        effectiveRange: nil
                      ) as? NSImage,
                      let bounds = (
                        storage.attribute(
                            .latexBounds,
                            at: range.location,
                            effectiveRange: nil
                        ) as? NSValue
                      )?.rectValue else { return }
                result[fullRange] = RenderedTable(
                    image: image,
                    bounds: bounds
                )
            }
            return result
        }

        struct VisibleWideTable {
            let image: NSImage
            let frame: CGRect
        }

        static func visibleWideTable(in textView: NativeTextView) -> VisibleWideTable? {
            guard let overlay = textView.wideTableOverlays.values.first,
                  let imageView = overlay.documentView as? NSImageView,
                  let image = imageView.image else { return nil }
            return VisibleWideTable(image: image, frame: overlay.frame)
        }

        static func drain(mode: RunLoop.Mode, duration: TimeInterval) {
            let deadline = Date(timeIntervalSinceNow: duration)
            while Date() < deadline {
                RunLoop.main.run(
                    mode: mode,
                    before: min(deadline, Date(timeIntervalSinceNow: 0.01))
                )
            }
        }

        func resizeWindow(to width: CGFloat, display: Bool = true) {
            window.setContentSize(
                NSSize(width: width, height: window.contentLayoutRect.height)
            )
            window.layoutIfNeeded()
            if display {
                window.displayIfNeeded()
            }
        }

        func resizeDocumentContainer(to width: CGFloat) throws {
            let container = try #require(
                textView.superview as? NativeTextViewContainer
            )
            container.setFrameSize(
                NSSize(width: width, height: container.frame.height)
            )
        }

        func runInEventTracking(
            widths: [CGFloat],
            interval: TimeInterval = 0.03
        ) -> RenderedTable? {
            driveInEventTracking(widths: widths, interval: interval).result
        }

        func renderedWidthsDuringEventTracking(
            widths: [CGFloat],
            interval: TimeInterval = 0.03
        ) -> [CGFloat] {
            driveInEventTracking(
                widths: widths,
                interval: interval
            ).renderedWidths
        }

        private func driveInEventTracking(
            widths: [CGFloat],
            interval: TimeInterval
        ) -> EventTrackingDriver {
            let scrollView = textView.enclosingScrollView
            scrollView?.viewWillStartLiveResize()
            defer { scrollView?.viewDidEndLiveResize() }
            let driver = EventTrackingDriver(
                window: window,
                textView: textView,
                widths: widths
            )
            let timer = Timer(
                timeInterval: interval,
                target: driver,
                selector: #selector(EventTrackingDriver.advance(_:)),
                userInfo: nil,
                repeats: true
            )
            RunLoop.main.add(timer, forMode: .eventTracking)
            let deadline = Date(timeIntervalSinceNow: 2)
            while !driver.finished, Date() < deadline {
                RunLoop.main.run(
                    mode: .eventTracking,
                    before: Date(timeIntervalSinceNow: 0.05)
                )
            }
            timer.invalidate()
            return driver
        }
    }

    @MainActor
    private final class EventTrackingDriver: NSObject {
        let window: NSWindow
        let textView: NativeTextView
        let widths: [CGFloat]
        var index = 0
        var result: Harness.RenderedTable?
        var renderedWidths: [CGFloat] = []
        var finished = false

        init(
            window: NSWindow,
            textView: NativeTextView,
            widths: [CGFloat]
        ) {
            self.window = window
            self.textView = textView
            self.widths = widths
        }

        @objc func advance(_ timer: Timer) {
            if index > 0,
                let rendered = Harness.renderedTable(in: textView)
            {
                renderedWidths.append(rendered.bounds.width)
            }
            guard index < widths.count else {
                result = Harness.renderedTable(in: textView)
                finished = true
                timer.invalidate()
                return
            }
            let width = widths[index]
            index += 1
            window.setContentSize(
                NSSize(width: width, height: window.contentLayoutRect.height)
            )
            window.layoutIfNeeded()
            window.displayIfNeeded()
        }
    }

    @MainActor
    private final class EditRecorder: NSObject {
        var count = 0

        @objc func storageDidProcessEditing(_ notification: Notification) {
            count += 1
        }
    }

    @Test("Initially narrow tables stamp their paragraph for width-change restyling")
    func narrowTableStampsWidthChangeRange() throws {
        _ = NSApplication.shared
        let text = "| a | b |\n|---|---|\n| 1 | 2 |"
        let nsText = text as NSString
        let tokens = MarkdownTokenizer.parseTokensViaAST(in: text)
        let tableToken = try #require(tokens.first { $0.kind == .table })
        let font = NSFont.systemFont(ofSize: 15)
        let context = MarkdownStyler.StylingContext(
            nsText: nsText,
            tokens: tokens,
            codeTokens: [],
            activeTokenIndices: [],
            baseFont: font,
            layoutBridge: nil,
            baseDefaultLineHeight: 18,
            codeBackgroundColor: .windowBackgroundColor,
            latexMarkerFont: font,
            configuration: .default,
            wikiLinkIDProvider: { _ in nil }
        )

        let attributes = MarkdownStyler.styleTables(context)
        let stampedAnchor = try #require(attributes.first {
            $0.attributes[.scrollableBlockFullRange] != nil
        })

        #expect(stampedAnchor.range.length == 1)
        #expect(stampedAnchor.attributes[.scrollableBlockNaturalWidth] == nil)
        let stampedRange = try #require(
            stampedAnchor.attributes[.scrollableBlockFullRange] as? NSValue
        ).rangeValue
        #expect(stampedRange == nsText.paragraphRange(for: tableToken.range))
    }

    @Test("Tracked table width follows live text-view bounds when its container lags")
    func trackedTableWidthUsesLiveTextViewBounds() throws {
        _ = NSApplication.shared
        let textView = NativeTextView(
            frame: NSRect(x: 0, y: 0, width: 680, height: 400)
        )
        let textContainer = try #require(textView.textContainer)
        let textLayoutManager = try #require(textView.textLayoutManager)
        textView.textContainerInset = NSSize(width: 48, height: 0)
        textContainer.widthTracksTextView = false
        textContainer.size = NSSize(width: 804, height: 10_000)
        textContainer.widthTracksTextView = true
        let font = NSFont.systemFont(ofSize: 16)
        let context = MarkdownStyler.StylingContext(
            nsText: "" as NSString,
            tokens: [],
            codeTokens: [],
            activeTokenIndices: [],
            baseFont: font,
            layoutBridge: LayoutBridge(textLayoutManager),
            baseDefaultLineHeight: 19,
            codeBackgroundColor: .windowBackgroundColor,
            latexMarkerFont: font,
            configuration: .default,
            wikiLinkIDProvider: { _ in nil }
        )

        #expect(textContainer.size.width == 804)
        #expect(MarkdownStyler.effectiveContainerWidth(for: context) == 584)
    }

    @Test("Fixed table width follows its explicit text-container width")
    func fixedTableWidthUsesExplicitTextContainerWidth() throws {
        _ = NSApplication.shared
        let textView = NativeTextView(
            frame: NSRect(x: 0, y: 0, width: 680, height: 400)
        )
        let textContainer = try #require(textView.textContainer)
        let textLayoutManager = try #require(textView.textLayoutManager)
        textView.textContainerInset = NSSize(width: 48, height: 0)
        textContainer.widthTracksTextView = false
        textContainer.size = NSSize(width: 500, height: 10_000)
        let font = NSFont.systemFont(ofSize: 16)
        let context = MarkdownStyler.StylingContext(
            nsText: "" as NSString,
            tokens: [],
            codeTokens: [],
            activeTokenIndices: [],
            baseFont: font,
            layoutBridge: LayoutBridge(textLayoutManager),
            baseDefaultLineHeight: 19,
            codeBackgroundColor: .windowBackgroundColor,
            latexMarkerFont: font,
            configuration: .default,
            wikiLinkIDProvider: { _ in nil }
        )

        #expect(MarkdownStyler.effectiveContainerWidth(for: context) == 500)
    }

    @Test("Deferred tables retain their images during dragging and settle on release")
    func deferredTablesSettleOnRelease() throws {
        let harness = try Harness(
            source: Self.manyTables,
            rendersTablesDuringLiveResize: false
        )
        defer { harness.close() }
        let scrollView = try #require(harness.textView.enclosingScrollView)
        let initial = Harness.renderedTables(in: harness.textView)
        let source = harness.textView.string
        let selection = harness.textView.selectedRange()
        scrollView.viewWillStartLiveResize()
        for width in [820.0, 700, 580] {
            harness.resizeWindow(to: width, display: false)
            Harness.drain(mode: .eventTracking, duration: 0.01)
            let current = Harness.renderedTables(in: harness.textView)
            for (range, table) in initial {
                #expect(current[range]?.image === table.image)
            }
        }
        scrollView.viewDidEndLiveResize()
        let settled = Harness.renderedTables(in: harness.textView)
        for (range, table) in initial {
            let result = try #require(settled[range])
            #expect(result.image !== table.image)
            #expect(abs(result.bounds.width - 579) <= 1)
        }
        #expect(!harness.textView.pendingTableWidthChangeUpdate)
        #expect(harness.textView.string == source)
        #expect(harness.textView.selectedRange() == selection)
    }

    @Test("A queued ordinary resize cannot render deferred tables during dragging")
    func queuedResizeDefersUntilRelease() throws {
        let harness = try Harness(rendersTablesDuringLiveResize: false)
        defer { harness.close() }
        let initial = try #require(Harness.renderedTable(in: harness.textView))
        harness.resizeWindow(to: 820, display: false)
        let scrollView = try #require(harness.textView.enclosingScrollView)
        scrollView.viewWillStartLiveResize()
        Harness.drain(mode: .eventTracking, duration: 0.01)
        #expect(Harness.renderedTable(in: harness.textView)?.image === initial.image)
        harness.resizeWindow(to: 580, display: false)
        scrollView.viewDidEndLiveResize()
        let settled = try #require(Harness.renderedTable(in: harness.textView))
        #expect(abs(settled.bounds.width - 579) <= 1)
        #expect(!harness.textView.pendingTableWidthChangeUpdate)
    }

    @Test("Deferred tables consume a late final hosting width synchronously")
    func deferredTablesConsumeLateHostingWidth() throws {
        let harness = try Harness(rendersTablesDuringLiveResize: false)
        defer { harness.close() }
        let scrollView = try #require(harness.textView.enclosingScrollView)
        scrollView.viewWillStartLiveResize()
        harness.resizeWindow(to: 580, display: false)
        try harness.resizeDocumentContainer(to: 900)
        scrollView.viewDidEndLiveResize()
        try harness.resizeDocumentContainer(to: 580)
        let settled = try #require(Harness.renderedTable(in: harness.textView))
        #expect(abs(settled.bounds.width - 579) <= 1)
        #expect(!harness.textView.pendingTableWidthChangeUpdate)
    }

    @Test("Live window resize applies the table width before layout returns")
    func liveWindowResizeAppliesTableWidthSynchronously() throws {
        let harness = try Harness()
        defer { harness.close() }
        let scrollView = try #require(harness.textView.enclosingScrollView)
        let initial = try #require(
            Harness.renderedTable(in: harness.textView)
        )

        scrollView.viewWillStartLiveResize()
        defer { scrollView.viewDidEndLiveResize() }
        harness.resizeWindow(to: 580, display: false)
        let immediate = try #require(
            Harness.renderedTable(in: harness.textView)
        )

        #expect(immediate.image !== initial.image)
        #expect(abs(immediate.bounds.width - 579) <= 1)
        #expect(!harness.textView.pendingTableWidthChangeUpdate)
    }

    @Test("Post-resize hosting layout still applies the table width synchronously")
    func postResizeHostingLayoutAppliesTableWidthSynchronously() throws {
        let harness = try Harness()
        defer { harness.close() }
        let scrollView = try #require(harness.textView.enclosingScrollView)
        let initial = try #require(
            Harness.renderedTable(in: harness.textView)
        )

        // Model SwiftUI hosting with a final-width clip view whose document
        // container is still one layout pass behind.
        scrollView.viewWillStartLiveResize()
        harness.resizeWindow(to: 580, display: false)
        try harness.resizeDocumentContainer(to: 900)
        scrollView.viewDidEndLiveResize()
        try harness.resizeDocumentContainer(to: 580)
        let immediate = try #require(
            Harness.renderedTable(in: harness.textView)
        )

        #expect(immediate.image !== initial.image)
        #expect(abs(immediate.bounds.width - 579) <= 1)
        #expect(!harness.textView.pendingTableWidthChangeUpdate)
    }

    @Test("Deferred post-resize hosting layout applies before its callback returns")
    func deferredPostResizeHostingLayoutAppliesSynchronously() throws {
        let harness = try Harness()
        defer { harness.close() }
        let scrollView = try #require(harness.textView.enclosingScrollView)
        let initial = try #require(
            Harness.renderedTable(in: harness.textView)
        )
        var immediate: Harness.RenderedTable?
        var pendingAtReturn = false
        var didApplyTrailingLayout = false

        scrollView.viewWillStartLiveResize()
        harness.resizeWindow(to: 580, display: false)
        try harness.resizeDocumentContainer(to: 900)
        scrollView.viewDidEndLiveResize()
        RunLoop.main.perform(inModes: [.default]) {
            MainActor.assumeIsolated {
                try? harness.resizeDocumentContainer(to: 580)
                immediate = Harness.renderedTable(in: harness.textView)
                pendingAtReturn = harness.textView.pendingTableWidthChangeUpdate
                didApplyTrailingLayout = true
            }
        }
        let deadline = Date(timeIntervalSinceNow: 0.5)
        while !didApplyTrailingLayout, Date() < deadline {
            RunLoop.main.run(
                mode: .default,
                before: Date(timeIntervalSinceNow: 0.01)
            )
        }

        let rendered = try #require(immediate)
        #expect(rendered.image !== initial.image)
        #expect(abs(rendered.bounds.width - 579) <= 1)
        #expect(!pendingAtReturn)
    }

    @Test("Delayed post-resize hosting layout remains synchronous until consumed")
    func delayedPostResizeHostingLayoutRemainsSynchronous() async throws {
        let harness = try Harness()
        defer { harness.close() }
        let scrollView = try #require(harness.textView.enclosingScrollView)
        let initial = try #require(
            Harness.renderedTable(in: harness.textView)
        )

        scrollView.viewWillStartLiveResize()
        harness.resizeWindow(to: 580, display: false)
        try harness.resizeDocumentContainer(to: 900)
        scrollView.viewDidEndLiveResize()
        try await Task.sleep(for: .milliseconds(350))

        try harness.resizeDocumentContainer(to: 580)
        let immediate = try #require(
            Harness.renderedTable(in: harness.textView)
        )

        #expect(immediate.image !== initial.image)
        #expect(abs(immediate.bounds.width - 579) <= 1)
        #expect(!harness.textView.pendingTableWidthChangeUpdate)
    }

    @Test("Settled live resize does not arm a later ordinary width update")
    func settledLiveResizeDisarmsPostResizeSynchronization() throws {
        let harness = try Harness()
        defer { harness.close() }
        let scrollView = try #require(
            harness.textView.enclosingScrollView as? ClampedScrollView
        )

        scrollView.viewWillStartLiveResize()
        scrollView.viewDidEndLiveResize()

        #expect(!scrollView.requiresSynchronousTableWidthUpdate)
    }

    @Test("Every live-resize interval renders its intermediate table width")
    func everyLiveResizeIntervalRendersIntermediateTableWidth() throws {
        let harness = try Harness()
        defer { harness.close() }

        let renderedWidths = harness.renderedWidthsDuringEventTracking(
            widths: [820, 760, 700, 640, 580],
            interval: 0.04
        )

        #expect(renderedWidths.count == 5)
        for (rendered, expected) in zip(
            renderedWidths,
            [819.0, 759.0, 699.0, 639.0, 579.0]
        ) {
            #expect(abs(rendered - expected) <= 1)
        }
    }

    @Test("Live resize rerenders every table before resize ends")
    func liveResizeRerendersEveryTableBeforeResizeEnds() throws {
        let harness = try Harness(source: Self.manyTables)
        defer { harness.close() }
        let initial = Harness.renderedTables(in: harness.textView)
        let orderedRanges = initial.keys.sorted { $0.location < $1.location }
        let firstRange = try #require(orderedRanges.first)
        let lastRange = try #require(orderedRanges.last)
        let initialFirst = try #require(initial[firstRange])
        let initialLast = try #require(initial[lastRange])
        let scrollView = try #require(harness.textView.enclosingScrollView)

        scrollView.viewWillStartLiveResize()
        harness.resizeWindow(to: 580, display: false)
        let live = Harness.renderedTables(in: harness.textView)
        #expect(live.count == initial.count)
        let liveFirst = try #require(live[firstRange])
        let liveLast = try #require(live[lastRange])

        #expect(liveFirst.image !== initialFirst.image)
        #expect(liveLast.image !== initialLast.image)
        #expect(abs(liveLast.bounds.width - 579) <= 1)
        scrollView.viewDidEndLiveResize()
        let settledLast = try #require(
            Harness.renderedTables(in: harness.textView)[lastRange]
        )
        #expect(settledLast.image === liveLast.image)
        #expect(abs(settledLast.bounds.width - 579) <= 1)
    }

    @Test("Table reflow updates document height before tracking ends")
    func tableReflowUpdatesDocumentHeightBeforeTrackingEnds() throws {
        let harness = try Harness(
            source: Self.optionPricingTable,
            horizontalTextInset: 48
        )
        defer { harness.close() }
        let initialHeight = harness.textView.baseContentHeight

        let live = try #require(
            harness.runInEventTracking(widths: [760, 680, 600, 520])
        )

        #expect(live.bounds.height > 200)
        #expect(harness.textView.baseContentHeight > initialHeight)
        #expect(
            harness.textView.scrollableContentHeight
                >= harness.textView.baseContentHeight
        )
    }

    @Test("Wide-table overlay updates before event tracking ends")
    func wideTableOverlayUpdatesBeforeEventTrackingEnds() throws {
        let harness = try Harness(source: Self.wideTable)
        defer { harness.close() }
        let initialStorage = try #require(
            Harness.renderedTable(in: harness.textView)
        )
        #expect(initialStorage.bounds.width > 900)
        let initialOverlay = try #require(
            Harness.visibleWideTable(in: harness.textView)
        )

        let liveStorage = try #require(
            harness.runInEventTracking(widths: [820, 760, 700, 640, 580])
        )
        let liveOverlay = try #require(
            Harness.visibleWideTable(in: harness.textView)
        )

        #expect(liveOverlay.image !== initialOverlay.image)
        #expect(liveOverlay.image === liveStorage.image)
        #expect(abs(liveOverlay.frame.width - 580) <= 1)
    }

    @Test("Fixed-width table overlay follows its host below the reading width")
    func fixedWidthTableOverlayFollowsNarrowerHost() throws {
        let harness = try Harness(
            source: Self.wideTable,
            readingWidth: 500
        )
        defer { harness.close() }
        let initial = try #require(
            Harness.visibleWideTable(in: harness.textView)
        )

        try harness.resizeDocumentContainer(to: 480)
        let firstNarrow = try #require(
            Harness.visibleWideTable(in: harness.textView)
        )
        try harness.resizeDocumentContainer(to: 460)
        let secondNarrow = try #require(
            Harness.visibleWideTable(in: harness.textView)
        )

        #expect(firstNarrow.image === initial.image)
        #expect(secondNarrow.image === initial.image)
        #expect(firstNarrow.frame.width == 480)
        #expect(secondNarrow.frame.width == 460)
    }

    @Test("Wrapped tables preserve symmetric outer insets while resizing")
    func wrappedTablePreservesSymmetricOuterInsetsWhileResizing() async throws {
        let harness = try Harness(
            source: Self.optionPricingTable,
            horizontalTextInset: 48
        )
        defer { harness.close() }

        var previousTableWidth: CGFloat?
        for width in [700.0, 720.0, 740.0, 760.0, 780.0] {
            harness.textView.setFrameSize(
                NSSize(width: width, height: harness.textView.frame.height)
            )
            try await Task.sleep(for: .milliseconds(30))
            let table = try #require(Harness.renderedTable(in: harness.textView))
            let containerWidth = try #require(harness.textView.textContainer?.size.width)

            #expect(abs(table.bounds.width - containerWidth) < 0.25)
            if let previousTableWidth {
                #expect(abs(table.bounds.width - previousTableWidth - 20) < 0.25)
            }
            previousTableWidth = table.bounds.width
        }
    }

    @Test("Fractional width changes propagate without a threshold")
    func fractionalWidthChangesPropagateWithoutThreshold() throws {
        let harness = try Harness(
            source: Self.optionPricingTable,
            horizontalTextInset: 48
        )
        defer { harness.close() }

        try harness.resizeDocumentContainer(to: 659.75)
        Harness.drain(mode: .eventTracking, duration: 0.03)
        let first = try #require(
            Harness.renderedTable(in: harness.textView)
        )

        try harness.resizeDocumentContainer(to: 660)
        Harness.drain(mode: .eventTracking, duration: 0.03)
        let second = try #require(
            Harness.renderedTable(in: harness.textView)
        )

        #expect(harness.textView.frame.width == 660)
        #expect(second.image !== first.image)
        #expect(abs(second.bounds.width - first.bounds.width - 0.25) < 0.01)
    }

    @Test("Fractional table overflow enters scrollable mode")
    func fractionalTableOverflowEntersScrollableMode() throws {
        _ = NSApplication.shared
        let text = Self.wideTable
        let nsText = text as NSString
        let tokens = MarkdownTokenizer.parseTokensViaAST(in: text)
        let tableToken = try #require(tokens.first { $0.kind == .table })
        let source = nsText.substring(with: tableToken.range)
        let parsed = try #require(MarkdownStyler.parseTableSource(source))
        let appearance = try #require(NSAppearance(named: .aqua))
        let font = NSFont.systemFont(ofSize: 16)
        let baseContext = MarkdownStyler.StylingContext(
            nsText: nsText,
            tokens: tokens,
            codeTokens: [],
            activeTokenIndices: [],
            baseFont: font,
            layoutBridge: nil,
            baseDefaultLineHeight: 19,
            codeBackgroundColor: .windowBackgroundColor,
            latexMarkerFont: font,
            configuration: .default,
            wikiLinkIDProvider: { _ in nil }
        )
        let minimumWidth = MarkdownStyler.tableImage(
            for: source,
            parsed: parsed,
            ctx: baseContext,
            appearance: appearance,
            availableWidth: 1
        ).image.size.width
        let availableWidth = minimumWidth - 0.25
        let textView = NativeTextView(
            frame: NSRect(x: 0, y: 0, width: availableWidth, height: 400)
        )
        let textContainer = try #require(textView.textContainer)
        let textLayoutManager = try #require(textView.textLayoutManager)
        textContainer.widthTracksTextView = false
        textContainer.size = NSSize(
            width: availableWidth,
            height: .greatestFiniteMagnitude
        )
        let context = MarkdownStyler.StylingContext(
            nsText: nsText,
            tokens: tokens,
            codeTokens: [],
            activeTokenIndices: [],
            baseFont: font,
            layoutBridge: LayoutBridge(textLayoutManager),
            baseDefaultLineHeight: 19,
            codeBackgroundColor: .windowBackgroundColor,
            latexMarkerFont: font,
            configuration: .default,
            wikiLinkIDProvider: { _ in nil }
        )

        let attributes = MarkdownStyler.styleTables(context)
        let anchor = try #require(attributes.first {
            $0.attributes[.scrollableBlockFullRange] != nil
        })

        #expect(anchor.attributes[.scrollableBlockNaturalWidth] != nil)
    }

    @Test("Wide tables leave scrollable mode within one display frame")
    func wideTableLeavesScrollableModeWithinOneDisplayFrame() throws {
        let harness = try Harness(
            source: Self.optionPricingTable,
            horizontalTextInset: 48
        )
        defer { harness.close() }

        harness.textView.setFrameSize(
            NSSize(width: 400, height: harness.textView.frame.height)
        )
        Harness.drain(mode: .default, duration: 0.03)
        _ = try #require(Harness.visibleWideTable(in: harness.textView))

        harness.textView.setFrameSize(
            NSSize(width: 600, height: harness.textView.frame.height)
        )
        Harness.drain(mode: .eventTracking, duration: 0.03)

        #expect(Harness.visibleWideTable(in: harness.textView) == nil)
    }

    @Test("Rapid width writes coalesce to the latest width per run-loop turn")
    func rapidWidthWritesCoalesceToLatestWidthPerRunLoopTurn() async throws {
        let harness = try Harness()
        defer { harness.close() }
        let recorder = EditRecorder()
        NotificationCenter.default.addObserver(
            recorder,
            selector: #selector(EditRecorder.storageDidProcessEditing(_:)),
            name: NSTextStorage.didProcessEditingNotification,
            object: harness.textView.textStorage
        )
        defer { NotificationCenter.default.removeObserver(recorder) }

        for width in [840.0, 780.0, 720.0, 660.0] {
            harness.textView.setFrameSize(
                NSSize(width: width, height: harness.textView.frame.height)
            )
        }
        try await Task.sleep(for: .milliseconds(50))

        let table = try #require(Harness.renderedTable(in: harness.textView))
        #expect(recorder.count == 1)
        #expect(abs(table.bounds.width - 659) <= 1)
    }

    @Test("Event tracking leaves no deferred table restyles")
    func eventTrackingLeavesNoDeferredTableRestyles() async throws {
        let harness = try Harness()
        defer { harness.close() }
        let recorder = EditRecorder()
        NotificationCenter.default.addObserver(
            recorder,
            selector: #selector(EditRecorder.storageDidProcessEditing(_:)),
            name: NSTextStorage.didProcessEditingNotification,
            object: harness.textView.textStorage
        )
        defer { NotificationCenter.default.removeObserver(recorder) }

        let live = try #require(
            harness.runInEventTracking(widths: [820, 760, 700, 640, 580])
        )
        let countAtTrackingEnd = recorder.count
        try await Task.sleep(for: .milliseconds(50))

        let settled = try #require(Harness.renderedTable(in: harness.textView))
        #expect(abs(live.bounds.width - 579) <= 1)
        #expect(settled.image === live.image)
        #expect(recorder.count == countAtTrackingEnd)
    }
}
