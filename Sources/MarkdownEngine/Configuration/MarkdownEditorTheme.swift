//
//  MarkdownEditorTheme.swift
//  MarkdownEngine
//
//  Color palette for the Markdown editor engine.
//

import Foundation

public struct MarkdownEditorTheme: Sendable {

    public var bodyText: PlatformColor
    public var mutedText: PlatformColor
    public var disabledText: PlatformColor
    public var headingMarker: PlatformColor
    public var link: PlatformColor
    public var incompleteLink: PlatformColor
    public var findMatchHighlight: PlatformColor
    public var findCurrentMatchHighlight: PlatformColor
    public var latexLightModeText: PlatformColor
    public var latexDarkModeText: PlatformColor
    public var strikethroughColor: PlatformColor

    public init(
        bodyText: PlatformColor = .markdownLabel,
        mutedText: PlatformColor = .markdownSecondaryLabel,
        disabledText: PlatformColor = .markdownTertiaryLabel,
        headingMarker: PlatformColor = .gray,
        link: PlatformColor = .markdownLink,
        incompleteLink: PlatformColor = .systemBlue,
        findMatchHighlight: PlatformColor = .systemYellow,
        findCurrentMatchHighlight: PlatformColor = .systemYellow,
        latexLightModeText: PlatformColor = .black,
        latexDarkModeText: PlatformColor = .white,
        strikethroughColor: PlatformColor = .markdownLabel
    ) {
        self.bodyText = bodyText
        self.mutedText = mutedText
        self.disabledText = disabledText
        self.headingMarker = headingMarker
        self.link = link
        self.incompleteLink = incompleteLink
        self.findMatchHighlight = findMatchHighlight
        self.findCurrentMatchHighlight = findCurrentMatchHighlight
        self.latexLightModeText = latexLightModeText
        self.latexDarkModeText = latexDarkModeText
        self.strikethroughColor = strikethroughColor
    }

    public static let `default` = MarkdownEditorTheme()
}
