//
//  PerfTrace.swift
//  MarkdownEngine
//
//  Created by Luca Chen on 07.07.26.
//
//  TEMP diagnostics (typing performance). Prints one compact line per keystroke
//  with a per-phase breakdown plus the current document length, so we can see
//  which costs grow with file size instead of staying constant. The whole point:
//  type in a short file, then a long one, and compare `total` for the same edit.
//
//  Toggle: set the env var MD_PERF=0 in the run scheme to silence.
//  Debug-only — the whole thing compiles out in Release.
//  Remove before shipping (this file + the `PerfTrace.` call sites).
//

import Foundation

enum PerfTrace {
#if DEBUG
    static var enabled = ProcessInfo.processInfo.environment["MD_PERF"] != "0"
    /// Opt-in for the sampled full-rebuild verifier asserts (wiki splice,
    /// backtick census, parse buffer). They run 3× O(doc) work synchronously
    /// on every 64th keystroke — periodic spikes that pollute the PERF
    /// numbers — so they stay off unless explicitly requested.
    static let verifyEnabled = ProcessInfo.processInfo.environment["MD_PERF_VERIFY"] == "1"
#else
    static let enabled = false
    static let verifyEnabled = false
#endif

    // All call sites run on the main thread (the coordinator + text view are
    // main-actor), so plain static state is safe under the package's Swift 5 mode.
    private static var active = false
    private static var frameStart: UInt64 = 0
    private static var docLength = 0
    private static var phases: [(String, Double)] = []
    private static var notes: [String] = []

    private static func nowMs() -> Double {
        Double(DispatchTime.now().uptimeNanoseconds) / 1_000_000
    }

    /// Open a per-keystroke frame. Every `measure`/`note` until `end()` attaches to it.
    /// A frame already opened this keystroke is CONTINUED, not reset:
    /// shouldChangeTextIn opens the frame (so the pre-edit parse and the
    /// smart-input interceptors are counted — they used to run before the
    /// frame and were invisible), the mid-edit selection change and
    /// textDidChange attach to it. A frame left open by an edit that never
    /// reached textDidChange is considered stale after 1s and reset.
    static func begin(docLength len: Int) {
        guard enabled else { return }
        let now = DispatchTime.now().uptimeNanoseconds
        docLength = len
        if active, Double(now - frameStart) / 1_000_000 < 1_000 { return }
        active = true
        phases.removeAll(keepingCapacity: true)
        notes.removeAll(keepingCapacity: true)
        frameStart = now
    }

    /// Time one sequential top-level phase of the current frame.
    @discardableResult
    static func measure<T>(_ label: String, _ body: () -> T) -> T {
        guard enabled, active else { return body() }
        let t0 = nowMs()
        let result = body()
        phases.append((label, nowMs() - t0))
        return result
    }

    /// Attach a free-form detail line (e.g. how many tables were re-rendered).
    /// The closure only runs when tracing is active, so it costs nothing when off.
    static func note(_ make: () -> String) {
        guard enabled, active else { return }
        notes.append(make())
    }

    /// Close the frame and print total + per-phase breakdown + notes.
    static func end() {
        guard enabled, active else { return }
        active = false
        let total = Double(DispatchTime.now().uptimeNanoseconds - frameStart) / 1_000_000
        let breakdown = phases.map { String(format: "%@=%.2f", $0.0, $0.1) }.joined(separator: " ")
        print(String(format: "⌨️ PERF doc=%dch total=%.2fms | %@", docLength, total, breakdown))
        for note in notes { print("    └─ \(note)") }
    }

    /// Standalone timing print for a cost that runs *outside* the keystroke frame
    /// (e.g. the async wide-table overlay reconcile fired after the edit settles).
    static func stamp(_ label: String, _ ms: Double, _ detail: @autoclosure () -> String = "") {
        guard enabled else { return }
        print(String(format: "⏱️ PERF %@ %.2fms %@", label, ms, detail()))
    }
}
