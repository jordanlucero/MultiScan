import SwiftUI

struct OCRProgressView: View {
    @ObservedObject var ocrService: OCRService
    @Environment(\.dismiss) private var dismiss
    
    var body: some View {
        VStack(spacing: 20) {
            Text("Processing Images")
                .font(.title2)
                .fontWeight(.semibold)
            
            ProgressView(value: ocrService.progress) {
                Text("Performing OCR...")
                    .font(.headline)
            } currentValueLabel: {
                Text("\(Int(ocrService.progress * 100))%")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .progressViewStyle(.linear)
            
            if !ocrService.currentFile.isEmpty {
                Label(ocrService.currentFile, systemImage: "doc.text")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            
            if ocrService.progress >= 1.0 {
                Button("Done") {
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(40)
        .frame(width: 400, height: 200)
        .interactiveDismissDisabled(ocrService.isProcessing)
    }
}