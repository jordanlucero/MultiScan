//
//  RichTextPreview.swift
//  MultiScan
//
//  Read-only TextKit 2 view for displaying large attributed strings.
//
//  Used by the export panel preview. Because TextKit 2 only lays out the layout
//  fragments intersecting the viewport, the full combined document can be shown
//  without truncation — replacing the old SwiftUI Text preview that froze on big
//  documents and had to cap at 50,000 characters.
//

import SwiftUI

#if os(macOS)
import AppKit

struct RichTextPreview: NSViewRepresentable {
    let text: NSAttributedString

    func makeNSView(context: Context) -> NSScrollView {
        let (scrollView, textView) = PageTextView.makeScrollable(editable: false)
        textView.contentStorage.setAttributedString(RichTextArchiver.applyingDisplayColor(text))
        context.coordinator.lastText = text
        return scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        guard let textView = nsView.documentView as? PageTextView else { return }
        if context.coordinator.lastText !== text {
            context.coordinator.lastText = text
            textView.contentStorage.setAttributedString(RichTextArchiver.applyingDisplayColor(text))
            textView.scrollToBeginningOfDocument(nil)
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    @MainActor
    final class Coordinator {
        var lastText: NSAttributedString?
    }
}

#else
import UIKit

struct RichTextPreview: UIViewRepresentable {
    let text: NSAttributedString

    func makeUIView(context: Context) -> PageTextView {
        let textView = PageTextView.make(editable: false)
        textView.contentStorage.setAttributedString(RichTextArchiver.applyingDisplayColor(text))
        context.coordinator.lastText = text
        return textView
    }

    func updateUIView(_ uiView: PageTextView, context: Context) {
        if context.coordinator.lastText !== text {
            context.coordinator.lastText = text
            uiView.contentStorage.setAttributedString(RichTextArchiver.applyingDisplayColor(text))
            uiView.contentOffset = .zero
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    @MainActor
    final class Coordinator {
        var lastText: NSAttributedString?
    }
}
#endif
