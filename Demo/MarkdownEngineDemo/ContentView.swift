//
//  ContentView.swift
//  MarkdownEngine
//
//  Created by Nicolas von Mallinckrodt on 29.04.26.
//

import SwiftUI
import MarkdownEngine

struct ContentView: View {
    @State private var text: String = sampleMarkdown
    @State private var isWikiLinkActive: Bool = false
    @State private var pendingReplacement: InlineReplacementRequest?

    var body: some View {
        NativeTextViewWrapper(
            text: $text,
            isWikiLinkActive: $isWikiLinkActive,
            pendingInlineReplacement: $pendingReplacement,
            configuration: .default,
            fontName: "SF Pro",
            documentId: "demo"
        )
    }
}

private let sampleMarkdown = """
# MarkdownEngine

A native macOS Markdown editor built on **TextKit 2**, bridged to SwiftUI.

## Features
*Italic*
**Bold**

"""
