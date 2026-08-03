import AppKit
import Foundation
import SwiftUI
import Testing
@testable import MarkdownEngine

/// Opt-in benchmark for generated Markdown. Run with:
///
/// `STREAMING_MARKDOWN_BENCHMARK=1 swift test -c release --filter StreamingMarkdownPerformanceTests`
@MainActor
@Suite("Streaming Markdown performance", .serialized)
struct StreamingMarkdownPerformanceTests {
    private static let benchmarkEnvironmentKey = "STREAMING_MARKDOWN_BENCHMARK"

    @Test func compareTextKitRenderingForAITokenStreaming() {
        guard ProcessInfo.processInfo.environment[Self.benchmarkEnvironmentKey] == "1" else {
            return
        }

        let totalUTF16Length = 30_000
        let chunkLength = 32
        let updates = generatedAIResponseUpdates(
            totalUTF16Length: totalUTF16Length,
            chunkLength: chunkLength
        )
        let fullRender = medianDuration(of: 3) {
            let stack = makeStack()
            for text in updates {
                stack.coordinator.rebuildTextStorageAndStyle(stack.textView, from: text)
                stack.textView.recalcOverscroll(for: stack.scrollView, debugTag: "benchmarkFull")
            }
        }
        let safe = medianDuration(of: 3) {
            renderStreaming(updates, validation: .safe)
        }
        let trustedAppendOnly = medianDuration(of: 3) {
            renderStreaming(updates, validation: .trustedAppendOnly)
        }

        let safeSpeedup = fullRender / safe
        let trustedSpeedup = fullRender / trustedAppendOnly
        print(
            "STREAMING_MARKDOWN_TEXTKIT_BENCHMARK "
                + "updates=\(updates.count) utf16=\(totalUTF16Length) chunk=\(chunkLength) "
                + "full_ms=\(milliseconds(fullRender)) "
                + "safe_ms=\(milliseconds(safe)) "
                + "safe_speedup=\(String(format: "%.2f", safeSpeedup))x "
                + "trusted_ms=\(milliseconds(trustedAppendOnly)) "
                + "trusted_speedup=\(String(format: "%.2f", trustedSpeedup))x"
        )
        #expect(safe < fullRender)
        #expect(trustedAppendOnly < safe)
    }

    private func renderStreaming(
        _ updates: [String],
        validation: MarkdownStreamingValidation
    ) {
        guard let finalText = updates.last else { return }
        let stack = makeStack()
        stack.coordinator.beginStreamingDocument(documentID: "benchmark")
        for text in updates {
            stack.coordinator.updateStreamingDocument(
                stack.textView,
                in: stack.scrollView,
                documentID: "benchmark",
                text: text,
                validation: validation,
                forceReset: false
            )
        }
        stack.coordinator.commitStreamingDocument(
            stack.textView,
            scrollView: stack.scrollView,
            text: finalText
        )
        stack.textView.recalcOverscroll(for: stack.scrollView, debugTag: "benchmarkCommit")
    }

    private func makeStack() -> (
        coordinator: NativeTextViewCoordinator,
        scrollView: ClampedScrollView,
        textView: NativeTextView
    ) {
        let coordinator = NativeTextViewCoordinator(
            text: .constant(""),
            fontName: "SF Pro",
            fontSize: 16,
            isWikiLinkActive: .constant(false),
            onLinkClick: nil,
            onInlineSelectionChange: nil
        )
        let stack = HeightBehaviorStack(heightBehavior: .fitsContent)
        coordinator.configuration = stack.textView.configuration
        coordinator.textView = stack.textView
        stack.textView.delegate = coordinator
        return (coordinator, stack.scrollView, stack.textView)
    }

    private func generatedAIResponseUpdates(
        totalUTF16Length: Int,
        chunkLength: Int
    ) -> [String] {
        let section = """
        ## Implementation notes

        The renderer receives **small cumulative token updates** and keeps completed text stable.

        - Validate the public contract.
        - Update only the TextKit tail.
        - Parse Markdown once when generation completes.

        ```swift
        for await delta in stream {
            response.append(delta)
            render(response)
        }
        ```

        This paragraph mixes `inline code`, emphasis, and a [documentation link](https://example.com).


        """
        var complete = "# Streaming Markdown response\n\n"
        while (complete as NSString).length < totalUTF16Length {
            complete += section
        }
        complete = (complete as NSString).substring(to: totalUTF16Length)

        let ns = complete as NSString
        var updates = stride(from: chunkLength, through: ns.length, by: chunkLength).map { length in
            ns.substring(to: min(length, ns.length))
        }
        if updates.last.map({ ($0 as NSString).length }) != ns.length {
            updates.append(complete)
        }
        return updates
    }

    private func medianDuration(of iterations: Int, operation: () -> Void) -> Double {
        var samples: [Double] = []
        samples.reserveCapacity(iterations)
        for _ in 0..<iterations {
            let start = ProcessInfo.processInfo.systemUptime
            operation()
            samples.append(ProcessInfo.processInfo.systemUptime - start)
        }
        return samples.sorted()[iterations / 2]
    }

    private func milliseconds(_ seconds: Double) -> String {
        String(format: "%.2f", seconds * 1_000)
    }
}
