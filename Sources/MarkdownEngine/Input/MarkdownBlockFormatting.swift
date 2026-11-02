//
//  MarkdownBlockFormatting.swift
//  MarkdownEngine
//

import Foundation

struct MarkdownLinePrefixEdit {
    let range: NSRange
    let replacement: String
}

struct MarkdownBlockFormattingPlan {
    let range: NSRange
    let prefixEdits: [MarkdownLinePrefixEdit]
    let selection: NSRange
}

enum MarkdownBlockFormatting {
    private static let headingPrefix = try! NSRegularExpression(pattern: #"^([ \t]*)#{1,6}[ \t]+"#)
    private static let indentation = try! NSRegularExpression(pattern: #"^[ \t]*"#)
    private static let taskPrefix = try! NSRegularExpression(
        pattern: #"^((?:\d+\.|[-*+]))[ \t]+\[[ xX]\][ \t]+"#
    )
    private static let listPrefix = try! NSRegularExpression(pattern: #"^((?:\d+\.|[-*+]))[ \t]+"#)

    static func paragraphPlan(in text: String, selection: NSRange) -> MarkdownBlockFormattingPlan? {
        let document = text as NSString
        let lines = selectedLines(in: document, selection: selection)
        let edits = lines.compactMap { line -> MarkdownLinePrefixEdit? in
            let lineText = document.substring(with: line)
            let localRange = NSRange(location: 0, length: (lineText as NSString).length)
            guard let match = headingPrefix.firstMatch(in: lineText, range: localRange) else { return nil }
            let indentationRange = match.range(at: 1)
            let markerRange = NSRange(
                location: line.location + NSMaxRange(indentationRange),
                length: NSMaxRange(match.range) - NSMaxRange(indentationRange)
            )
            return MarkdownLinePrefixEdit(range: markerRange, replacement: "")
        }
        return plan(in: document, selection: selection, lines: lines, edits: edits)
    }

    static func taskListPlan(in text: String, selection: NSRange) -> MarkdownBlockFormattingPlan? {
        let document = text as NSString
        let lines = selectedLines(in: document, selection: selection)
        let lineDetails = lines.map { line -> (range: NSRange, indentationLength: Int, taskRange: NSRange?, listRange: NSRange?, listMarker: String?) in
            let lineText = document.substring(with: line) as NSString
            let fullRange = NSRange(location: 0, length: lineText.length)
            let indentationLength = indentation.firstMatch(in: lineText as String, range: fullRange)?.range.length ?? 0
            let content = lineText.substring(from: indentationLength) as NSString
            let contentRange = NSRange(location: 0, length: content.length)
            let task = taskPrefix.firstMatch(in: content as String, range: contentRange).map {
                NSRange(location: indentationLength + $0.range.location, length: $0.range.length)
            }
            let listMatch = listPrefix.firstMatch(in: content as String, range: contentRange)
            let list = listMatch.map {
                NSRange(location: indentationLength + $0.range.location, length: $0.range.length)
            }
            let marker = listMatch.map { content.substring(with: $0.range(at: 1)) }
            return (line, indentationLength, task, list, marker)
        }
        let removeTaskPrefixes = lineDetails.allSatisfy { $0.taskRange != nil }
        let edits = lineDetails.compactMap { line -> MarkdownLinePrefixEdit? in
            if removeTaskPrefixes, let taskRange = line.taskRange {
                return MarkdownLinePrefixEdit(
                    range: NSRange(location: line.range.location + taskRange.location, length: taskRange.length),
                    replacement: ""
                )
            }
            if line.taskRange != nil { return nil }
            if let listRange = line.listRange, let marker = line.listMarker {
                return MarkdownLinePrefixEdit(
                    range: NSRange(location: line.range.location + listRange.location, length: listRange.length),
                    replacement: "\(marker) [ ] "
                )
            }
            return MarkdownLinePrefixEdit(
                range: NSRange(location: line.range.location + line.indentationLength, length: 0),
                replacement: "- [ ] "
            )
        }
        return plan(in: document, selection: selection, lines: lines, edits: edits)
    }

    private static func plan(
        in document: NSString,
        selection: NSRange,
        lines: [NSRange],
        edits: [MarkdownLinePrefixEdit]
    ) -> MarkdownBlockFormattingPlan? {
        guard edits.isEmpty == false, let first = lines.first, let last = lines.last else { return nil }
        let safeSelection = clamped(selection, length: document.length)
        let sortedEdits = edits.sorted { $0.range.location < $1.range.location }
        let start = transformedLocation(safeSelection.location, by: sortedEdits)
        let end = transformedLocation(NSMaxRange(safeSelection), by: sortedEdits)
        return MarkdownBlockFormattingPlan(
            range: NSRange(location: first.location, length: NSMaxRange(last) - first.location),
            prefixEdits: sortedEdits,
            selection: NSRange(location: start, length: max(0, end - start))
        )
    }

    private static func selectedLines(in document: NSString, selection: NSRange) -> [NSRange] {
        let safe = clamped(selection, length: document.length)
        let first = document.lineRange(for: NSRange(location: safe.location, length: 0))
        let lastLocation = safe.length > 0 ? NSMaxRange(safe) - 1 : safe.location
        let last = document.lineRange(for: NSRange(location: lastLocation, length: 0))
        let selectedRange = NSRange(location: first.location, length: NSMaxRange(last) - first.location)
        if selectedRange.length == 0 { return [selectedRange] }

        var lines: [NSRange] = []
        var location = selectedRange.location
        while location < NSMaxRange(selectedRange) {
            let line = document.lineRange(for: NSRange(location: location, length: 0))
            lines.append(line)
            let next = NSMaxRange(line)
            guard next > location else { break }
            location = next
        }
        return lines
    }

    private static func transformedLocation(_ location: Int, by edits: [MarkdownLinePrefixEdit]) -> Int {
        var offset = 0
        for edit in edits {
            if location < edit.range.location { break }
            if location <= NSMaxRange(edit.range) {
                return edit.range.location + offset + edit.replacement.utf16.count
            }
            offset += edit.replacement.utf16.count - edit.range.length
        }
        return location + offset
    }

    private static func clamped(_ range: NSRange, length: Int) -> NSRange {
        let location = min(max(0, range.location), length)
        return NSRange(location: location, length: min(max(0, range.length), length - location))
    }
}
