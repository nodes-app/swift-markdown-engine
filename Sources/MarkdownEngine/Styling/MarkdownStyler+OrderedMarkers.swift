//
//  MarkdownStyler+OrderedMarkers.swift
//  MarkdownEngine
//
//  Created by Luca Chen on 30.07.26.
//
//  Membership helper for `1.` / `1)` ordered markers. The number the editor
//  SHOWS is positional (`MarkdownASTStyler`) and is painted over the source
//  digits; a SELECTION sweeping the marker reverts it to those digits, so the
//  coordinator has to recognise the lines that can do it. The caret does not:
//  it leaves the painted number standing. Rendering itself lives in the AST
//  styler; this file only answers membership.
//

import AppKit
import Foundation

extension MarkdownStyler {

    /// Indented ordered marker at line start, excluding task items — the AST
    /// styler never overlays those, so their digits are always literal.
    static let orderedListRegex: NSRegularExpression = try! NSRegularExpression(
        pattern: #"^([ \t]*)(\d+[.)])([ \t]+)(?!\[[ xX]\])"#,
        options: [.anchorsMatchLines]
    )
}
