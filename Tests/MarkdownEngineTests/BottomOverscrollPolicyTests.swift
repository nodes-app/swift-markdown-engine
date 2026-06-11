//
//  BottomOverscrollPolicyTests.swift
//  MarkdownEngineTests
//
//  Created by Luca Chen on 11.06.26.
//
//  Bottom-overscroll math, in particular how the scroll-away header band
//  participates in activation/unlock while the slack stays viewport-based.
//

import Foundation
import Testing
@testable import MarkdownEngine

@Suite("BottomOverscrollPolicy")
struct BottomOverscrollPolicyTests {

    /// Engine defaults: percent 0.5, max 450, min 40, activation 0.15 + 0.85.
    private let policy = BottomOverscrollPolicy(configuration: .default)
    private let visible: CGFloat = 800
    private let lineHeight: CGFloat = 26

    @Test func shortTextWithoutBandGetsNoSlack() {
        // Below the activation start (0.15 × 800 = 120): nothing to scroll.
        let slack = policy.activeOverscroll(
            baseContentHeight: 100, visibleHeight: visible, lineHeight: lineHeight
        )
        #expect(slack == 0)
    }

    @Test func emptyDocumentWithoutBandGetsNoSlack() {
        let slack = policy.activeOverscroll(
            baseContentHeight: 30, visibleHeight: visible, lineHeight: lineHeight
        )
        #expect(slack == 0)
    }

    @Test func expandedBandActivatesSlackForShortText() {
        // Text alone is below the activation start (100 < 120), but the 550pt
        // band pushes its end near the viewport bottom — slack must unlock.
        let slack = policy.activeOverscroll(
            baseContentHeight: 100, headerHeight: 550,
            visibleHeight: visible, lineHeight: lineHeight
        )
        #expect(slack > 0)
        // The document must actually overflow so the band can be scrolled away.
        let scrollRange = 550 + 100 + slack - visible
        #expect(scrollRange > 100)
    }

    @Test func fullyActivatedSlackIsBandIndependent() {
        // At full activation the band has scrolled away — slack must not change.
        // Defaults: floor(min(800 × 0.5, 450) − 26) = 374.
        let without = policy.activeOverscroll(
            baseContentHeight: 800, visibleHeight: visible, lineHeight: lineHeight
        )
        let with = policy.activeOverscroll(
            baseContentHeight: 800, headerHeight: 550,
            visibleHeight: visible, lineHeight: lineHeight
        )
        #expect(without == 374)
        #expect(with == 374)
    }

    @Test func headerlessRampMatchesPreBandBehavior() {
        // Locks the pre-header formula for plain editors (headerHeight = 0):
        // progress = (500 − 120) / 680, unlock = 300, slack = 374
        // → floor((300 + 374) × 0.55882…) = 376.
        let slack = policy.activeOverscroll(
            baseContentHeight: 500, visibleHeight: visible, lineHeight: lineHeight
        )
        #expect(slack == 376)
    }
}
