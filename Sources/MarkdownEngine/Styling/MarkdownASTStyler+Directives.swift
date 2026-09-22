//
//  MarkdownASTStyler+Directives.swift
//  MarkdownEngine
//
//  Phase 2 of the directive seam: a container directive's body picks up the
//  directive's style, and — the part that matters — its font TRANSFORM
//  composes over the font inherited at that point in the tree.
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
    /// no body, and their glyph presentation lands in Phase 3.
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

        // A self-contained call is the whole node — no body to style.
        guard !node.markers.isEmpty, node.contentRange.length > 0 else { return font }

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
        return bodyFont
    }
}
