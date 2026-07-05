//
//  AdaptiveReviewView.swift
//  MultiScan
//
//  Size-class-aware wrapper that routes to either the regular
//  NavigationSplitView layout (iPad) or the compact bottom-sheet layout (iPhone).
//  iOS-only: macOS uses ReviewView directly (size classes don't exist on macOS).
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
