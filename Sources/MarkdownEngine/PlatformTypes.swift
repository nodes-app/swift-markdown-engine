//
//  PlatformTypes.swift
//  MarkdownEngine
//
//  Platform type aliases and shared abstractions that let the styling engine
//  compile on both macOS (AppKit) and iOS (UIKit).
//

#if os(macOS)
import AppKit
public typealias PlatformColor = NSColor
public typealias PlatformFont  = NSFont
public typealias PlatformImage = NSImage
#else
import UIKit
public typealias PlatformColor = UIColor
public typealias PlatformFont  = UIFont
public typealias PlatformImage = UIImage
#endif

// MARK: - Font helpers

extension PlatformFont {
    static func markdownFont(name: String, size: CGFloat) -> PlatformFont {
        PlatformFont(name: name, size: size) ?? .systemFont(ofSize: size)
    }

    static func markdownMonospaced(size: CGFloat) -> PlatformFont {
        .monospacedSystemFont(ofSize: size, weight: .regular)
    }

    func markdownBold() -> PlatformFont {
        #if os(macOS)
        let desc = fontDescriptor.withSymbolicTraits(.bold)
        return NSFont(descriptor: desc, size: pointSize)
            ?? NSFontManager.shared.convert(self, toHaveTrait: .boldFontMask)
        #else
        if let desc = fontDescriptor.withSymbolicTraits(.traitBold) {
            return UIFont(descriptor: desc, size: pointSize)
        }
        return self
        #endif
    }

    func markdownItalic() -> PlatformFont {
        #if os(macOS)
        let desc = fontDescriptor.withSymbolicTraits(.italic)
        return NSFont(descriptor: desc, size: pointSize)
            ?? NSFontManager.shared.convert(self, toHaveTrait: .italicFontMask)
        #else
        if let desc = fontDescriptor.withSymbolicTraits(.traitItalic) {
            return UIFont(descriptor: desc, size: pointSize)
        }
        return self
        #endif
    }

    func markdownBoldItalic() -> PlatformFont {
        #if os(macOS)
        let desc = fontDescriptor.withSymbolicTraits([.bold, .italic])
        return NSFont(descriptor: desc, size: pointSize)
            ?? NSFontManager.shared.convert(self, toHaveTrait: [.boldFontMask, .italicFontMask])
        #else
        if let desc = fontDescriptor.withSymbolicTraits([.traitBold, .traitItalic]) {
            return UIFont(descriptor: desc, size: pointSize)
        }
        return self
        #endif
    }

    /// Bold variant of a named font at a specific size (heading-aware).
    static func markdownBold(name: String, size: CGFloat) -> PlatformFont {
        markdownFont(name: name, size: size).markdownBold()
    }
}

// MARK: - Color helpers

extension PlatformColor {
    /// System label color, adapts to light/dark mode on both platforms.
    public static var markdownLabel: PlatformColor {
        #if os(macOS)
        .labelColor
        #else
        .label
        #endif
    }

    public static var markdownSecondaryLabel: PlatformColor {
        #if os(macOS)
        .secondaryLabelColor
        #else
        .secondaryLabel
        #endif
    }

    public static var markdownTertiaryLabel: PlatformColor {
        #if os(macOS)
        .tertiaryLabelColor
        #else
        .tertiaryLabel
        #endif
    }

    public static var markdownLink: PlatformColor {
        #if os(macOS)
        .linkColor
        #else
        .link
        #endif
    }

    public static var markdownTextBackground: PlatformColor {
        #if os(macOS)
        .textBackgroundColor.withAlphaComponent(0)
        #else
        .systemBackground.withAlphaComponent(0)
        #endif
    }
}

// MARK: - Text view abstraction

/// Minimal protocol implemented by both NSTextView (macOS) and UITextView (iOS)
/// so the styling layer can restyle either without AppKit-specific imports.
protocol MarkdownTextViewProtocol: AnyObject {
    var markdownTextStorage: NSTextStorage? { get }
    var typingAttributes: [NSAttributedString.Key: Any] { get set }
    var markdownString: String { get }
    var markdownSelectedRange: NSRange { get }
    func markdownInvalidateDisplay()
}

#if os(macOS)
extension NSTextView: MarkdownTextViewProtocol {
    var markdownTextStorage: NSTextStorage? { textStorage }
    var markdownString: String { string }
    var markdownSelectedRange: NSRange { selectedRange() }
    func markdownInvalidateDisplay() { setNeedsDisplay(visibleRect) }
}
#endif
