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

    @objc func handleHeadingNotification(_ notification: Notification) {
        guard let level = notification.userInfo?["level"] as? Int else { return }
        let item = NSMenuItem()
        item.tag = level
        didMarkdownHeading(item)
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
