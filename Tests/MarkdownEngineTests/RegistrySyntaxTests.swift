//
//  RegistrySyntaxTests.swift
//  MarkdownEngineTests
//
//  The parser-facing registries built from syntax values match the ones built
//  from the extension and directive protocols.
//

import Foundation
import Testing
@testable import MarkdownEngine

@Suite("Registries — built from syntax values")
struct RegistrySyntaxTests {

    @Test("A directive registry from syntax values has the protocol-built one's fingerprint and entries")
    func directiveRegistryFromSyntax() {
        let directives: [any MarkdownDirective] = [FontDirective(), ColorDirective()]
        let settings = DirectiveRegistrySettings(defaultMarker: "\\")
        let fromProtocol = DirectiveRegistry(directives: directives, settings: settings)
        let fromSyntax = DirectiveRegistry(
            syntax: directives.map { (id: $0.id, syntax: $0.syntax) }, settings: settings)
        #expect(!fromSyntax.fingerprint.isEmpty)
        #expect(fromSyntax.fingerprint == fromProtocol.fingerprint)
        #expect(fromSyntax.entry(marker: 0x5C, name: "font")?.id == FontDirective.identifier)
    }

    @Test("An extension registry from syntax values has the protocol-built one's fingerprint and rules")
    func extensionRegistryFromSyntax() {
        let extensions: [any MarkdownExtension] = [
            HighlightExtension(), StrikethroughExtension(), ContainerExtension(),
        ]
        let directives = DirectiveRegistry(directives: [FontDirective()])
        let fromProtocol = ExtensionRegistry(extensions: extensions, directives: directives)
        let fromSyntax = ExtensionRegistry(
            syntax: extensions.map { (id: $0.id, inline: $0.inline, block: $0.block) },
            directives: directives)
        #expect(!fromSyntax.fingerprint.isEmpty)
        #expect(fromSyntax.fingerprint == fromProtocol.fingerprint)
        #expect(fromSyntax.entries.map(\.id) == fromProtocol.entries.map(\.id))
        #expect(fromSyntax.blockEntries.map(\.id) == fromProtocol.blockEntries.map(\.id))
    }

    @Test("No syntax values and no directives give the empty registry")
    func emptySyntax() {
        #expect(ExtensionRegistry(syntax: []).isEmpty)
        #expect(ExtensionRegistry(syntax: []).fingerprint == "")
        #expect(DirectiveRegistry(syntax: []).isEmpty)
    }
}
