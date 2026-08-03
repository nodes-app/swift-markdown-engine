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

    @Test func compareFullRenderWithAppendOnlyStreaming() {
        guard ProcessInfo.processInfo.environment[Self.benchmarkEnvironmentKey] == "1" else {
            return
        }

        let updates = generatedUpdates(totalUTF16Length: 50_000, chunkLength: 100)
        let fullRender = medianDuration(of: 3) {
            let stack = makeStack()
            for text in updates {
                stack.coordinator.rebuildTextStorageAndStyle(stack.textView, from: text)
                stack.textView.recalcOverscroll(for: stack.scrollView, debugTag: "benchmarkFull")
            }
        }
        let appendOnly = medianDuration(of: 3) {
            let stack = makeStack()
            for text in updates {
                stack.coordinator.updateStreamingDocument(
                    stack.textView,
                    in: stack.scrollView,
                    documentID: "benchmark",
                    text: text,
                    forceReset: false
                )
            }
        }

        let speedup = fullRender / appendOnly
        let speedupText = String(format: "%.2f", speedup)
        print(
            "STREAMING_MARKDOWN_BENCHMARK "
                + "updates=\(updates.count) utf16=50000 chunk=100 "
                + "full_ms=\(milliseconds(fullRender)) "
                + "streaming_ms=\(milliseconds(appendOnly)) "
                + "speedup=\(speedupText)x"
        )
        #expect(appendOnly < fullRender)
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

    private func generatedUpdates(totalUTF16Length: Int, chunkLength: Int) -> [String] {
        let line = "let value = compute(\"streaming markdown\") // generated response\n"
        var complete = "```swift\n"
        while (complete as NSString).length < totalUTF16Length - 4 {
            complete += line
        }
        complete = (complete as NSString).substring(to: totalUTF16Length - 4) + "```\n"

        let ns = complete as NSString
        return stride(from: chunkLength, through: ns.length, by: chunkLength).map { length in
            ns.substring(to: min(length, ns.length))
        }
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
