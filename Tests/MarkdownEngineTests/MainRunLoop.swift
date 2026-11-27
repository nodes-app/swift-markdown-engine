//
//  MainRunLoop.swift
//  MarkdownEngineTests
//
//  Created by Luca Chen on 27.11.26.
//
//  Runs a hosted editor's whole life inside one run-loop callout. Test code is a
//  main-queue job, and a run loop nested in one does not drain the main queue,
//  where the editor's own blocks wait. Outside a callout the harness drains that
//  queue with no autorelease pool, and a content storage autoreleased there is
//  never freed (traced with leaks). A callout that lands inside another suite's
//  job is tried again.
//

import Foundation

@MainActor
enum MainRunLoop {

    /// Runs `body` as a run-loop callout, where `spin` drains the main queue inside
    /// autorelease pools. Checks go after it: a callout is outside the test's task.
    static func callout<T>(_ body: @escaping @MainActor () -> T) async -> T {
        for _ in 0..<1000 {
            let result: T? = await withCheckedContinuation { (done: CheckedContinuation<T?, Never>) in
                RunLoop.main.perform {
                    MainActor.assumeIsolated {
                        done.resume(returning: drainsMainQueue() ? autoreleasepool(invoking: body) : nil)
                    }
                }
            }
            if let result { return result }
            // Called back inside another suite's main-queue job, which runs in parallel.
            try? await Task.sleep(nanoseconds: 2_000_000)
        }
        return await MainActor.run(body: body)
    }

    static func spin(_ seconds: TimeInterval = 0.3) {
        let deadline = Date(timeIntervalSinceNow: seconds)
        while Date() < deadline {
            autoreleasepool { _ = RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.01)) }
        }
    }

    private final class Flag { var isSet = false }

    private static func drainsMainQueue() -> Bool {
        let flag = Flag()
        DispatchQueue.main.async { flag.isSet = true }
        let deadline = Date(timeIntervalSinceNow: 0.05)
        while !flag.isSet, Date() < deadline {
            autoreleasepool { _ = RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.005)) }
        }
        return flag.isSet
    }
}
