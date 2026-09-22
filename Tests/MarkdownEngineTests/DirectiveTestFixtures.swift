//
//  DirectiveTestFixtures.swift
//  MarkdownEngineTests
//
//  Directives used across the directive suites.
//
//  Deliberately test-local: this change adds the seam, not any directive, so
//  the parser tests declare the shapes they need rather than leaning on a
//  bundled implementation. That keeps them testing the SEAM — a schema is a
//  schema whether it came from the engine or from an embedder.
//

import Foundation
@testable import MarkdownEngine

/// Container form with a mixed labelled schema — the shape the parser has to
/// carry through argument coercion.
struct SizedDirective: MarkdownDirective {
    var syntax: DirectiveSyntax {
        DirectiveSyntax(
            name: "font",
            form: .container,
            parameters: [
                .init(label: "size", kind: .length,
                      documentation: "Point size, or 1.5em / 120% relative to the surrounding text."),
                .init(label: "family", kind: .string, documentation: "Font family name."),
                .init(label: "weight", kind: .keyword(["regular", "bold"]),
                      defaultValue: .keyword("regular"), documentation: "Font weight."),
            ]
        )
    }
}

/// Container form with a required POSITIONAL argument.
struct TintDirective: MarkdownDirective {
    var syntax: DirectiveSyntax {
        DirectiveSyntax(
            name: "color",
            form: .container,
            parameters: [.init(label: nil, kind: .keyword([]), isRequired: true,
                               documentation: "Colour name.")]
        )
    }
}

/// Self-contained form, no arguments.
struct MarkerDirective: MarkdownDirective {
    var syntax: DirectiveSyntax { DirectiveSyntax(name: "marker", form: .selfContained) }
    func html(arguments: DirectiveArguments, bodyHTML: String) -> String { "<hr class=\"marker\" />" }
}

/// Self-contained with two POSITIONAL parameters — the shape that exercises
/// defaults on positionals, which labelled-only filling used to skip.
struct SelfContainedPair: MarkdownDirective {
    var syntax: DirectiveSyntax { DirectiveSyntax(name: "pair", form: .selfContained) }
}
