//
//  PasteboardImageReader.swift
//  MarkdownEngine
//
//  Created by Luca Chen on 16.03.26.
//
//  Pasteboard inspection helpers used to detect and extract images
//  from paste / drop events into the editor.
//

import AppKit
import UniformTypeIdentifiers

/// Helpers for reading images out of an `NSPasteboard`.
///
/// Used internally when the user pastes into the editor and externally by
/// embedders that want to validate a pasteboard before invoking
/// ``NativeTextViewWrapper/onPasteImage``.
public enum PasteboardImageReader {
    /// Returns `true` when the pasteboard carries either an image file URL
    /// or raw image data the engine can decode.
    public static func canPasteImage(from pasteboard: NSPasteboard) -> Bool {
        imageFileURL(from: pasteboard) != nil || imageData(from: pasteboard) != nil
    }

    /// First file URL on the pasteboard whose extension maps to an image
    /// `UTType`, or `nil` if no such URL is present.
    public static func imageFileURL(from pasteboard: NSPasteboard) -> URL? {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [
            .urlReadingFileURLsOnly: true
        ]
        guard let objects = pasteboard.readObjects(forClasses: [NSURL.self], options: options) as? [URL] else {
            return nil
        }

        return objects.first(where: { url in
            guard let type = UTType(filenameExtension: url.pathExtension) else { return false }
            return type.conforms(to: .image)
        })
    }

    /// PNG-encoded image data extracted from the pasteboard, or `nil` when
    /// no decodable image is available.
    ///
    /// Tries `.png`, then `.tiff`, then any registered `NSImage` initializer,
    /// then falls back to scanning every type the pasteboard advertises.
    public static func imageData(from pasteboard: NSPasteboard) -> Data? {
        if let pngData = pasteboard.data(forType: .png), !pngData.isEmpty {
            return pngData
        }

        if let tiffData = pasteboard.data(forType: .tiff),
           let bitmapRep = NSBitmapImageRep(data: tiffData),
           let pngData = bitmapRep.representation(using: .png, properties: [:]) {
            return pngData
        }

        if let images = pasteboard.readObjects(forClasses: [NSImage.self], options: nil) as? [NSImage],
           let image = images.first,
           let pngData = pngData(from: image) {
            return pngData
        }

        for type in pasteboard.types ?? [] where type != .png && type != .tiff {
            guard let data = pasteboard.data(forType: type),
                  !data.isEmpty,
                  let image = NSImage(data: data),
                  let pngData = pngData(from: image) else {
                continue
            }
            return pngData
        }

        guard let image = NSImage(pasteboard: pasteboard) else {
            return nil
        }
        return pngData(from: image)
    }

    private static func pngData(from image: NSImage) -> Data? {
        if let tiffData = image.tiffRepresentation,
           let bitmapRep = NSBitmapImageRep(data: tiffData),
           let pngData = bitmapRep.representation(using: .png, properties: [:]) {
            return pngData
        }

        var proposedRect = NSRect(origin: .zero, size: image.size)
        guard let cgImage = image.cgImage(forProposedRect: &proposedRect, context: nil, hints: nil) else {
            return nil
        }
        let bitmapRep = NSBitmapImageRep(cgImage: cgImage)
        return bitmapRep.representation(using: .png, properties: [:])
    }
}
