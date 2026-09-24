//
//  InlineSpanDensityTests.swift
//  MarkdownEngineTests
//
//  Inline parse cost against span density within one region (#109).
//
//  Two halves, and the first is the one that matters: the containment rewrite
//  has to be a pure performance change. `corpusFingerprint` folds the parsed
//  tree of 4000 pseudo-random inputs into one value, recorded on the PRE-rewrite
//  parser at the merge base (1a2bd74, i.e. with #118) — in the spirit of
//  `GoldenCorpusTests`, except the baseline covers shapes nobody would think to
//  write by hand.
//
//  Re-record it ONLY on a parser that predates the rewrite, otherwise it just
//  ratifies whatever the rewrite does. It is also a bare hash: when it fails,
//  diff `String(describing:)` per input against the old parser to see what moved.
//
//  The second half asserts the cost curve is linear in spans rather than
//  quadratic, so the scans can't quietly come back. It exists twice over:
//
//    - COUNTED (`expectLinearWork`) — asserts on `InlineParseCost`, the number
//      of claimed-range probes and containment tests a parse performs. Pure
//      functions of the input, so they read the same on any machine and run on
//      CI. Linear measures 6.0x; restoring the pre-rewrite pairwise
//      containment measures 33.9x.
//    - TIMED (`expectLinearInSpans`) — the original wall-clock ratio, kept for
//      absolute numbers and OPT-IN via `MDE_PERF=1 swift test`, because a ratio
//      of durations is not portable. See `perfGateEnabled`.
//
//  What the counted form does NOT catch is a brand-new scan that bypasses
//  `ClaimedIndex` and `buildTree` entirely; it holds the existing structures to
//  linear rather than proving nothing quadratic exists anywhere.
//

import Foundation
import Testing
@testable import MarkdownEngine

/// The TIMED cost-curve assertions run only under `MDE_PERF=1 swift test`.
/// The counted ones next to them always run.
///
/// A wall-clock RATIO is not portable, which is easy to miss because it looks
/// like it should be: the same parser measures 5.3x on an M-series laptop and
/// 10.9x on a shared `macos-15` runner, where `swift test --parallel` has 55
/// suites competing for cores throughout the measurement window. Gating CI on
/// that number buys flakiness, not safety — and no bound fixes it, since the
/// pre-rewrite floor (11.3x here) sits below the post-rewrite CI reading.
///
/// `corpusFingerprint` and the counted assertions are the regression nets that
/// DO hold everywhere, and they stay on by default.
private let perfGateEnabled = ProcessInfo.processInfo.environment["MDE_PERF"] != nil

@Suite("Inline parse cost vs. span density")
struct InlineSpanDensityTests {

    // MARK: - Corpus

    /// Deterministic LCG — the corpus must be identical across builds for the
    /// fingerprint to mean anything, and `SystemRandomNumberGenerator` isn't.
    private struct LCG {
        var state: UInt64 = 0x2545F4914F6CDD1D
        mutating func next(_ bound: Int) -> Int {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Int((state >> 33) % UInt64(bound))
        }
    }

    /// Fragments chosen to collide: bare and paired delimiters, escapes, and
    /// the openers of every claimed-span construct, so the corpus is dense in
    /// half-formed and nested spans rather than in valid markdown.
    private static let atoms = [
        "a", "bb", " ", "  ", "*", "**", "_", "__", "`", "``", "\\", "\\*", "\\`",
        "[", "]", "(", ")", "![", "[[", "]]", "|", "$", "==", "~~", "url", "http://e.com/x",
        "\n", "word", ".", "!", "*a*", "**b**", "`c`", "[d](e)", "[[f|g]]", "$h$",
    ]

    private func corpus(_ count: Int) -> [String] {
        var rng = LCG()
        return (0..<count).map { _ in
            var s = ""
            for _ in 0..<(3 + rng.next(14)) { s += Self.atoms[rng.next(Self.atoms.count)] }
            return s
        }
    }

    /// Swift's `Hasher` is per-process seeded, so fold by hand.
    private func fingerprint(_ strings: [String], registry: ExtensionRegistry) -> String {
        var fnv: UInt64 = 0xcbf29ce484222325
        func fold(_ s: String) {
            for b in s.utf8 { fnv = (fnv ^ UInt64(b)) &* 0x100000001b3 }
        }
        for s in strings {
            fold(s)
            fold(String(describing: InlineParser.parse(s, registry: registry)))
        }
        return String(fnv, radix: 16)
    }

    @Test("the containment rewrite changes no tree in a 4000-input corpus")
    func corpusFingerprint() {
        let registry = MarkdownEditorConfiguration(
            extensions: [HighlightExtension(), StrikethroughExtension()]
        ).extensionRegistry

        #expect(fingerprint(corpus(4000), registry: registry) == "b74649ffbbbe237a")
    }

    // MARK: - Cost curve, counted

    /// The work a parse actually does, as a count rather than a duration.
    ///
    /// `claimedProbes` covers the claimed-range queries every pass makes;
    /// `containmentTests` covers `buildTree`. Both were quadratic in the spans
    /// per region before the ordered walk. Summing them is deliberate — a
    /// paragraph of links makes no claimed-range queries at all (nothing is
    /// claimed before the link pass, and there are no `*` or `\\` characters to
    /// ask about), so `containmentTests` carries the signal there and
    /// `claimedProbes` carries it for code spans.
    private func cost(_ text: String, registry: ExtensionRegistry) -> Int {
        var cost = InlineParseCost()
        _ = InlineParser.parse(text, registry: registry, cost: &cost)
        return cost.claimedProbes + cost.containmentTests
    }

    /// 6x the spans must cost ~6x the work, not ~34x.
    ///
    /// Measured: 6.0x for every construct below. Restoring the pre-rewrite
    /// pairwise containment takes it to 33.9x. The bound sits in that gap, and
    /// unlike the wall-clock version it means the same thing everywhere —
    /// these are integers derived from the input, not timings.
    private func expectLinearWork(
        _ label: String,
        registry: ExtensionRegistry = MarkdownEditorConfiguration(
            extensions: [HighlightExtension()]
        ).extensionRegistry,
        _ make: (Int) -> String
    ) {
        let small = cost(paragraph(40, make), registry: registry)
        let large = cost(paragraph(240, make), registry: registry)

        // Guards against the assertion passing because nothing was measured.
        #expect(small > 0, "\(label): no work counted at all")

        let growth = Double(large) / Double(max(small, 1))
        #expect(growth < 8, "\(label): 6x spans cost \(String(format: "%.1f", growth))x work (\(small) -> \(large))")
    }

    @Test("code spans: parse WORK is linear in spans per paragraph")
    func codeSpanWork() { expectLinearWork("code") { "`word\($0)`" } }

    @Test("links: parse WORK is linear in spans per paragraph")
    func linkWork() { expectLinearWork("links") { "[word\($0)](https://e.com/\($0))" } }

    @Test("emphasis: parse WORK is linear in spans per paragraph")
    func emphasisWork() { expectLinearWork("emphasis") { "*word\($0)*" } }

    @Test("highlights: parse WORK is linear in spans per paragraph")
    func highlightWork() { expectLinearWork("highlight") { "==word\($0)==" } }

    // MARK: - Directives

    /// Directives landed after this suite was written (#120), and they are a
    /// claimed-span producer like any other.
    ///
    /// Each shape pairs the directive with a CODE SPAN deliberately. A
    /// paragraph of bare `@mk` claims nothing in passes 1-2, so `ClaimedIndex`
    /// is built empty and a pairwise scan over it is free — the assertion then
    /// holds no matter what the cursor does, and only `buildTree` is really
    /// under test. The code span gives the index something to scan, so these
    /// cover BOTH structures. Verified by restoring the pre-rewrite pairwise
    /// containment: with the code span they fail, without it they pass.
    private struct CountedMarker: MarkdownDirective {
        var syntax: DirectiveSyntax { DirectiveSyntax(name: "mk", form: .selfContained) }
    }

    private struct CountedBox: MarkdownDirective {
        var syntax: DirectiveSyntax { DirectiveSyntax(name: "bx", form: .container) }
    }

    private var directiveRegistry: ExtensionRegistry {
        MarkdownEditorConfiguration(directives: [CountedMarker(), CountedBox()]).extensionRegistry
    }

    @Test("self-contained directives: parse WORK is linear in spans per paragraph")
    func selfContainedDirectiveWork() {
        expectLinearWork("directive/self-contained", registry: directiveRegistry) { "`c\($0)` @mk" }
    }

    @Test("container directives: parse WORK is linear in spans per paragraph")
    func containerDirectiveWork() {
        expectLinearWork("directive/container", registry: directiveRegistry) { "`c\($0)` @bx{w\($0)}" }
    }

    @Test("a paragraph mixing claimed-span kinds does linear work")
    func mixedWork() {
        expectLinearWork("mixed") { i in
            switch i % 4 {
            case 0: return "`code\(i)`"
            case 1: return "\\*lit\(i)\\*"
            case 2: return "*em\(i)*"
            default: return "[l\(i)](u\(i))"
            }
        }
    }

    /// Nesting a claimed span inside a link label (#118) must not make the
    /// link pass rescan — `overlapping` peeks from the cursor rather than
    /// walking the array.
    @Test("code spans inside link labels stay linear")
    func nestedLabelWork() {
        expectLinearWork("nested labels") { "[`c\($0)` t](u\($0))" }
    }

    // MARK: - Cost curve, timed

    /// Minimum of several runs. That makes the ABSOLUTE number about as stable
    /// as a timing gets — noise only ever adds time — but it does not rescue
    /// the RATIO these tests assert on, which is why they are opt-in. Under
    /// sustained contention there is no quiet run to find a floor in, and the
    /// smaller measurement inflates proportionally more, so the ratio drifts
    /// up. The counted assertions above are the portable form.
    private func msPerParse(_ text: String, registry: ExtensionRegistry) -> Double {
        var best = Double.infinity
        for _ in 0..<7 {
            let start = DispatchTime.now().uptimeNanoseconds
            for _ in 0..<20 { _ = DocumentAST.parse(text, registry: registry) }
            let ms = Double(DispatchTime.now().uptimeNanoseconds - start) / 20 / 1_000_000
            best = min(best, ms)
        }
        return best
    }

    private func paragraph(_ n: Int, _ make: (Int) -> String) -> String {
        (0..<n).map(make).joined(separator: " ")
    }

    /// 6x the spans in one paragraph should cost ~6x, not ~30x.
    ///
    /// 8 is the geometric midpoint of the gap measured on Apple silicon —
    /// worst case after the rewrite is 5.6x (code), best case before it is
    /// 11.3x (highlight). Recalibrate against your own machine before reading
    /// a failure as a regression; the message prints the measured value.
    private func expectLinearInSpans(_ label: String, _ make: (Int) -> String) {
        let registry = MarkdownEditorConfiguration(extensions: [HighlightExtension()]).extensionRegistry
        let small = msPerParse(paragraph(40, make), registry: registry)
        let large = msPerParse(paragraph(240, make), registry: registry)
        let growth = large / small

        #expect(growth < 8, "\(label): 6x spans cost \(String(format: "%.1f", growth))x parse")
    }

    @Test("code spans: parse cost is linear in spans per paragraph", .enabled(if: perfGateEnabled))
    func codeSpanDensity() { expectLinearInSpans("code") { "`word\($0)`" } }

    @Test("links: parse cost is linear in spans per paragraph", .enabled(if: perfGateEnabled))
    func linkDensity() { expectLinearInSpans("links") { "[word\($0)](https://e.com/\($0))" } }

    @Test("emphasis: parse cost is linear in spans per paragraph", .enabled(if: perfGateEnabled))
    func emphasisDensity() { expectLinearInSpans("emphasis") { "*word\($0)*" } }

    @Test("highlights: parse cost is linear in spans per paragraph", .enabled(if: perfGateEnabled))
    func highlightDensity() { expectLinearInSpans("highlight") { "==word\($0)==" } }

    /// The pathological case the issue was filed from: escapes and code spans
    /// together, where every later pass used to rescan every claimed range.
    @Test("a paragraph mixing claimed-span kinds stays linear", .enabled(if: perfGateEnabled))
    func mixedDensity() {
        expectLinearInSpans("mixed") { i in
            switch i % 4 {
            case 0: return "`code\(i)`"
            case 1: return "\\*lit\(i)\\*"
            case 2: return "*em\(i)*"
            default: return "[l\(i)](u\(i))"
            }
        }
    }
}
