//
//  ScrollingHeaderController.swift
//  MarkdownEngine
//
//  Owns the scroll-away header hosted above the editor body: an embedder-supplied
//  SwiftUI view in an `NSHostingView`, inside a clipping band at the top of the
//  container document view. The clip's height is the reserved band the body sits
//  below; collapsing animates it between the embedder's collapsed height and the
//  content's intrinsic height, so the top of the header stays put while the lower
//  content reveals/hides.
//

import AppKit
import SwiftUI

@MainActor
final class ScrollingHeaderController {
    /// Clip container whose height is the reserved top band. Reveals/hides the
    /// lower content while the top stays put.
    private(set) var clipView: NSView?
    /// Hosts the embedder's full header content, top-pinned inside the clip.
    private(set) var hostingView: NSHostingView<AnyView>?

    /// Active when expanded: `clip.height == host.height`, so the reserved band
    /// always equals the content's (async-resolved) intrinsic height — self-correcting.
    private var equalityConstraint: NSLayoutConstraint?
    /// Active when collapsed or animating: `clip.height == constant`.
    private var constantConstraint: NSLayoutConstraint?
    /// Observes the clip's height; the SOLE writer of `container.headerHeight`.
    private var clipFrameObserver: NSObjectProtocol?
    /// Observes the HOSTED view's height. While expanded the clip is held by the
    /// animatable constant constraint, so a content change reaches the band only
    /// through here — and it reaches it BEFORE the band has moved, which is the whole
    /// point (see `hostHeightChanged`).
    private var hostFrameObserver: NSObjectProtocol?
    /// Last applied expanded state, to detect toggles.
    private var lastExpanded: Bool?
    /// Invalidates stale animation completions when a new toggle interrupts one.
    private var animationToken = 0

    /// Collapse/expand animation duration. Internal so tests can shrink it.
    var animationDuration: TimeInterval = 0.32

    /// Height changes arriving before this instant are applied without animating.
    ///
    /// A document switch changes the hosted header's height exactly like a disclosure
    /// does — the controller sees "the content is now a different height" and nothing
    /// else — but it must not be revealed: the reader asked for another document, not
    /// for the header to grow, and animating it drags the whole body text along for
    /// 0.32s. Measured: two notes whose inspectors differ by 6pt slid the entire
    /// document on every switch.
    ///
    /// A deadline rather than a one-shot flag: if the new document happens to have the
    /// SAME header height, no change arrives and a one-shot flag would stay armed and
    /// swallow the next real disclosure. The window is short enough that only the
    /// switch's own relayout falls inside it (measured 3ms after the reconcile).
    private var snapHeightChangesUntil: Date?

    /// The embedder is switching documents: apply the next header height change
    /// straight away instead of revealing it.
    func snapNextHeightChange() {
        snapHeightChangesUntil = Date(timeIntervalSinceNow: 0.2)
    }

    /// The reserved top band the body should sit below. When the constant
    /// constraint governs (collapsed / animating) this is its `constant` — stable
    /// against transient mid-layout clip frames; otherwise the live clip height.
    var reservedHeight: CGFloat {
        if let constantConstraint, constantConstraint.isActive {
            return constantConstraint.constant
        }
        return clipView?.frame.height ?? 0
    }


    deinit {
        if let clipFrameObserver {
            NotificationCenter.default.removeObserver(clipFrameObserver)
        }
        if let hostFrameObserver {
            NotificationCenter.default.removeObserver(hostFrameObserver)
        }
    }


    /// Build the header on first call; afterwards refresh the hosted content
    /// (every call — the embedder's view may capture changing values) and apply
    /// the collapse/expand state.
    func reconcile(
        header: AnyView,
        collapsedHeight: CGFloat,
        expanded: Bool,
        container: NativeTextViewContainer
    ) {
        if clipView == nil {
            build(header: header, collapsedHeight: collapsedHeight, expanded: expanded, container: container)
        } else if let hostingView {
            // Refresh on every reconcile (every updateNSView, including keystrokes):
            // the embedder's view may capture changing values, and SwiftUI's diff of
            // an unchanged hierarchy is cheap — the same cost the header would pay
            // rendered anywhere else in the embedder's tree. @State inside the
            // header survives (same root structure diffs in place).
            hostingView.rootView = header
        }
        adoptSwitchedContentHeight(container: container)
        applyExpansion(collapsedHeight: collapsedHeight, expanded: expanded, container: container)
    }

    /// The embedder just swapped the document. Take the new content's height NOW,
    /// in the same pass that installed it.
    ///
    /// Waiting for `hostHeightChanged` is too late even when it applies the change
    /// instantly: the host is only re-measured a layout pass later, so the new
    /// document's text is laid out against the OLD band and then moved. Measured on a
    /// 6pt difference — reconcile at 72795 and 72809 both still saw the old height, the
    /// host resized at 72812, the band followed at 72817, and the body text visibly
    /// stepped. The equality constraint used to make this free, because it resized the
    /// clip in the same pass as the host.
    ///
    /// Nothing to animate here by definition: the reader asked for another document.
    private func adoptSwitchedContentHeight(container: NativeTextViewContainer) {
        guard let until = snapHeightChangesUntil, Date() < until,
              lastExpanded == true,
              let host = hostingView,
              let constantC = constantConstraint, constantC.isActive else { return }

        host.invalidateIntrinsicContentSize()
        host.layoutSubtreeIfNeeded()
        let target = host.fittingSize.height
        guard target > 0 else { return }

        if abs(target - constantC.constant) > 0.5 {
            animationToken += 1
            settledToken = animationToken
            animationTargetHeight = nil
            constantC.constant = target
        }
        // Gated on the CLIP, not the constant. The host observer usually sets the
        // constant a few ms before this runs, so a constant-based guard returned early
        // and left the clip — which is what `headerHeight` and therefore the body's
        // origin are read from — trailing by 42ms on every switch. Small deltas hide
        // that; a note with many tags against one with none would not.
        guard let clip = clipView, abs(clip.frame.height - constantC.constant) > 0.5 else { return }

        // Resolve in THIS pass, so the band is right before the new document paints.
        // Legal here (unlike inside the frame observers): reconcile runs from
        // updateNSView, not from within a layout pass.
        container.layoutSubtreeIfNeeded()
    }

    func remove(from container: NativeTextViewContainer?) {
        animationToken += 1
        settledToken = animationToken   // no animation in flight after teardown
        animationTargetHeight = nil
        // Observers first, and the state they guard on before the views are detached:
        // `removeFromSuperview()` lays out, which fires the HOST observer synchronously
        // (queue: nil). Reached with `lastExpanded`/`constantConstraint` still set, it
        // passes every guard and starts an animation — advancing `animationToken` right
        // after this method equalised it, so the controller believes an animation is in
        // flight for the rest of its life.
        if let clipFrameObserver {
            NotificationCenter.default.removeObserver(clipFrameObserver)
            self.clipFrameObserver = nil
        }
        if let hostFrameObserver {
            NotificationCenter.default.removeObserver(hostFrameObserver)
            self.hostFrameObserver = nil
        }
        lastExpanded = nil
        equalityConstraint = nil
        constantConstraint = nil
        hostingView = nil
        clipView?.removeFromSuperview()
        clipView = nil
        container?.headerHeight = 0   // → restack: text view back to y=0, container shrinks
    }

    // MARK: - Internals

    private func build(
        header: AnyView,
        collapsedHeight: CGFloat,
        expanded: Bool,
        container: NativeTextViewContainer
    ) {
        // Body compositing, gated on header presence so header-less editors keep
        // AppKit's default rendering: the body is layer-backed (TextKit 2's default,
        // asserted here for the seam fix), redrawn only on explicit invalidation, and
        // clipped to its bounds so responsive-scroll OVERDRAW can't render text above
        // the frame top into the header band. NSView does NOT clip by default; without
        // this the body bleeds up over the collapsed header even though the frames
        // are disjoint. Left in place if the header is later removed — un-clipping a
        // live text view buys nothing and risks a repaint glitch.
        if let textView = container.textView {
            textView.wantsLayer = true
            textView.layerContentsRedrawPolicy = .onSetNeedsDisplay
            textView.clipsToBounds = true
        }

        let host = NSHostingView(rootView: header)
        if #available(macOS 13.0, *) { host.sizingOptions = [.intrinsicContentSize] }
        // Ignore the window safe area (the toolbar/navbar region). Otherwise, as the
        // host scrolls relative to that safe area, SwiftUI adds/removes a TOP inset to
        // "flow under the navbar" — which shifts the content down inside the host,
        // pushes the collapsed band's content below the clip mask, and makes the
        // measured intrinsic height oscillate with the scroll position.
        if #available(macOS 13.3, *) { host.safeAreaRegions = [] }

        let clip = NSView()
        // Layer-back the clip so `clipsToBounds` reliably masks the layer-backed
        // NSHostingView; without it the inspector body bleeds below the collapsed
        // band on async resize (ghost rows + stale heading paints).
        clip.wantsLayer = true
        clip.translatesAutoresizingMaskIntoConstraints = false
        clip.clipsToBounds = true
        clip.postsFrameChangedNotifications = true
        // The clip is a SIBLING of the text view inside the container (top band).
        // Auto-Layout-pinned to the container's top/leading/trailing; its height is
        // owned by the equality/constant constraint pair below and read back into
        // `container.headerHeight`.
        container.addSubview(clip)

        host.translatesAutoresizingMaskIntoConstraints = false
        clip.addSubview(host)

        // Two height options for the clip; exactly one is active at a time.
        //  • equality: clip.height == host.height  → expanded, tracks content live.
        //  • constant: clip.height == <value>      → collapsed, or animating.
        let equalityC = clip.heightAnchor.constraint(equalTo: host.heightAnchor)
        let constantC = clip.heightAnchor.constraint(equalToConstant: max(0, collapsedHeight))
        NSLayoutConstraint.activate([
            clip.topAnchor.constraint(equalTo: container.topAnchor),
            clip.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            clip.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            // Host is full-height (top-pinned); overflow below the clip is hidden.
            host.topAnchor.constraint(equalTo: clip.topAnchor),
            host.leadingAnchor.constraint(equalTo: clip.leadingAnchor),
            host.trailingAnchor.constraint(equalTo: clip.trailingAnchor)
        ])
        if expanded { equalityC.isActive = true } else { constantC.isActive = true }

        hostingView = host
        clipView = clip
        equalityConstraint = equalityC
        constantConstraint = constantC
        lastExpanded = expanded

        // SOLE writer of `container.headerHeight`: the clip's height drives the header
        // band, which the container reads to offset the text view. Synchronous (queue
        // nil) so the body tracks the header with no lag. `reservedHeight` reads the
        // constant's intended value while it governs — a scroll-time layout pass can
        // momentarily expose a smaller in-flight clip frame.
        clipFrameObserver = NotificationCenter.default.addObserver(
            forName: NSView.frameDidChangeNotification, object: clip, queue: nil
        ) { [weak self, weak container] _ in
            MainActor.assumeIsolated {
                guard let self, let container else { return }
                let h = self.reservedHeight
                guard abs(container.headerHeight - h) > 0.1 else { return }
                container.headerHeight = h
            }
        }

        container.layoutSubtreeIfNeeded()

        // Expanded: hand the clip straight to the constant constraint, seeded with the
        // height equality just resolved. From here on the band is OWNED by the constant
        // and content changes arrive via `hostHeightChanged` — if the equality
        // constraint kept the clip, Auto Layout would resize the band to the new content
        // before anything could animate it, and the reveal would start from a frame
        // already showing the end state (measured: clip=782 while the band read 913).
        if expanded, let equalityC = equalityConstraint, let constantC = constantConstraint,
           let clip = clipView, clip.frame.height > 0 {
            constantC.constant = clip.frame.height
            equalityC.isActive = false
            constantC.isActive = true
        }
        host.postsFrameChangedNotifications = true
        hostFrameObserver = NotificationCenter.default.addObserver(
            forName: NSView.frameDidChangeNotification, object: host, queue: nil
        ) { [weak self, weak container] _ in
            MainActor.assumeIsolated {
                guard let self, let container else { return }
                self.hostHeightChanged(container: container)
            }
        }

        container.headerHeight = reservedHeight
    }

    /// The hosted content changed height while the header is expanded — a second
    /// inspector section opened or closed. The clip is on the constant constraint, so
    /// the band has NOT moved yet: animate it to the content's new height with the
    /// crossing's own curve, and the reveal starts where the reader last saw it.
    private func hostHeightChanged(container: NativeTextViewContainer) {
        guard lastExpanded == true,
              let constantC = constantConstraint, constantC.isActive,
              let host = hostingView else { return }
        let target = host.frame.height
        // RETARGET rather than ignore while an animation is in flight. Dropping the
        // change loses it for good — the band is held by the constant constraint for
        // the whole expanded state, so nothing comes along later to correct it. Toggling
        // a section twice in quick succession then finished on the height of the OPEN
        // state while the content was already closed. Mid-flight the constant is a
        // moving value, so the comparison has to be against the target it is heading for.
        let pending = (animationToken == settledToken) ? constantC.constant
                                                       : (animationTargetHeight ?? constantC.constant)
        // `> 0` is load-bearing: an un-laid-out host reports 0, and accepting that here
        // drives the band to zero and desynchronises it from the expansion state
        // (proven — allowing 0 swaps the expand and collapse test outcomes). The cost is
        // that a header which legitimately EMPTIES cannot collapse the band: zero is
        // both "not measured yet" and "nothing to show", and the two are not
        // distinguishable from the height alone. Such an embedder must collapse the
        // header via `headerExpanded` instead of by emptying its content.
        guard target > 0, abs(target - pending) > 0.5 else { return }

        // A live window resize reflows the inspector continuously, an offscreen
        // container is still settling its first layout, and a document switch is the
        // reader asking for other content — none of the three is a disclosure, so track
        // those directly instead of animating them. Still through the animator at zero
        // duration: a plain property set would leave an animation already in flight
        // ticking toward its stale target underneath.
        let isDocumentSwitch = (snapHeightChangesUntil.map { Date() < $0 } ?? false)
        guard !container.inLiveResize, container.window != nil, !isDocumentSwitch else {
            animationToken += 1
            settledToken = animationToken
            animationTargetHeight = nil
            // Assigned DIRECTLY, not through the animator. Even at zero duration the
            // animator defers the model value to a later transaction — measured 57ms,
            // which on a document switch reads as the body text sitting still and then
            // jumping. The token is advanced so a completion from an animation that was
            // in flight cannot settle on top of this; that animation's remaining frames
            // are a rare, brief tail, which is the cheaper trade against a visible
            // delay on every single switch.
            animationToken += 1
            settledToken = animationToken
            animationTargetHeight = nil
            constantC.constant = target
            return
        }
        animate(to: target, expandedAfter: true, container: container)
    }

    private func applyExpansion(
        collapsedHeight: CGFloat,
        expanded: Bool,
        container: NativeTextViewContainer
    ) {
        guard let equalityC = equalityConstraint,
              let constantC = constantConstraint,
              let clip = clipView,
              let host = hostingView else { return }
        let collapsed = max(0, collapsedHeight)

        if lastExpanded != expanded {
            lastExpanded = expanded
            // Hand the clip height to the animatable constant constraint.
            let start = clip.frame.height
            equalityC.isActive = false
            constantC.constant = start
            constantC.isActive = true
            let target: CGFloat
            if expanded {
                host.invalidateIntrinsicContentSize()
                host.layoutSubtreeIfNeeded()
                target = max(collapsed, host.fittingSize.height)
            } else {
                target = collapsed
            }
            animate(to: target, expandedAfter: expanded, container: container)
        } else if !expanded, constantC.isActive {
            if animationToken != settledToken {
                // A collapse animation is in flight. If the collapsed height changed
                // mid-flight (e.g. the pinned row re-measured), retarget — the new
                // value arrives only on this reconcile and would otherwise be lost.
                if let target = animationTargetHeight, abs(target - collapsed) > 0.5 {
                    animate(to: collapsed, expandedAfter: false, container: container)
                }
            } else if abs(constantC.constant - collapsed) > 0.5 {
                // Collapsed steady: keep the constant in sync with the collapsed height.
                constantC.constant = collapsed
                container.layoutSubtreeIfNeeded()
            }
        }
        // Expanded steady: nothing to do here. The band is held by the constant
        // constraint and follows content through `hostHeightChanged`, which sees a
        // disclosure the moment the hosted view resizes — earlier than this reconcile,
        // which an embedder may skip entirely when its own state has not changed.
    }

    /// Tracks whether an animation is in flight: `animationToken` advances on every
    /// animation start and interruption; `settledToken` catches up on settle.
    private var settledToken = 0
    /// Target of the in-flight animation, for mid-flight retargeting.
    private var animationTargetHeight: CGFloat?

    private func animate(to target: CGFloat, expandedAfter: Bool, container: NativeTextViewContainer) {
        guard let constantC = constantConstraint else { return }
        animationToken += 1
        let token = animationToken
        animationTargetHeight = target

        func settle() {
            guard token == animationToken else { return }   // interrupted by a newer toggle
            settledToken = token
            animationTargetHeight = nil
            // The clip STAYS on the constant constraint while expanded. Handing it back
            // to the live-tracking equality constraint is what let a later disclosure
            // resize the band in one layout pass before anything could animate it; the
            // band now follows content through `hostHeightChanged` instead.
            // One clamp once the height has settled (skipped during the animation).
            (container.enclosingScrollView as? ClampedScrollView)?.clampToInsets()
        }

        // ALWAYS go through the animator, even for a no-distance move: a direct
        // property set would not cancel an animation already in flight on the
        // constant, which would keep ticking toward its stale target underneath us.
        let start = constantC.constant
        let instant = abs(target - start) <= 0.5
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = instant ? 0 : animationDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            // Animating the constraint's constant marks the container needing layout
            // each frame; the window's display cycle runs the layout pass, the clip's
            // frame change fires the observer, and the body tracks the band.
            constantC.animator().constant = target
        }, completionHandler: {
            MainActor.assumeIsolated { settle() }
        })
        if instant { container.layoutSubtreeIfNeeded() }
    }
}
