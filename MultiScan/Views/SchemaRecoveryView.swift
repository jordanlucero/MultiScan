//  Recovery UI shown when the app fails to load data or detects incompatibilities.
//
//  This view replaces invisible crashes with actionable user options:
//  - Try Again: Retry loading the container
//  - Reset All Data: Delete database and start fresh
//  - Report Issue: Link to GitHub for bug reports

import SwiftUI

// MARK: - Recovery View

/// Main recovery view shown when container loading fails.
struct SchemaRecoveryView: View {
    let state: RecoveryState
    let onRetry: () -> Void
    let onReset: () -> Void

    @State private var showResetConfirmation = false

    var body: some View {
        VStack(spacing: 32) {
            // Icon and title
            headerSection

            // Description of what went wrong
            descriptionSection

            // Action buttons
            actionSection
        }
        .padding(24)
        .confirmationDialog(
            Text("Reset All Data?"),
            isPresented: $showResetConfirmation,
            titleVisibility: .visible
        ) {
            Button("Delete All Data", role: .destructive) {
                onReset()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This will permanently delete all your projects and pages. This cannot be undone.")
        }
    }

    // MARK: - Header Section

    @ViewBuilder
    private var headerSection: some View {
        VStack(spacing: 16) {
            Image(systemName: state.iconName)
                .font(.system(size: 56))
                .foregroundStyle(state.iconColor)

            Text(state.title)
                .font(.title)
                .fontWeight(.bold)
        }
    }

    // MARK: - Description Section

    @ViewBuilder
    private var descriptionSection: some View {
        VStack(spacing: 12) {
            Text(state.description)
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            if let technicalDetail = state.technicalDetail {
                Text(technicalDetail)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
            }
        }
    }

    // MARK: - Action Section

    @ViewBuilder
    private var actionSection: some View {
        VStack(spacing: 12) {
            // Primary action depends on state
            switch state {
            case .incompatible:
                // For incompatible data, "Check for Updates" is primary
                Link(destination: URL(string: "itms-apps://")!) {
                    Label {
                        Text("Open App Store")
                    } icon: {
                        Image(systemName: "arrow.down.circle")
                    }
                }
                .buttonStyle(.borderedProminent)

            case .failed:
                // For failures, "Try Again" is primary
                Button {
                    onRetry()
                } label: {
                    Label {
                        Text("Try Again")
                    } icon: {
                        Image(systemName: "arrow.clockwise")
                    }
                }
                .buttonStyle(.borderedProminent)
            }

            // Secondary actions
            HStack(spacing: 12) {
                Button(role: .destructive) {
                    showResetConfirmation = true
                } label: {
                    Label {
                        Text("Reset All Data")
                    } icon: {
                        Image(systemName: "trash")
                    }
                }

                Link(destination: URL(string: "https://github.com/jordanlucero/MultiScan/issues")!) {
                    Label {
                        Text("Report Issue")
                    } icon: {
                        Image(systemName: "exclamationmark.bubble")
                    }
                }
            }
            .buttonStyle(.bordered)
        }
    }
}

// MARK: - Recovery State

/// Represents what went wrong and determines the UI shown.
enum RecoveryState {
    /// Data was written by a newer app version.
    case incompatible(version: Int)

    /// Container failed to load for other reasons.
    case failed(error: String)

    var iconName: String {
        switch self {
        case .incompatible:
            return "arrow.down.app.dashed"
        case .failed:
            return "exclamationmark.triangle"
        }
    }

    var iconColor: Color {
        switch self {
        case .incompatible:
            return .orange
        case .failed:
            return .red
        }
    }

    var title: LocalizedStringResource {
        switch self {
        case .incompatible:
            return "Update Required"
        case .failed:
            return "Unable to Load Data"
        }
    }

    var description: LocalizedStringResource {
        switch self {
        case .incompatible:
            return "Your projects were last modified by a newer version of MultiScan. Please update the app on this device to access your projects."
        case .failed:
            return "MultiScan was unable to load your projects due to an unexpected error."
        }
    }

    var technicalDetail: String? {
        switch self {
        case .incompatible(let version):
            return String(localized: "Data schema version: \(version), App supports: \(SchemaVersioning.currentVersion)")
        case .failed(let error):
            return error
        }
    }
}

// MARK: - Loading View

/// Simple loading view shown while container is being created.
struct ContainerLoadingView: View {
    var body: some View {
        VStack(spacing: 16) {
            ProgressView()
            Text("Loading…")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - Previews

#Preview("Incompatible Data") {
    SchemaRecoveryView(
        state: .incompatible(version: 999),
        onRetry: {},
        onReset: {}
    )
}

#Preview("Load Failed") {
    SchemaRecoveryView(
        state: .failed(error: "NSError Code=123456 \"Example error.\""),
        onRetry: {},
        onReset: {}
    )
}

#Preview("Loading") {
    ContainerLoadingView()
}
