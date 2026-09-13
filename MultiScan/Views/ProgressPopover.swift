import SwiftUI

struct ProgressPopover: View {
    let donePageCount: Int
    let totalPageCount: Int

    private var progress: Double {
        guard totalPageCount > 0 else { return 0 }
        return Double(donePageCount) / Double(totalPageCount)
    }

    var body: some View {
        VStack(spacing: 8) {
            ProgressView(value: progress)
                .progressViewStyle(.linear)

            HStack {
                Text("\(donePageCount) of \(totalPageCount) pages completed", comment: "Progress indicator showing amount of reviewed pages that are considered 'completed'")
                    .font(.caption)
                    .foregroundStyle(Color.secondary)

                Spacer()

                Text(Int(progress * 100), format: .percent)
                    .font(.caption)
                    .foregroundStyle(Color.secondary)
            }
        }
        .padding()
        .frame(idealWidth: 280)
    }
}

#Preview("English") {
    ProgressPopover(donePageCount: 1, totalPageCount: 100)
        .environment(\.locale, Locale(identifier: "en"))
}

#Preview("es-419") {
    ProgressPopover(donePageCount: 1, totalPageCount: 100)
        .environment(\.locale, Locale(identifier: "es-419"))
}
