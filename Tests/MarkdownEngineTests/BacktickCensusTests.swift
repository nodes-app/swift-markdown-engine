#if os(macOS)
//
//  BacktickCensusTests.swift
//  MarkdownEngine
//
//  Created by Luca Chen on 07.07.26.
//

import Foundation
import Testing
@testable import MarkdownEngine

@Suite("Backtick census")
struct BacktickCensusTests {

    @Test func matchesComponentsSemantics() {
        let samples = [
            "", "`", "``", "```", "````", "`````", "``````",
            "a```b```c",
            "x\n```swift\nlet a = 1\n```\ny",
            "inline `code` only",
            "```````"
        ]
        for sample in samples {
            let expected = sample.components(separatedBy: "```").count - 1
            #expect(MarkdownDetection.tripleBacktickCount(in: sample as NSString) == expected,
                    "mismatch for \(sample.debugDescription)")
        }
    }
}
#endif
