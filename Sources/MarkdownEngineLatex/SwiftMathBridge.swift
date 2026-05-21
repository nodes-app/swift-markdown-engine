//
//  SwiftMathBridge.swift
//  MarkdownEngineLatex
//
//  Ready-made LatexRenderer conformance backed by SwiftMath.
//

#if os(macOS)
import AppKit
import Foundation
import SwiftMath
import MarkdownEngine

/// A drop-in ``LatexRenderer`` backed by [SwiftMath].
///
/// Renders both block (`$$ … $$`) and inline (`$ … $`) LaTeX strings into
/// `NSImage`s using the Latin Modern math font. Results are cached per
/// (latex, font size, appearance, theme color fingerprint) so repeated
/// renders are free.
///
/// Light/dark appearance is taken from the host editor's window
/// effective appearance, not from `NSApp.effectiveAppearance`, so apps
/// that force a light window when the system is in dark mode still get
/// correctly-tinted formulas.
///
/// [SwiftMath]: https://github.com/mgriebling/SwiftMath
public final class SwiftMathBridge: LatexRenderer, @unchecked Sendable {
    private struct CacheKey: Hashable {
        let latex: String
        let fontSize: CGFloat
        let isDarkMode: Bool
        let lightColorRGB: UInt32
        let darkColorRGB: UInt32
    }

    private struct CacheEntry {
        let image: NSImage
        let size: CGSize
        let baselineOffset: CGFloat
    }

    private let singleLetterPaddingBottom: CGFloat
    private var cache: [CacheKey: CacheEntry] = [:]
    private let cacheLock = NSLock()

    /// - Parameter singleLetterPaddingBottom: Extra bottom padding (in
    ///   points) added to single-letter formulas to prevent visual
    ///   clipping; matches the engine's
    ///   ``MarkdownEditorConfiguration/blockLatex/singleLetterPaddingBottom``
    ///   default. Override to match a customized configuration.
    public init(singleLetterPaddingBottom: CGFloat = 1.0) {
        self.singleLetterPaddingBottom = singleLetterPaddingBottom
    }

    /// Clears the rendered-image cache. Call after appearance flips if
    /// the host code doesn't re-render formulas automatically.
    public func clearCache() {
        cacheLock.lock()
        cache.removeAll()
        cacheLock.unlock()
    }

    // MARK: - LatexRenderer

    public func render(
        latex: String,
        fontSize: CGFloat,
        theme: MarkdownEditorTheme
    ) -> LatexRenderResult? {
        let normalizedLatex = latex.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedLatex.isEmpty else { return nil }

        let appearance = NSApp.keyWindow?.effectiveAppearance ?? NSApp.effectiveAppearance
        let isDarkMode = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let textColor = isDarkMode ? theme.latexDarkModeText : theme.latexLightModeText
        let key = CacheKey(
            latex: normalizedLatex,
            fontSize: fontSize,
            isDarkMode: isDarkMode,
            lightColorRGB: Self.colorFingerprint(theme.latexLightModeText),
            darkColorRGB: Self.colorFingerprint(theme.latexDarkModeText)
        )

        cacheLock.lock()
        if let cached = cache[key] {
            cacheLock.unlock()
            return LatexRenderResult(
                image: cached.image,
                size: cached.size,
                baselineOffset: cached.baselineOffset
            )
        }
        cacheLock.unlock()

        guard let entry = renderLatex(normalizedLatex, fontSize: fontSize, textColor: textColor) else {
            return nil
        }

        cacheLock.lock()
        cache[key] = entry
        cacheLock.unlock()

        return LatexRenderResult(
            image: entry.image,
            size: entry.size,
            baselineOffset: entry.baselineOffset
        )
    }

    // MARK: - Private

    /// Fold an `NSColor` to a 24-bit fingerprint that's good enough to
    /// bust the cache when the theme changes the LaTeX text color.
    private static func colorFingerprint(_ color: NSColor) -> UInt32 {
        guard let rgb = color.usingColorSpace(.deviceRGB) else { return 0 }
        let r = UInt32(max(0, min(255, Int(rgb.redComponent * 255))))
        let g = UInt32(max(0, min(255, Int(rgb.greenComponent * 255))))
        let b = UInt32(max(0, min(255, Int(rgb.blueComponent * 255))))
        return (r << 16) | (g << 8) | b
    }

    private func renderLatex(_ latex: String, fontSize: CGFloat, textColor: NSColor) -> CacheEntry? {
        let mathLabel = MTMathUILabel()
        mathLabel.latex = latex
        mathLabel.fontSize = fontSize
        mathLabel.textColor = textColor
        mathLabel.textAlignment = .left
        mathLabel.labelMode = .text

        // Latin Modern Math gives the cleanest LaTeX glyphs at typical sizes.
        if let mathFont = MTFontManager().font(withName: "latinmodern-math", size: fontSize) {
            mathLabel.font = mathFont
        }

        mathLabel.layoutSubtreeIfNeeded()

        guard let displayList = mathLabel.displayList else { return nil }

        // SwiftMath skips unsupported glyphs (e.g. emoji/raw Greek), which can yield
        // zero-sized output. Bail instead of trying to render a 0x0 image — lockFocus
        // (used internally by NSImage drawing) crashes on zero dimensions.
        let exactWidth = displayList.width
        let exactHeight = displayList.ascent + displayList.descent
        guard exactWidth > 0, exactHeight > 0 else { return nil }

        let isSimpleSingleLetter = latex.range(of: #"^[A-Za-z]{1,3}$"#, options: .regularExpression) != nil
        let paddingBottom: CGFloat = isSimpleSingleLetter ? singleLetterPaddingBottom : 0

        let frameSize = CGSize(
            width: ceil(exactWidth),
            height: exactHeight + paddingBottom
        )
        mathLabel.frame = CGRect(origin: .zero, size: frameSize)

        guard let image = renderLabelToImage(mathLabel, size: frameSize) else {
            return nil
        }

        return CacheEntry(
            image: image,
            size: frameSize,
            baselineOffset: displayList.descent
        )
    }

    private func renderLabelToImage(_ label: MTMathUILabel, size: CGSize) -> NSImage? {
        // `bitmapImageRepForCachingDisplay` + `cacheDisplay(in:to:)` is the
        // documented way to snapshot an NSView that isn't in a window. Setting
        // `wantsLayer = true` and `layer.render(in:)` snapshots the (empty)
        // backing layer instead of triggering MTMathUILabel's `draw(_:)`.
        label.frame = CGRect(origin: .zero, size: size)
        label.layoutSubtreeIfNeeded()

        let image = NSImage(size: size)
        if let rep = label.bitmapImageRepForCachingDisplay(in: label.bounds) {
            label.cacheDisplay(in: label.bounds, to: rep)
            image.addRepresentation(rep)
        }
        return image
    }
}
#endif
