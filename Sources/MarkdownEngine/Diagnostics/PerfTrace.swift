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
    /// Summed costs for code that runs MANY times per frame or from inside
    /// AppKit callbacks (caret reveal, spell-checker callbacks) — printed as
    /// `+label=…(×n)` after the sequential phases.
    private static var accumulated: [(String, Double, Int)] = []

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
        accumulated.removeAll(keepingCapacity: true)
        frameStart = now
    }

    /// Like `measure`, but SUMS repeated calls under one label instead of
    /// appending a phase per call — for work triggered from inside AppKit
    /// (caret reveal, spell-checker callbacks) that can fire several times
    /// per keystroke and would otherwise stay invisible in the frame.
    @discardableResult
    static func accumulate<T>(_ label: String, _ body: () -> T) -> T {
        guard enabled, active else { return body() }
        let t0 = nowMs()
        let result = body()
        let dt = nowMs() - t0
        if let i = accumulated.firstIndex(where: { $0.0 == label }) {
            accumulated[i].1 += dt
            accumulated[i].2 += 1
        } else {
            accumulated.append((label, dt, 1))
        }
        return result
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

    /// Record a named timestamp (offset from frame start) inline in the
    /// breakdown, printed as `@label=12.34`. The gaps BETWEEN checkpoints and
    /// the measured spans locate work the spans don't cover (AppKit edit
    /// application, layout, notification dispatch between our callbacks).
    static func checkpoint(_ label: String) {
        guard enabled, active else { return }
        phases.append(("@" + label, Double(DispatchTime.now().uptimeNanoseconds - frameStart) / 1_000_000))
    }

    /// Close the frame and print total + per-phase breakdown + notes.
    /// `other` = total − Σ(phases + accumulated): time inside the frame that
    /// no span covers (AppKit edit processing, layout, unmeasured code).
    static func end() {
        guard enabled, active else { return }
        active = false
        let total = Double(DispatchTime.now().uptimeNanoseconds - frameStart) / 1_000_000
        var breakdown = phases.map { String(format: "%@=%.2f", $0.0, $0.1) }.joined(separator: " ")
        if !accumulated.isEmpty {
            breakdown += " " + accumulated.map { String(format: "+%@=%.2f(×%d)", $0.0, $0.1, $0.2) }.joined(separator: " ")
        }
        let covered = phases.filter { !$0.0.hasPrefix("@") }.reduce(0) { $0 + $1.1 }
            + accumulated.reduce(0) { $0 + $1.1 }
        print(String(format: "⌨️ PERF doc=%dch total=%.2fms | %@ other=%.2f", docLength, total, breakdown, total - covered))
        for note in notes { print("    └─ \(note)") }
    }

    /// Standalone timing print for a cost that runs *outside* the keystroke frame
    /// (e.g. the async wide-table overlay reconcile fired after the edit settles).
    static func stamp(_ label: String, _ ms: Double, _ detail: @autoclosure () -> String = "") {
        guard enabled else { return }
        print(String(format: "⏱️ PERF %@ %.2fms %@", label, ms, detail()))
    }
}
