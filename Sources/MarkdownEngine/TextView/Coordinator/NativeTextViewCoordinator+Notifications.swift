//
//  NativeTextViewCoordinator+Notifications.swift
//  MarkdownEngine
//
//  Created by Luca Chen on 16.03.26.
//
//  Bus-notification handlers wired up by `subscribeToBusNotifications`.
//  These translate embedder-posted requests (apply bold / italic / heading
//  level) into the corresponding ContextMenu actions, and refresh styling
//  when the syntax highlighter signals an appearance change.
//

import AppKit

extension NativeTextViewCoordinator {
    @objc func handleBoldNotification(_ notification: Notification) {
        didMarkdownBold(nil)
    }

    @objc func handleItalicNotification(_ notification: Notification) {
        didMarkdownItalic(nil)
    }

    @objc func handleHighlightNotification(_ notification: Notification) {
        didMarkdownHighlight(nil)
    }

    @objc func handleHeadingNotification(_ notification: Notification) {
        guard let level = notification.userInfo?["level"] as? Int else { return }
        let item = NSMenuItem()
        item.tag = level
        didMarkdownHeading(item)
    }

    @objc func handleStrikethroughNotification(_ notification: Notification) {
        didMarkdownStrikethrough(nil)
    }

    @objc func handleInlineCodeNotification(_ notification: Notification) {
        didMarkdownInlineCode(nil)
    }

    @objc func handleBlockquoteNotification(_ notification: Notification) {
        didMarkdownBlockquote(nil)
    }

    @objc func handleUnorderedListNotification(_ notification: Notification) {
        didMarkdownUnorderedList(nil)
    }

    @objc func handleOrderedListNotification(_ notification: Notification) {
        didMarkdownOrderedList(nil)
    }

    @objc func handleLinkNotification(_ notification: Notification) {
        didMarkdownLink(notification)
    }

    @objc func handleCodeBlockNotification(_ notification: Notification) {
        didMarkdownCodeBlock(nil)
    }

    @objc func handleHorizontalRuleNotification(_ notification: Notification) {
        didMarkdownHorizontalRule(nil)
    }

    @objc func handleImageNotification(_ notification: Notification) {
        didMarkdownImage(notification)
    }

    @objc func handleAppearanceChange(_ notification: Notification) {
        guard let tv = textView else { return }
        // Only react if the notification came from our own text view or from nil (system-wide)
        if let sender = notification.object as? NSTextView, sender !== tv {
            return
        }
        let fullRange = NSRange(location: 0, length: (tv.string as NSString).length)
        restyleTextView(tv, paragraphCandidates: [fullRange])
    }
}
