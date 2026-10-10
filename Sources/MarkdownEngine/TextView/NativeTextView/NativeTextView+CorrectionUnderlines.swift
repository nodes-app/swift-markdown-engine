//
//  NativeTextView+CorrectionUnderlines.swift
//  MarkdownEngine
//
//  Created by Luca Chen on 09.10.26.
//
//  AppKit's blue underline under an autocorrected word belongs to the text
//  view, not to the document it was typed in.
//

import AppKit

extension NativeTextView {

    /// Drops every autocorrection underline and the range it tracks. One view
    /// shows every note, and on a switch the outgoing note's underline stood
    /// over the incoming one, then moved into its text (device log). The text
    /// checking controller is private on NSTextView, hence each step is guarded.
    func removeCorrectionUnderlines() {
        let controllerKey = NSSelectorFromString("textCheckingController")
        let remove = NSSelectorFromString("removeCorrectionIndicatorUnderlines")
        guard responds(to: controllerKey),
              let controller = perform(controllerKey)?.takeUnretainedValue() as? NSObject,
              controller.responds(to: remove) else { return }
        controller.perform(remove)
    }
}
