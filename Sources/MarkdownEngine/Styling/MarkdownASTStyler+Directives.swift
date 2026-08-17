//
//  MarkdownASTStyler+Directives.swift
//  MarkdownEngine
//
//  The styling half of the directive seam, in two parts.
//
//  A CONTAINER directive's body picks up the directive's style, and — the part
//  that matters — its font TRANSFORM composes over the font inherited at that
//  point in the tree. A SELF-CONTAINED call has no body to style; it draws a
//  glyph in place of its own source instead (see `presentSelfContained`).
//
//  That composition is why directives are tree-shaped. The styler already
//  threads a font down the walk (heading font → +bold → +italic); a directive
//  simply contributes another step, so every combination stacks instead of
//  overwriting:
//
//      # @font(size: 18){**bold** and *italic*}
//        └ heading font → 18pt → +bold / +italic
//
//  A "from here on" directive could not participate in that at all — it would
//  have to mutate state between siblings, which is exactly what the
//  compose-on-descent model has no place for.
//
//  Ranges all come from the parser. A directive supplies attributes and a font
//  transform; it never sees or emits geometry, so a misbehaving directive can
//  restyle its own body at worst.
//

import AppKit
import Foundation

extension MarkdownASTStyler {

    /// Style a directive node and return the font its body's children must
    /// inherit — or `nil` when `node` isn't a registered directive, in which
    /// case the caller falls through to ordinary extension-span handling.
    ///
    /// Self-contained calls return their inherited font unchanged: they have
    /// no body, and are handed to the glyph pass instead.
    static func directiveBodyFont(
        for node: ExtensionInlineNode,
        font: NSFont,
        ctx: Ctx,
        into attrs: inout [StyledRange]
    ) -> NSFont? {
        guard let directiveID = DirectiveRegistry.directiveID(forNodeID: node.extensionID) else { return nil }
        // Linear scan, not a dictionary build: registries hold a handful of
        // directives and this runs per directive NODE per restyle, so the
        // allocation would cost more than the scan. A directive unregistered
        // since the parse degrades to plain text rather than styling wrongly.
        guard let directive = ctx.config.directives.first(where: { $0.id == directiveID }) else { return nil }

        let marker = directive.syntax.marker ?? ctx.config.directiveSettings.defaultMarker
        let context = DirectiveContext(
            theme: ctx.theme,
            inheritedFont: font,
            isActive: ctx.isActive(node.range),
            marker: marker
        )

        // A self-contained call is the whole node — no body to style, but it
        // may draw a glyph in place of its collapsed source.
        guard !node.markers.isEmpty, node.contentRange.length > 0 else {
            let arguments = DirectiveArguments(
                parsing: DirectiveScanner.argumentsRange(inPrefix: node.range, of: ctx.ns),
                in: ctx.ns,
                schema: directive.syntax.parameters
            )
            presentSelfContained(
                directive.presentation(arguments: arguments, context: context),
                node: node, font: font, isActive: context.isActive, ctx: ctx, into: &attrs
            )
            return font
        }

        let arguments = DirectiveArguments(
            parsing: DirectiveScanner.argumentsRange(inPrefix: node.markers[0], of: ctx.ns),
            in: ctx.ns,
            schema: directive.syntax.parameters
        )
        let style = directive.style(arguments: arguments, context: context)
        let bodyFont = style.font.apply(to: font)

        if !style.attributes.isEmpty {
            attrs.append((node.contentRange, style.attributes))
        }
        // Emit the font even when the transform is a no-op: the body inherits
        // it explicitly, so a later pass can't leave part of the span on a
        // stale font.
        attrs.append((node.contentRange, [.font: bodyFont]))
        // Directive syntax is not prose — no spell-check underlines on it.
        for marker in node.markers { attrs.append((marker, [.spellingState: 0])) }
        return bodyFont
    }

    // MARK: - Self-contained presentation

    /// Draw a self-contained directive's glyph in place of its source.
    ///
    /// Mechanically identical to inline LaTeX
    /// (`MarkdownStyler+Latex.swift`): the source text is never removed — it
    /// collapses to zero width via clear colour, the shrunk marker font, and
    /// negative kern, while the FIRST character carries the image plus enough
    /// positive kern to occupy the glyph's width. `MarkdownTextLayoutFragment`
    /// draws it. Selection, find, copy, and undo all still see the real
    /// characters, which is what the "markers shrink, they don't disappear"
    /// invariant is protecting.
    ///
    /// With the caret inside, the source is revealed muted instead — the same
    /// flip every other construct performs.
    private static func presentSelfContained(
        _ presentation: DirectivePresentation,
        node: ExtensionInlineNode,
        font: NSFont,
        isActive: Bool,
        ctx: Ctx,
        into attrs: inout [StyledRange]
    ) {
        attrs.append((node.range, [.spellingState: 0]))

        guard !isActive else {
            attrs.append((node.range, [.foregroundColor: ctx.theme.mutedText]))
            return
        }

        let resolved: (image: NSImage, descent: CGFloat)?
        switch presentation {
        case .literal:
            resolved = nil
        case .symbol(let name, let tint):
            resolved = symbolImage(named: name, tint: tint, font: font).map { image in
                // Optically centre the glyph on the text's x-height:
                // `descent` is how far the image's bottom sits below the
                // baseline, so centring wants (height - xHeight) / 2.
                (image, (image.size.height - font.xHeight) / 2)
            }
        case .text(let string):
            // Text renders on the same image channel: substituting characters
            // into the storage would violate "the source is never removed".
            resolved = textImage(string, font: font).map { ($0, -font.descender) }
        case .image(let image, let baselineOffset):
            resolved = (image, baselineOffset)
        }

        // `.literal`, or a symbol name the system doesn't know: leave the
        // source visible rather than collapsing it to nothing.
        guard let resolved, node.range.length > 0 else { return }

        let markerFont = ctx.inlineMarkerFont
        let imageBounds = CGRect(x: 0, y: resolved.descent,
                                 width: resolved.image.size.width, height: resolved.image.size.height)

        let firstCharRange = NSRange(location: node.range.location, length: 1)
        let firstChar = ctx.ns.substring(with: firstCharRange)
        attrs.append((firstCharRange, [
            .latexImage: resolved.image,          // the engine's generic inline-image
            .latexBounds: NSValue(rect: imageBounds),   // channel; the name is historical
            .foregroundColor: NSColor.clear,
            .font: markerFont,
            .kern: resolved.image.size.width - HeadingHelpers.textWidth(firstChar, font: markerFont),
        ]))

        if node.range.length > 1 {
            let restRange = NSRange(location: node.range.location + 1, length: node.range.length - 1)
            let restText = ctx.ns.substring(with: restRange)
            attrs.append((restRange, [
                .foregroundColor: NSColor.clear,
                .font: markerFont,
                .kern: -HeadingHelpers.textWidth(restText, font: markerFont),
            ]))
        }
    }

    /// An SF Symbol sized to the inherited font, optionally tinted. `nil` when
    /// the system doesn't know the name — the caller then leaves the source
    /// visible instead of collapsing it to an empty gap.
    private static func symbolImage(named name: String, tint: NSColor?, font: NSFont) -> NSImage? {
        let key = "sym|\(name)|\(font.pointSize)|\(tint?.description ?? "-")" as NSString
        if let cached = glyphCache.object(forKey: key) { return cached }
        var configuration = NSImage.SymbolConfiguration(pointSize: font.pointSize, weight: .regular)
        if let tint {
            configuration = configuration.applying(NSImage.SymbolConfiguration(paletteColors: [tint]))
        }
        guard let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(configuration) else { return nil }
        glyphCache.setObject(image, forKey: key)
        return image
    }

    /// Rasterise replacement text in the inherited font.
    private static func textImage(_ string: String, font: NSFont) -> NSImage? {
        guard !string.isEmpty else { return nil }
        let key = "txt|\(string)|\(font.fontName)|\(font.pointSize)" as NSString
        if let cached = glyphCache.object(forKey: key) { return cached }
        let attributed = NSAttributedString(string: string, attributes: [.font: font])
        let size = attributed.size()
        guard size.width > 0, size.height > 0 else { return nil }
        let image = NSImage(size: CGSize(width: ceil(size.width), height: ceil(size.height)))
        image.lockFocus()
        attributed.draw(at: .zero)
        image.unlockFocus()
        glyphCache.setObject(image, forKey: key)
        return image
    }

    /// Rendered glyphs, keyed by everything that determines the pixels.
    ///
    /// Restyling re-runs presentation for every visible directive on every
    /// keystroke; rasterising text each time is the one part of this path
    /// expensive enough to matter. `NSCache` is thread-safe and evicts under
    /// pressure, so this needs no invalidation of its own — a changed font or
    /// tint simply produces a different key.
    private static let glyphCache: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = 512
        return cache
    }()
}
