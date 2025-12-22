import SwiftUI

struct ProgressPopover: View {
    @ObservedObject var navigationState: NavigationState
    
    var body: some View {
        VStack(spacing: 16) {
            
            VStack(spacing: 8) {
                ProgressView(value: navigationState.progress)
                    .progressViewStyle(.linear)
                    .frame(height: 8)
                
                HStack {
                    Text("\(navigationState.donePageCount) of \(navigationState.totalPageCount) pages completed")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    
                    Spacer()
                    
                    Text("\(Int(navigationState.progress * 100))%")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
        }
        .padding()
        .frame(width: 280)
    }
    
    private func resetProgress() {
        guard let document = navigationState.selectedDocument else { return }
        for page in document.pages {
            page.isDone = false
        }
    }
}

#Preview("English") {
    class PreviewState: NavigationState {
        override var donePageCount: Int { 1 }
        override var totalPageCount: Int { 100 }
        override var progress: Double { Double(donePageCount) / Double(totalPageCount) }
    }
    
    return ProgressPopover(
        navigationState: PreviewState()
    )
    .environment(\.locale, Locale(identifier: "en"))
}

#Preview("es-419") {
    class PreviewState: NavigationState {
        override var donePageCount: Int { 1 }
        override var totalPageCount: Int { 100 }
        override var progress: Double { Double(donePageCount) / Double(totalPageCount) }
    }
    
    return ProgressPopover(
        navigationState: PreviewState()
    )
    .environment(\.locale, Locale(identifier: "es-419"))
}

