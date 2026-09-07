#if os(macOS)
//
//  SwiftMathBridge.swift
//  MarkdownEngineLatex
//
//  Ready-made LatexRenderer conformance backed by SwiftMath.
//

import AppKit
import Foundation
import CryptoKit
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

    /// On-disk mirror of the render cache. The in-memory cache dies with the
    /// process, so the ~450ms cold render of a formula-heavy note used to recur on
    /// the FIRST open of every session. Persisting keeps it cold only on the very
    /// first render ever (per formula); every later launch loads the PNG from disk
    /// (~0.3ms) instead of typesetting (~2ms). Lives in the app's Caches dir, which
    /// the OS may purge under pressure — a purge just re-renders, so it is safe.
    private lazy var diskCacheDir: URL? = {
        guard let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
        else { return nil }
        let dir = base.appendingPathComponent("MarkdownEngineLatex", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    /// Reused across renders: `MTMathUILabel()` adds an errorLabel subview on every
    /// init, so a fresh label per formula doubles the per-formula label overhead.
    /// render() is main-thread-only (it reads NSApp), so a single shared label is safe.
    private lazy var reusableLabel = MTMathUILabel()

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
        // The disk mirror is keyed by appearance/theme/font, so a flip already
        // maps to different keys; but an explicit clearCache() means "forget
        // everything", so drop the disk mirror too.
        if let dir = diskCacheDir {
            try? FileManager.default.removeItem(at: dir)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
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

        // Disk mirror: a hit here skips the ~2ms typeset for a ~0.3ms PNG load.
        if let entry = loadFromDisk(key: key) {
            cacheLock.lock()
            cache[key] = entry
            cacheLock.unlock()
            return LatexRenderResult(image: entry.image, size: entry.size,
                                     baselineOffset: entry.baselineOffset)
        }

        guard let entry = renderLatex(normalizedLatex, fontSize: fontSize, textColor: textColor) else {
            return nil
        }

        cacheLock.lock()
        cache[key] = entry
        cacheLock.unlock()
        saveToDisk(key: key, entry: entry)

        return LatexRenderResult(
            image: entry.image,
            size: entry.size,
            baselineOffset: entry.baselineOffset
        )
    }

    // MARK: - Disk cache

    /// Stable filename for a cache key: SHA-256 of the fingerprinting fields, hex.
    private func diskFilename(for key: CacheKey) -> String {
        let composite = "\(key.latex)|\(key.fontSize)|\(key.isDarkMode)|\(key.lightColorRGB)|\(key.darkColorRGB)"
        let digest = SHA256.hash(data: Data(composite.utf8))
        return digest.map { String(format: "%02x", $0) }.joined() + ".mathcache"
    }

    /// Persisted form: PNG pixels + the point-size and baseline the layout needs
    /// (PNG carries pixels only, not the point size or baseline, so they are stored
    /// alongside). Reconstructed image is byte-identical in appearance (PNG lossless).
    private func loadFromDisk(key: CacheKey) -> CacheEntry? {
        guard let dir = diskCacheDir else { return nil }
        let url = dir.appendingPathComponent(diskFilename(for: key))
        guard let data = try? Data(contentsOf: url),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let png = plist["png"] as? Data,
              let w = plist["w"] as? Double, let h = plist["h"] as? Double,
              let baseline = plist["b"] as? Double,
              let rep = NSBitmapImageRep(data: png) else {
            return nil
        }
        let size = CGSize(width: w, height: h)
        rep.size = size
        let image = NSImage(size: size)
        image.addRepresentation(rep)
        return CacheEntry(image: image, size: size, baselineOffset: CGFloat(baseline))
    }

    private func saveToDisk(key: CacheKey, entry: CacheEntry) {
        guard let dir = diskCacheDir,
              let rep = entry.image.representations.first as? NSBitmapImageRep,
              let png = rep.representation(using: .png, properties: [:]) else { return }
        let plist: [String: Any] = [
            "png": png, "w": Double(entry.size.width), "h": Double(entry.size.height),
            "b": Double(entry.baselineOffset)
        ]
        guard let data = try? PropertyListSerialization.data(fromPropertyList: plist, format: .binary, options: 0)
        else { return }
        try? data.write(to: dir.appendingPathComponent(diskFilename(for: key)), options: .atomic)
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
        // Reused instance (see `reusableLabel`); every property is set below so no
        // stale state carries between formulas.
        let mathLabel = reusableLabel
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
        let canvasHeight = exactHeight + paddingBottom

        // `displayList.width` is the advance width, which excludes the right-side ink
        // overhang of slanted glyphs (V, Y, P, F, …) — cropping to it clips them.
        // Render with right slack, then crop to the measured ink edge.
        let rightSlack = ceil(fontSize)
        let probeWidth = ceil(exactWidth) + rightSlack

        guard let probeRep = renderLabelToRep(mathLabel, size: CGSize(width: probeWidth, height: canvasHeight)),
              let probeCG = probeRep.cgImage else {
            return nil
        }

        let inkRight = Self.inkRightEdge(probeCG, widthInPoints: probeWidth) ?? exactWidth
        let finalWidth = max(ceil(exactWidth), ceil(inkRight))
        let finalSize = CGSize(width: finalWidth, height: canvasHeight)

        // Crop to the measured width (full height kept); points→pixels via the rep,
        // so this is correct at any backing scale.
        let pxPerPoint = CGFloat(probeCG.width) / probeWidth
        let cropPx = min(probeCG.width, Int((finalWidth * pxPerPoint).rounded()))
        guard cropPx > 0,
              let croppedCG = probeCG.cropping(to: CGRect(x: 0, y: 0, width: cropPx, height: probeCG.height)) else {
            return nil
        }

        let finalRep = NSBitmapImageRep(cgImage: croppedCG)
        finalRep.size = finalSize
        let image = NSImage(size: finalSize)
        image.addRepresentation(finalRep)

        return CacheEntry(
            image: image,
            size: finalSize,
            baselineOffset: displayList.descent
        )
    }

    private func renderLabelToRep(_ label: MTMathUILabel, size: CGSize) -> NSBitmapImageRep? {
        // `bitmapImageRepForCachingDisplay` + `cacheDisplay(in:to:)` is the
        // documented way to snapshot an NSView that isn't in a window. Setting
        // `wantsLayer = true` and `layer.render(in:)` snapshots the (empty)
        // backing layer instead of triggering MTMathUILabel's `draw(_:)`.
        label.frame = CGRect(origin: .zero, size: size)
        label.layoutSubtreeIfNeeded()

        guard let rep = label.bitmapImageRepForCachingDisplay(in: label.bounds) else { return nil }
        label.cacheDisplay(in: label.bounds, to: rep)
        return rep
    }

    /// Right-most x (in points) containing non-transparent ink, or `nil` if empty —
    /// lets us crop a formula to its true ink width instead of the advance width.
    private static func inkRightEdge(_ image: CGImage, widthInPoints: CGFloat) -> CGFloat? {
        let w = image.width
        let h = image.height
        guard w > 0, h > 0, widthInPoints > 0 else { return nil }

        let bytesPerRow = w * 4
        var data = [UInt8](repeating: 0, count: bytesPerRow * h)
        guard let cs = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(
                data: &data, width: w, height: h, bitsPerComponent: 8,
                bytesPerRow: bytesPerRow, space: cs,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else {
            return nil
        }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))

        // Scan each row from the right, stopping once we pass the running max.
        var maxX = -1
        for y in 0..<h {
            let row = y * bytesPerRow
            var x = w - 1
            while x > maxX {
                if data[row + x * 4 + 3] > 10 { maxX = x; break }
                x -= 1
            }
        }
        guard maxX >= 0 else { return nil }

        // +1: pixel `maxX` spans [maxX, maxX+1). Convert to points.
        return (CGFloat(maxX) + 1) * widthInPoints / CGFloat(w)
    }
}
#endif
