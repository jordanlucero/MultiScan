import SwiftUI

struct ProgressPopover: View {
    @ObservedObject var navigationState: NavigationState
    
    var body: some View {
        VStack(spacing: 16) {
            Text("Progress")
                .font(.headline)
            
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
