//
//  EmbeddedImageCache.swift
//  MarkdownEngine
//
//  Created by Luca Chen on 16.03.26.
//

import AppKit
import CoreGraphics

/// Parsed `![[name|optional-id|optional-width]]` reference.
public struct ImageEmbedReference: Sendable {
    private static let markdownRegex = try! NSRegularExpression(
        pattern: "!\\[\\[([^\\]\\r\\n]*)\\]\\]"
    )

    public let name: String
    public let nodeID: UUID?
    public let requestedWidth: CGFloat?

    public init(name: String, nodeID: UUID? = nil, requestedWidth: CGFloat? = nil) {
        self.name = name
        self.nodeID = nodeID
        self.requestedWidth = requestedWidth
    }

    public init?(content: String) {
        let parts = content
            .split(separator: "|", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }

        guard let name = parts.first, !name.isEmpty else { return nil }

        var parsedID: UUID?
        var parsedWidth: CGFloat?

        for part in parts.dropFirst() where !part.isEmpty {
            if parsedID == nil, let id = UUID(uuidString: part) {
                parsedID = id
                continue
            }
            if parsedWidth == nil, let value = Double(part), value > 0 {
                parsedWidth = CGFloat(value)
            }
        }

        self.init(name: name, nodeID: parsedID, requestedWidth: parsedWidth)
    }

    public static func parse(markdown: String) -> ImageEmbedReference? {
        guard markdown.hasPrefix("![["), markdown.hasSuffix("]]") else { return nil }
        return ImageEmbedReference(content: String(markdown.dropFirst(3).dropLast(2)))
    }

    public static func replacingEmbeds(
        in text: String,
        transform: (ImageEmbedReference) -> String
    ) -> String {
        let nsText = text as NSString
        let fullRange = NSRange(location: 0, length: nsText.length)
        let mutable = NSMutableString(string: text)
        let matches = markdownRegex.matches(in: text, range: fullRange).reversed()

        for match in matches {
            let rawContent = nsText.substring(with: match.range(at: 1))
            guard let reference = ImageEmbedReference(content: rawContent) else { continue }
            mutable.replaceCharacters(in: match.range, with: transform(reference))
        }

        return mutable as String
    }

    public var markdown: String {
        var parts = [name]
        if let nodeID {
            parts.append(nodeID.uuidString)
        }
        if let requestedWidth, requestedWidth > 0 {
            let widthValue = Double(requestedWidth)
            parts.append(widthValue.rounded() == widthValue ? String(Int(widthValue)) : String(widthValue))
        }
        return "![[\(parts.joined(separator: "|"))]]"
    }

    /// Convert to the engine-side request shape consumed by `EmbeddedImageProvider`.
    public var providerRequest: EmbeddedImageRequest {
        EmbeddedImageRequest(
            name: name,
            id: nodeID?.uuidString,
            requestedWidth: requestedWidth
        )
    }
}

/// Caches images returned by an ``EmbeddedImageProvider``. The cache
/// invalidates when the provider's fingerprint changes, so the engine
/// stays correct even when the embedder swaps out its data source.
final class EmbeddedImageCache {
    static let shared = EmbeddedImageCache()
    private init() {}

    private var cache: [String: NSImage] = [:]
    private var lastFingerprint: AnyHashable?

    func image(for reference: ImageEmbedReference, services: MarkdownEditorServices) -> NSImage? {
        let currentFingerprint = services.images.fingerprint()
        if currentFingerprint != lastFingerprint {
            cache.removeAll()
            lastFingerprint = currentFingerprint
        }

        let cacheKey = reference.nodeID?.uuidString ?? reference.name
        if let cached = cache[cacheKey] {
            return cached
        }

        guard let image = services.images.image(for: reference.providerRequest) else {
            return nil
        }

        cache[cacheKey] = image
        return image
    }
}
