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
    /// Last applied expanded state, to detect toggles.
    private var lastExpanded: Bool?
    /// Invalidates stale animation completions when a new toggle interrupts one.
    private var animationToken = 0

    /// Collapse/expand animation duration. Internal so tests can shrink it.
    var animationDuration: TimeInterval = 0.32

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
        applyExpansion(collapsedHeight: collapsedHeight, expanded: expanded, container: container)
    }

    func remove(from container: NativeTextViewContainer?) {
        animationToken += 1
        settledToken = animationToken   // no animation in flight after teardown
        animationTargetHeight = nil
        if let clipFrameObserver {
            NotificationCenter.default.removeObserver(clipFrameObserver)
            self.clipFrameObserver = nil
        }
        clipView?.removeFromSuperview()
        clipView = nil
        hostingView = nil
        equalityConstraint = nil
        constantConstraint = nil
        lastExpanded = nil
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
        container.headerHeight = reservedHeight
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
        // Expanded steady: the equality constraint already tracks the content.
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
            if expandedAfter, let equalityC = equalityConstraint, let constantC = constantConstraint {
                // Hand back to the live-tracking equality constraint.
                constantC.isActive = false
                equalityC.isActive = true
                clipView?.superview?.layoutSubtreeIfNeeded()
            }
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
