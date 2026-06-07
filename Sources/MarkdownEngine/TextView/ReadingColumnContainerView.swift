//
//  ReadingColumnContainerView.swift
//  MarkdownEngine
//
//  Created by Luca Chen on 07.06.26.
//
//  Full-width documentView: centers a fixed-width text column by position; wide tables break out full-width.
//

import AppKit

final class ReadingColumnContainerView: NSView {
    weak var textView: NativeTextView?
    override var isFlipped: Bool { true }
}

extension NSScrollView {
    /// Editor text view, whether it's the documentView directly or the centered subview of a container.
    var nativeTextView: NativeTextView? {
        if let tv = documentView as? NativeTextView { return tv }
        return (documentView as? ReadingColumnContainerView)?.textView
    }
}
