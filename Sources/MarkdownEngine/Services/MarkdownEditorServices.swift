//
//  MarkdownEditorServices.swift
//  MarkdownEngine
//
//  Protocols and default implementations for engine-side dependencies.
//

import Foundation

// MARK: - Wiki Links

public protocol WikiLinkResolver: Sendable {
    func resolve(displayName: String, range: NSRange) -> WikiLinkResolution?
}

public struct WikiLinkResolution: Sendable, Equatable {
    public let id: String
    public let exists: Bool
    public init(id: String, exists: Bool) { self.id = id; self.exists = exists }
}

public struct NoOpWikiLinkResolver: WikiLinkResolver {
    public init() {}
    public func resolve(displayName: String, range: NSRange) -> WikiLinkResolution? { nil }
}

// MARK: - Embedded Images

public protocol EmbeddedImageProvider: Sendable {
    func image(for reference: EmbeddedImageRequest) -> PlatformImage?
    func fingerprint() -> AnyHashable
}

public struct EmbeddedImageRequest: Sendable, Equatable {
    public let name: String
    public let id: String?
    public let requestedWidth: CGFloat?

    public init(name: String, id: String? = nil, requestedWidth: CGFloat? = nil) {
        self.name = name
        self.id = id
        self.requestedWidth = requestedWidth
    }
}

public struct NoOpEmbeddedImageProvider: EmbeddedImageProvider {
    public init() {}
    public func image(for reference: EmbeddedImageRequest) -> PlatformImage? { nil }
    public func fingerprint() -> AnyHashable { 0 }
}

// MARK: - Syntax Highlighting

public protocol SyntaxHighlighter: Sendable {
    func codeFont(size: CGFloat) -> PlatformFont
    func backgroundColor() -> PlatformColor
    func highlight(code: String, language: String?) -> NSAttributedString?
    var appearanceDidChangeNotification: Notification.Name? { get }
}

public struct PlainTextSyntaxHighlighter: SyntaxHighlighter {
    public init() {}

    public func codeFont(size: CGFloat) -> PlatformFont {
        .monospacedSystemFont(ofSize: size, weight: .regular)
    }

    public func backgroundColor() -> PlatformColor {
        .markdownTextBackground
    }

    public func highlight(code: String, language: String?) -> NSAttributedString? { nil }

    public var appearanceDidChangeNotification: Notification.Name? { nil }
}

// MARK: - LaTeX

public protocol LatexRenderer: Sendable {
    func render(latex: String, fontSize: CGFloat, theme: MarkdownEditorTheme) -> LatexRenderResult?
}

public struct LatexRenderResult: Sendable {
    public let image: PlatformImage
    public let size: CGSize
    public let baselineOffset: CGFloat

    public init(image: PlatformImage, size: CGSize, baselineOffset: CGFloat) {
        self.image = image
        self.size = size
        self.baselineOffset = baselineOffset
    }
}

public struct NoOpLatexRenderer: LatexRenderer {
    public init() {}
    public func render(latex: String, fontSize: CGFloat, theme: MarkdownEditorTheme) -> LatexRenderResult? { nil }
}

// MARK: - Event Bus

public struct MarkdownEditorBus: Sendable {
    public var applyBoldRequest: Notification.Name?
    public var applyItalicRequest: Notification.Name?
    public var applyHeadingRequest: Notification.Name?
    public var selectionBoldDidChange: Notification.Name?
    public var selectionItalicDidChange: Notification.Name?
    public var findScrollToRange: Notification.Name?
    public var findClearHighlights: Notification.Name?

    public init(
        applyBoldRequest: Notification.Name? = nil,
        applyItalicRequest: Notification.Name? = nil,
        applyHeadingRequest: Notification.Name? = nil,
        selectionBoldDidChange: Notification.Name? = nil,
        selectionItalicDidChange: Notification.Name? = nil,
        findScrollToRange: Notification.Name? = nil,
        findClearHighlights: Notification.Name? = nil
    ) {
        self.applyBoldRequest = applyBoldRequest
        self.applyItalicRequest = applyItalicRequest
        self.applyHeadingRequest = applyHeadingRequest
        self.selectionBoldDidChange = selectionBoldDidChange
        self.selectionItalicDidChange = selectionItalicDidChange
        self.findScrollToRange = findScrollToRange
        self.findClearHighlights = findClearHighlights
    }

    public static let `default` = MarkdownEditorBus()
}

// MARK: - Services Container

public struct MarkdownEditorServices: Sendable {
    public var wikiLinks: any WikiLinkResolver
    public var images: any EmbeddedImageProvider
    public var syntaxHighlighter: any SyntaxHighlighter
    public var latex: any LatexRenderer
    public var bus: MarkdownEditorBus

    public init(
        wikiLinks: any WikiLinkResolver = NoOpWikiLinkResolver(),
        images: any EmbeddedImageProvider = NoOpEmbeddedImageProvider(),
        syntaxHighlighter: any SyntaxHighlighter = PlainTextSyntaxHighlighter(),
        latex: any LatexRenderer = NoOpLatexRenderer(),
        bus: MarkdownEditorBus = .default
    ) {
        self.wikiLinks = wikiLinks
        self.images = images
        self.syntaxHighlighter = syntaxHighlighter
        self.latex = latex
        self.bus = bus
    }

    public static let `default` = MarkdownEditorServices()
}
