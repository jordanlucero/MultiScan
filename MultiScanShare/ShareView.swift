//
//  ShareView.swift
//  MultiScanShare
//
//  The share sheet UI, shared by iOS, iPadOS, and macOS. Normally only seen for a moment: it shows progress while the files are copied, then the app takes over.
//

import SwiftUI

struct ShareView: View {
    let model: ShareModel

    var body: some View {
        VStack(spacing: 16) {
            switch model.phase {
            case .sending(let completed):
                ProgressView(value: Double(completed), total: Double(max(model.itemCount, 1))) {
                    Text("Sending to MultiScan…")
                }
            case .finished:
                Label("Sent to MultiScan", systemImage: "checkmark.circle.fill")
                    .font(.headline)
                Text("Open MultiScan to start scanning.")
                    .foregroundStyle(.secondary)
                Button { model.cancel() } label: {
                Image(systemName: "checkmark")
            }
                .buttonStyle(.glassProminent)
                .keyboardShortcut(.defaultAction)
            case .failed:
                Label(
                    model.itemCount == 0
                        ? "There are no images or PDFs to scan."
                        : "These items couldn’t be added to MultiScan.",
                    systemImage: "exclamationmark.triangle.fill"
                )
                Button { model.cancel() } label: {
                Image(systemName: "xmark")
            }
                .buttonStyle(.glassProminent)
                .keyboardShortcut(.defaultAction)
            }
        }
        .multilineTextAlignment(.center)
        .padding(24)
        #if os(macOS)
        .frame(width: 320)
        #else
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        #endif
        .task { await model.send() }
    }
}
