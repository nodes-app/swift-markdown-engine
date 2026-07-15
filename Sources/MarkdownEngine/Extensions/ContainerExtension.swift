//
//  ContainerExtension.swift
//  MarkdownEngine
//
//  Created by Luca Chen on 15.07.26.
//
//  `:::` fenced container as the first block extension. Not registered by
//  default — the core engine parses pure markdown; embedders opt in via:
//
//      configuration.extensions = [ContainerExtension()]
//
//  Syntax:
//
//      ::: note
//      Body text with **inline** markdown.
//      :::
//
//  The fence lines hide while the caret is outside the block and reveal
//  muted while editing (mirroring code fences); the body keeps full inline
//  styling plus the container background. An unclosed container runs to the end
//  of the document, exactly like an unclosed code fence.
//

import AppKit
import Foundation

public struct ContainerExtension: MarkdownExtension {

    /// Well-known id.
    public static let identifier = "container"

    /// Background tint applied to the container block.
    public var backgroundColor: NSColor

    /// The default resolves per appearance: `withAlphaComponent` on a dynamic
    /// system color FREEZES it (same gotcha the table renderer documents), so
    /// the tint is rebuilt inside a dynamic provider and keeps tracking
    /// light/dark mode.
    public init(backgroundColor: NSColor = NSColor(name: nil) { appearance in
        var resolved = NSColor.systemBlue
        appearance.performAsCurrentDrawingAppearance {
            resolved = NSColor.systemBlue.usingColorSpace(.sRGB) ?? .systemBlue
        }
        return resolved.withAlphaComponent(0.12)
    }) {
        self.backgroundColor = backgroundColor
    }

    public var id: String { Self.identifier }

    public var block: BlockSyntax? {
        BlockSyntax(fence: ":::")
    }

    public func contentAttributes(theme: MarkdownEditorTheme) -> [NSAttributedString.Key: Any] {
        [.backgroundColor: backgroundColor]
    }

    public func html(childrenHTML: String) -> String {
        "<blockquote>\(childrenHTML)</blockquote>"
    }
}
