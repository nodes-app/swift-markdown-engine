#if os(macOS)
//
//  InvertedIBeamCursor.swift
//  MarkdownEngine
//
//  Created by Luca Chen on 30.07.26.
//
//  The system I-beam is one appearance-independent glyph — a dark core inside a
//  light halo — and macOS inverts it against the EDITOR's backdrop, not against
//  the run under the pointer. Over a span that inverts (dark ink on a light
//  block) both of the glyph's colors are then wrong: in a dark editor the
//  inverted core is the block's own color and the pointer vanishes inside it.
//
//  So recolor, don't redraw: the live `NSCursor.iBeam` image is re-tinted core →
//  the span's ink, halo → the span's block. Deriving from the live image keeps
//  the system's shape and the user's pointer size (Accessibility ▸ Pointer)
//  instead of hand-drawing a cursor that ignores both.
//

import AppKit

enum InvertedIBeamCursor {

    private static var cache: [Key: NSCursor] = [:]

    private struct Key: Hashable {
        let ink: String
        let halo: String
    }

    /// I-beam whose core is `ink` and whose halo is `block`. Cached: recoloring
    /// walks every representation's pixels (~65k across 1x–10x), which is fine
    /// once per color pair and far too slow per mouse-move.
    static func cursor(ink: NSColor, block: NSColor) -> NSCursor? {
        let key = Key(ink: descriptor(ink), halo: descriptor(block))
        if let cached = cache[key] { return cached }
        let system = NSCursor.iBeam
        guard let recolored = recolor(system.image, ink: ink, block: block) else { return nil }
        let cursor = NSCursor(image: recolored, hotSpot: system.hotSpot)
        cache[key] = cursor
        return cursor
    }

    /// Identity for the cache key — two dynamic colors that resolve the same
    /// today must share an entry, so key on the resolved components.
    private static func descriptor(_ color: NSColor) -> String {
        guard let rgb = color.usingColorSpace(.deviceRGB) else { return color.description }
        return "\(rgb.redComponent),\(rgb.greenComponent),\(rgb.blueComponent),\(rgb.alphaComponent)"
    }

    private static func recolor(_ image: NSImage, ink: NSColor, block: NSColor) -> NSImage? {
        guard let inkRGB = ink.usingColorSpace(.deviceRGB),
              let blockRGB = block.usingColorSpace(.deviceRGB) else { return nil }
        let inkBytes = bytes(of: inkRGB), blockBytes = bytes(of: blockRGB)
        let out = NSImage(size: image.size)
        var added = false
        for case let source as NSBitmapImageRep in image.representations {
            let width = source.pixelsWide, height = source.pixelsHigh
            // Redraw into a known format first (straight alpha, 8-bit RGBA) —
            // the system reps' own layout is not guaranteed, and per-pixel
            // NSColor round-trips cost 1.3 s across the 1x–10x reps.
            guard let target = NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: width * 4, bitsPerPixel: 32
            ), let context = NSGraphicsContext(bitmapImageRep: target) else { continue }
            target.size = source.size
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = context
            source.draw(in: NSRect(x: 0, y: 0, width: width, height: height))
            NSGraphicsContext.restoreGraphicsState()
            guard let data = target.bitmapData else { continue }
            for pixel in stride(from: 0, to: width * height * 4, by: 4) {
                // CoreGraphics only fills a PREMULTIPLIED buffer, so undo that
                // before judging the color and redo it when writing back.
                let alpha = Double(data[pixel + 3]) / 255
                guard alpha > 0 else { continue }                        // transparent: leave it
                // Split on the glyph's own luminance: the dark core carries the
                // shape, the light halo carries it against a dark page.
                let luminance = (0.299 * Double(data[pixel])
                    + 0.587 * Double(data[pixel + 1])
                    + 0.114 * Double(data[pixel + 2])) / (255 * alpha)
                let replacement = luminance < 0.5 ? inkBytes : blockBytes
                data[pixel] = UInt8(clamping: Int(Double(replacement.0) * alpha))
                data[pixel + 1] = UInt8(clamping: Int(Double(replacement.1) * alpha))
                data[pixel + 2] = UInt8(clamping: Int(Double(replacement.2) * alpha))
            }
            out.addRepresentation(target)
            added = true
        }
        return added ? out : nil
    }

    private static func bytes(of color: NSColor) -> (UInt8, UInt8, UInt8) {
        (UInt8(clamping: Int(color.redComponent * 255)),
         UInt8(clamping: Int(color.greenComponent * 255)),
         UInt8(clamping: Int(color.blueComponent * 255)))
    }
}
#endif
