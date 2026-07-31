//
//  MarkdownStyler+FrontMatter.swift
//  MarkdownEngine
//
//  Hides a leading YAML front-matter block (`---` … `---`) in the editor.
//  Hosts typically surface the parsed keys/values in their own UI, so the raw
//  block is collapsed to nothing — unless the caret is inside it, in which case
//  the raw YAML is revealed for editing. Without this the fences would also
//  render as thematic-break rules, which this pass suppresses.
//

import AppKit
import Foundation

extension MarkdownStyler {

    static func styleFrontMatter(_ ctx: StylingContext) -> [StyledRange] {
        guard let fm = frontMatterRange(in: ctx.nsText) else { return [] }

        var attrs: [StyledRange] = []
        // The opening/closing `---` lines are parsed as thematic breaks; never
        // draw those rules for front-matter fences (editing or collapsed).
        for fenceLine in fm.fenceLineRanges {
            attrs.append((fenceLine, [.thematicBreak: false]))
        }

        let editing = NSLocationInRange(ctx.caretLocation, fm.range)
            || ctx.caretLocation == NSMaxRange(fm.range)
        if editing {
            // Reveal the raw YAML, muting the `---` fences so they read as syntax.
            for fenceLine in fm.fenceLineRanges {
                attrs.append((fenceLine, [.foregroundColor: ctx.configuration.theme.mutedText]))
            }
            return attrs
        }

        // Collapse every front-matter line to a 1pt, invisible sliver.
        let collapsed = NSMutableParagraphStyle()
        collapsed.minimumLineHeight = 1
        collapsed.maximumLineHeight = 1
        collapsed.lineSpacing = 0
        collapsed.paragraphSpacing = 0
        collapsed.paragraphSpacingBefore = 0
        ctx.nsText.enumerateSubstrings(in: fm.range, options: .byParagraphs) { _, _, enclosing, _ in
            attrs.append((enclosing, [.paragraphStyle: collapsed]))
        }
        attrs.append((fm.range, [
            .foregroundColor: NSColor.clear,
            .font: ctx.latexMarkerFont,
            .spellingState: 0
        ]))
        return attrs
    }

    struct FrontMatterRange {
        let range: NSRange
        /// The opening and closing `---` line ranges.
        let fenceLineRanges: [NSRange]
    }

    /// The leading `---` … `---` YAML front-matter block, if the document opens
    /// with one. Requires `---` on the very first line and a later `---` line.
    static func frontMatterRange(in text: NSString) -> FrontMatterRange? {
        guard text.length >= 3 else { return nil }
        let firstLine = text.lineRange(for: NSRange(location: 0, length: 0))
        guard isFenceLine(text.substring(with: firstLine)) else { return nil }

        var lineStart = NSMaxRange(firstLine)
        while lineStart < text.length {
            let line = text.lineRange(for: NSRange(location: lineStart, length: 0))
            if isFenceLine(text.substring(with: line)) {
                let range = NSRange(location: 0, length: NSMaxRange(line))
                return FrontMatterRange(range: range, fenceLineRanges: [firstLine, line])
            }
            let next = NSMaxRange(line)
            if next <= lineStart { break }
            lineStart = next
        }
        return nil
    }

    private static func isFenceLine(_ line: String) -> Bool {
        line.trimmingCharacters(in: .whitespacesAndNewlines) == "---"
    }
}
