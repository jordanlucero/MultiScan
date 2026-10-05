//
//  PageTextEditor.swift
//  MultiScan
//
//  SwiftUI wrapper for the TextKit 2 page editor.
//
//  Follows the standard pattern for hosting framework text views in a SwiftUI app:
//  an NSViewRepresentable on macOS and a UIViewRepresentable on iOS, each wrapping
//  the shared PageTextView. The platform view instance is reused across page
//  switches — only the controller changes, which reloads the content storage.
//
//  ## Undo (macOS)
//  `NSTextView` asks its delegate for an undo manager (`undoManager(for:)`); without one it
//  uses the window's, which the review screen shares with page reordering. The coordinator
//  hands back the controller's own `UndoManager`, so typing undo is scoped to the editor and
//  ⌘Z goes to whichever responder has focus — the text view when editing, the window (page
//  reorder) otherwise. On iOS `UITextView` already owns its undo manager.
//

import SwiftUI

#if os(macOS)
import AppKit

struct PageTextEditor: NSViewRepresentable {
    let controller: PageTextController

    func makeNSView(context: Context) -> NSScrollView {
        let (scrollView, textView) = PageTextView.makeScrollable(editable: true)
        textView.delegate = context.coordinator
        context.coordinator.controller = controller
        controller.attach(textView)
        return scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        guard let textView = nsView.documentView as? PageTextView else { return }
        if context.coordinator.controller !== controller {
            context.coordinator.controller = controller
            controller.attach(textView)
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var controller: PageTextController?

        func textDidChange(_ notification: Notification) {
            controller?.textDidChange()
        }

        /// Per-editor undo manager — see the file comment.
        func undoManager(for view: NSTextView) -> UndoManager? {
            controller?.editorUndoManager
        }

        /// Keep attachment placeholders atomic: a selection that ends up half inside an attachment character is never meaningful, and TextKit treats the single U+FFFC as one glyph anyway. Nothing to adjust here today; the hook is kept so a future attachment-aware selection policy has a home.
    }
}

#else
import UIKit

struct PageTextEditor: UIViewRepresentable {
    let controller: PageTextController

    func makeUIView(context: Context) -> PageTextView {
        let textView = PageTextView.make(editable: true)
        textView.delegate = context.coordinator
        context.coordinator.controller = controller
        controller.attach(textView)
        return textView
    }

    func updateUIView(_ uiView: PageTextView, context: Context) {
        if context.coordinator.controller !== controller {
            context.coordinator.controller = controller
            controller.attach(uiView)
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        var controller: PageTextController?

        func textViewDidChange(_ textView: UITextView) {
            controller?.textDidChange()
        }
    }
}
#endif
