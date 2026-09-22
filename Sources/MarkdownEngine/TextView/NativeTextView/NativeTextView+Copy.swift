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
//  The buffer holds the DISPLAY form of a link or image embed (`[[Name]]` /
//  `![[Name]]`); its opaque suffix lives on the `.wikiLinkID` side-channel.
//  A copy that serialized the buffer verbatim therefore produced a reference
//  with no id — pasting it back created a dead link, and pasting it OVER the
//  original destroyed the only copy of the id. So the private raw-markdown
//  flavor carries the STORAGE form, rebuilt from the selection's own
//  attributes; the plain-text/HTML/RTF flavors keep the display form, so
//  nothing leaks a uuid into another app.
//

import AppKit

extension NativeTextView {
    override func copy(_ sender: Any?) {
        let sel = selectedRange()
        guard sel.length > 0 else {
            super.copy(sender)
            return
        }
        let display = (string as NSString).substring(with: sel)
        MarkdownPasteboardWriter.write(markdown: display,
                                       rawMarkdown: storageForm(ofSelection: sel, display: display),
                                       to: .general, extensions: configuration.extensions,
                                       directives: configuration.directives,
                                       directiveSettings: configuration.directiveSettings)
    }

    /// Storage form of `display`, recovering each link/embed's opaque suffix from
    /// the `.wikiLinkID` attributes of the selected run. The slice is re-wrapped in
    /// its own `NSTextStorage` so attribute indices line up with `display`'s.
    private func storageForm(ofSelection sel: NSRange, display: String) -> String {
        guard !configuration.rawSourceMode,
              let storage = textStorage,
              NSMaxRange(sel) <= storage.length,
              display.contains("[[") else { return display }
        let slice = NSTextStorage(attributedString: storage.attributedSubstring(from: sel))
        return WikiLinkService.makeStorageState(
            from: display, existingMetadata: [:], textStorage: slice,
            keepsImageIDsInSource: configuration.imageEmbed.keepsIDInSource
        ).storage
    }
}
