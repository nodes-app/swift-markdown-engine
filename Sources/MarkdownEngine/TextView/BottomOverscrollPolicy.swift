//
//  BottomOverscrollPolicy.swift
//  MarkdownEngine
//
//  Created by Luca Chen on 16.03.26.
//
//  Computes the comfortable bottom-of-document slack so the caret never
//  hugs the bottom edge of the visible viewport while typing.
//

import AppKit
import Foundation

struct BottomOverscrollPolicy {
    let overscrollPercent: CGFloat
    let minOverscrollPoints: CGFloat
    let maxOverscrollPoints: CGFloat
    let activationStartFraction: CGFloat
    let activationRangeFraction: CGFloat

    init(configuration: OverscrollPolicy) {
        self.overscrollPercent = configuration.percent
        self.minOverscrollPoints = configuration.minPoints
        self.maxOverscrollPoints = configuration.maxPoints
        self.activationStartFraction = configuration.activationStartFraction
        self.activationRangeFraction = configuration.activationRangeFraction
    }

    init(
        overscrollPercent: CGFloat,
        minOverscrollPoints: CGFloat,
        maxOverscrollPoints: CGFloat,
        activationStartFraction: CGFloat = OverscrollPolicy.default.activationStartFraction,
        activationRangeFraction: CGFloat = OverscrollPolicy.default.activationRangeFraction
    ) {
        self.overscrollPercent = overscrollPercent
        self.minOverscrollPoints = minOverscrollPoints
        self.maxOverscrollPoints = maxOverscrollPoints
        self.activationStartFraction = activationStartFraction
        self.activationRangeFraction = activationRangeFraction
    }

    func activeOverscroll(
        baseContentHeight: CGFloat,
        headerHeight: CGFloat = 0,
        visibleHeight: CGFloat,
        lineHeight: CGFloat
    ) -> CGFloat {
        // The header band scrolls with the content, so it counts toward activation
        // and unlock; the comfortable slack stays viewport-based (the band is gone
        // once the user reaches the document bottom).
        let stackedContentHeight = baseContentHeight + headerHeight
        let activationStartHeight = visibleHeight * activationStartFraction
        let activationRange = max(visibleHeight * activationRangeFraction, 1)
        let activationProgress = min(
            max((stackedContentHeight - activationStartHeight) / activationRange, 0),
            1
        )
        guard activationProgress > 0 else { return 0 }

        var desiredSlack = visibleHeight * overscrollPercent
        desiredSlack = min(desiredSlack, maxOverscrollPoints)
        desiredSlack = max(desiredSlack, minOverscrollPoints)
        desiredSlack = max(0, floor(desiredSlack - lineHeight))

        // Start unlocking downward scroll before the stacked content fully fills
        // the viewport, then blend into the final comfortable bottom slack.
        let scrollUnlockDistance = max(visibleHeight - stackedContentHeight, 0)
        return floor((scrollUnlockDistance + desiredSlack) * activationProgress)
    }
}
