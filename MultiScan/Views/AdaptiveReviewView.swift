//
//  AdaptiveReviewView.swift
//  MultiScan
//
//  Size-class-aware wrapper that routes to either the regular NavigationSplitView layout (iPad) or the compact bottom-sheet layout (iPhone).
//

#if os(iOS)
import SwiftUI

struct AdaptiveReviewView: View {
    let document: Document
    var onDismiss: () -> Void

    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    var body: some View {
        if horizontalSizeClass == .compact {
            CompactReviewView(
                document: document,
                onDismiss: onDismiss
            )
        } else {
            ReviewView(
                document: document,
                onDismiss: onDismiss
            )
        }
    }
}
#endif
