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

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var controller: PageTextController?

        func textDidChange(_ notification: Notification) {
            controller?.textDidChange()
        }
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

    @MainActor
    final class Coordinator: NSObject, UITextViewDelegate {
        var controller: PageTextController?

        func textViewDidChange(_ textView: UITextView) {
            controller?.textDidChange()
        }
    }
}
#endif
