//
//  NativeTextView+ClickRemap.swift
//  MarkdownEngine
//
//  Created by Luca Chen on 16.03.26.
//
//  Single-click hit-testing inside paragraph spacing: pick the closer of the
//  current fragment's last line vs. the next fragment's first line and place
//  the caret at a line-relative X within the chosen line.
//

import AppKit

extension NativeTextView {
    func remapClickInParagraphSpacing(event: NSEvent) -> Bool {
        guard event.clickCount == 1, !event.modifierFlags.contains(.shift),
              let tlm = textLayoutManager, let tcs = textContentStorage else {
            return false
        }
        let viewPoint = convert(event.locationInWindow, from: nil)
        let click = CGPoint(
            x: viewPoint.x - textContainerOrigin.x,
            y: viewPoint.y - textContainerOrigin.y
        )
        guard let fragment = tlm.textLayoutFragment(for: click),
              let lastLine = fragment.textLineFragments.last else {
            return false
        }
        let fragFrame = fragment.layoutFragmentFrame
        let lastLineMaxY = fragFrame.minY + lastLine.typographicBounds.maxY
        guard click.y > lastLineMaxY, click.y <= fragFrame.maxY else { return false }

        var nextFragment: NSTextLayoutFragment?
        tlm.enumerateTextLayoutFragments(
            from: fragment.rangeInElement.endLocation, options: [.ensuresLayout]
        ) { nextFragment = $0; return false }
        let nextFirst = nextFragment?.textLineFragments.first
        let nextTopY = nextFirst.map { nextFragment!.layoutFragmentFrame.minY + $0.typographicBounds.minY } ?? fragFrame.maxY
        let useLower = (nextTopY - click.y) < (click.y - lastLineMaxY) && nextFirst != nil
        let chosenFragment = useLower ? nextFragment! : fragment
        let chosenLine = useLower ? nextFirst! : lastLine
        let lineTypo = chosenLine.typographicBounds
        let lineLocal = CGPoint(
            x: click.x - chosenFragment.layoutFragmentFrame.minX - lineTypo.minX,
            y: lineTypo.midY - lineTypo.minY
        )
        let charIdx = chosenLine.characterIndex(for: lineLocal)
        let lineStart = chosenLine.characterRange.location
        let clampedInFrag = max(lineStart, min(lineStart + chosenLine.characterRange.length, charIdx))
        let fragStart = tcs.offset(from: tcs.documentRange.location, to: chosenFragment.rangeInElement.location)
        guard fragStart != NSNotFound else { return false }
        let docLen = (string as NSString).length
        window?.makeFirstResponder(self)
        setSelectedRange(NSRange(location: min(max(fragStart + clampedInFrag, 0), docLen), length: 0))
        return true
    }
}
