//
//  PageTextView.swift
//  MultiScan
//
//  The platform text views at the heart of the TextKit 2 text engine.
//
//  Both views are built on an explicit TextKit 2 stack:
//
//      NSTextContentStorage  (storage layer — breaks the attributed string into paragraphs)
//              │
//      NSTextLayoutManager   (layout layer — produces NSTextLayoutFragments)
//              │
//      NSTextContainer       (geometry the viewport lays out into)
//              │
//      PageTextView          (view layer — NSTextView / UITextView subclass)
//
//  The framework text views drive the viewport layout process themselves, which is
//  what makes huge documents cheap to display: only fragments intersecting the
//  viewport are laid out and rendered.
//
//  ⚠️ Never touch `layoutManager` (macOS) on these views — accessing the TextKit 1
//  property makes the view silently fall back to the compatibility text engine.
//
//  Future extension point: subclassing here is what enables the viewport-delegate
//  customizations (line numbers, collapsible ranges, attachment view-provider reuse)
//  by overriding the NSTextViewportLayoutControllerDelegate methods that the
//  framework text views now conform to.
//

import SwiftUI

#if os(macOS)
import AppKit

/// TextKit 2 backed NSTextView for page text editing and preview.
final class PageTextView: NSTextView {

    /// Builds a scrollable TextKit 2 text view from an explicitly constructed stack.
    static func makeScrollable(editable: Bool) -> (scrollView: NSScrollView, textView: PageTextView) {
        // Storage → layout → container: the TextKit 2 stack.
        let contentStorage = NSTextContentStorage()
        let layoutManager = NSTextLayoutManager()
        contentStorage.addTextLayoutManager(layoutManager)

        let container = NSTextContainer(size: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        layoutManager.textContainer = container

        let textView = PageTextView(frame: .zero, textContainer: container)
        textView.isEditable = editable
        textView.isSelectable = true
        textView.isRichText = true
        textView.allowsUndo = true
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
        textView.usesFontPanel = false
        textView.importsGraphics = false
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainerInset = NSSize(width: 10, height: 12)
        textView.drawsBackground = false
        textView.textColor = .labelColor
        textView.typingAttributes = [
            .font: PageTextStyle.displayFont,
            .foregroundColor: NSColor.labelColor
        ]

        let scrollView = NSScrollView()
        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.drawsBackground = false
        scrollView.autohidesScrollers = true

        return (scrollView, textView)
    }
}

extension PageTextView {
    /// Non-optional text storage accessor (NSTextView exposes it as optional).
    var contentStorage: NSTextStorage {
        textStorage ?? NSTextStorage()
    }
}

#else
import UIKit

/// TextKit 2 backed UITextView for page text editing and preview.
final class PageTextView: UITextView {

    /// Fired when the preferred content size category (Dynamic Type) changes.
    /// The editing controller re-normalizes its content to the new body size —
    /// attributed strings carry explicit fonts, so they don't rescale on their own.
    var contentSizeCategoryDidChange: (() -> Void)?

    /// Builds a TextKit 2 text view. `UITextView(usingTextLayoutManager: true)`
    /// assembles the same content-storage → layout-manager → container stack that
    /// the macOS side constructs explicitly.
    static func make(editable: Bool) -> PageTextView {
        let textView = PageTextView(usingTextLayoutManager: true)
        textView.registerForTraitChanges([UITraitPreferredContentSizeCategory.self]) { (view: PageTextView, _: UITraitCollection) in
            view.contentSizeCategoryDidChange?()
        }
        textView.isEditable = editable
        textView.isSelectable = true
        // System-provided formatting controls (edit menu / keyboard) — the app
        // deliberately ships no in-app formatting buttons on iOS.
        textView.allowsEditingTextAttributes = editable
        textView.isFindInteractionEnabled = true
        textView.alwaysBounceVertical = true
        textView.keyboardDismissMode = .interactive
        textView.backgroundColor = .clear
        textView.textContainerInset = UIEdgeInsets(top: 12, left: 6, bottom: 12, right: 6)
        textView.font = PageTextStyle.displayFont
        textView.textColor = .label
        textView.typingAttributes = [
            .font: PageTextStyle.displayFont,
            .foregroundColor: UIColor.label
        ]
        return textView
    }
}

extension PageTextView {
    /// Shared name with the macOS accessor so the controller code is platform-neutral.
    var contentStorage: NSTextStorage {
        textStorage
    }
}
#endif
