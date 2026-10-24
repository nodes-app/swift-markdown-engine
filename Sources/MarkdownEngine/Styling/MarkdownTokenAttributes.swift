//
//  MarkdownTokenAttributes.swift
//  MarkdownEngine
//
//  Text attributes the styler sets on wiki-links and task checkboxes.
//

import Foundation

extension NSAttributedString.Key {
    public static let wikiLinkID = NSAttributedString.Key("NodeLinkID")
    public static let taskCheckbox = NSAttributedString.Key("TaskCheckbox")
}
