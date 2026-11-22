//
//  SyntaxTypes.swift
//  MarkdownEngine
//
//  The public syntax types that live in `MarkdownEngineSyntax`, under their
//  `MarkdownEngine` names, so embedders keep one import. The re-export brings
//  their members too (`MemberImportVisibility`).
//

@_exported import MarkdownEngineSyntax

public typealias BlockSyntax = MarkdownEngineSyntax.BlockSyntax
public typealias DirectiveArguments = MarkdownEngineSyntax.DirectiveArguments
public typealias DirectiveDiagnostic = MarkdownEngineSyntax.DirectiveDiagnostic
public typealias DirectiveParameter = MarkdownEngineSyntax.DirectiveParameter
public typealias DirectiveRegistrySettings = MarkdownEngineSyntax.DirectiveRegistrySettings
public typealias DirectiveSyntax = MarkdownEngineSyntax.DirectiveSyntax
public typealias DirectiveUnit = MarkdownEngineSyntax.DirectiveUnit
public typealias DirectiveValue = MarkdownEngineSyntax.DirectiveValue
public typealias InlineSyntax = MarkdownEngineSyntax.InlineSyntax
