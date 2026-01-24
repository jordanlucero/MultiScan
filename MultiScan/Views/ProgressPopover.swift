import SwiftUI

struct ProgressPopover: View {
    @ObservedObject var navigationState: NavigationState
    
    var body: some View {
        VStack(spacing: 16) {
            
            VStack(spacing: 8) {
                ProgressView(value: navigationState.progress)
                    .progressViewStyle(.linear)
                
                HStack {
                    Text("\(navigationState.donePageCount) of \(navigationState.totalPageCount) pages completed", comment: "Progress indicator showing completed pages")
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
        .frame(idealWidth: 280)
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

