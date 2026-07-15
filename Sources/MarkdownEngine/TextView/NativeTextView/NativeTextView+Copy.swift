//
//  NativeTextView+Copy.swift
//  MarkdownEngine
//
//  Created by Luca Chen on 09.07.26.
//
//  Copy override. The storage holds RAW markdown styled in place, so the
//  default copy serializes junk (leaked syntax markers, raw caret line,
//  missing thematic breaks). Instead we hand the selected raw markdown to
//  `MarkdownPasteboardWriter`, which renders a clean HTML/RTF/web-archive set
//  and keeps the raw markdown as the plain-text flavor.
//

import AppKit

extension NativeTextView {
    override func copy(_ sender: Any?) {
        let sel = selectedRange()
        guard sel.length > 0 else {
            super.copy(sender)
            return
        }
        let raw = (string as NSString).substring(with: sel)
        MarkdownPasteboardWriter.write(markdown: raw, to: .general, extensions: configuration.extensions)
    }
}
