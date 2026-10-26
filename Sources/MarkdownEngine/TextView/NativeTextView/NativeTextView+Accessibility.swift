//
//  NativeTextView+Accessibility.swift
//  MarkdownEngine
//
//  Created by Luca Chen on 26.10.26.
//

import AppKit

extension NativeTextView {
    /// Only the part inside the viewport. VoiceOver scrolls an element taller than the
    /// viewport until its top sits ~35 pt under the scroll area's top, and the text
    /// starts below the header band, so the page moved ~75 pt whenever the VoiceOver
    /// cursor landed on it (measured on 27.0.1). Lines report their own bounds.
    override func accessibilityFrame() -> NSRect {
        let full = super.accessibilityFrame()
        guard let scrollView = enclosingScrollView, let window else { return full }
        let clip = scrollView.contentView
        var viewport = window.convertToScreen(clip.convert(clip.bounds, to: nil))
        let insets = scrollView.contentInsets
        viewport.origin.y += insets.bottom
        viewport.size.height -= insets.top + insets.bottom
        let visible = full.intersection(viewport)
        return visible.isNull ? full : visible
    }
}
