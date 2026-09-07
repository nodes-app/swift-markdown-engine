#if os(iOS)
import Foundation
import UIKit

/// Color palette used by the UIKit markdown editor.
public struct MarkdownEditorTheme: @unchecked Sendable {
    public var bodyText: UIColor
    public var mutedText: UIColor
    public var disabledText: UIColor
    public var headingMarker: UIColor
    public var link: UIColor
    public var codeBackground: UIColor
    public var quote: UIColor

    public init(
        bodyText: UIColor = .label,
        mutedText: UIColor = .secondaryLabel,
        disabledText: UIColor = .tertiaryLabel,
        headingMarker: UIColor = .secondaryLabel,
        link: UIColor = .link,
        codeBackground: UIColor = .secondarySystemBackground,
        quote: UIColor = .secondaryLabel
    ) {
        self.bodyText = bodyText
        self.mutedText = mutedText
        self.disabledText = disabledText
        self.headingMarker = headingMarker
        self.link = link
        self.codeBackground = codeBackground
        self.quote = quote
    }

    public static let `default` = MarkdownEditorTheme()
}

/// Margins inside the text view.
public struct TextInsets: Sendable {
    public var horizontal: CGFloat
    public var vertical: CGFloat

    public init(horizontal: CGFloat = 0, vertical: CGFloat = 0) {
        self.horizontal = horizontal
        self.vertical = vertical
    }

    public static let `default` = TextInsets()
}

/// UIKit editor configuration. Its defaults mirror the macOS editor's live-preview behavior.
public struct MarkdownEditorConfiguration: @unchecked Sendable {
    public enum HeightBehavior: Sendable {
        case scrolls
        case fitsContent
    }

    public var theme: MarkdownEditorTheme
    public var textInsets: TextInsets
    public var heightBehavior: HeightBehavior
    public var rawSourceMode: Bool

    public init(
        theme: MarkdownEditorTheme = .default,
        textInsets: TextInsets = .default,
        heightBehavior: HeightBehavior = .scrolls,
        rawSourceMode: Bool = false
    ) {
        self.theme = theme
        self.textInsets = textInsets
        self.heightBehavior = heightBehavior
        self.rawSourceMode = rawSourceMode
    }

    public static let `default` = MarkdownEditorConfiguration()
}
#endif
