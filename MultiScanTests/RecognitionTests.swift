//
//  RecognitionTests.swift
//  MultiScanTests
//
//  The parts of recognition that can go quietly wrong: merging Vision's detail bands into the whole-page read, and the model-server client's handling of what servers actually send.
//

import Foundation
import Testing
import CoreGraphics
import CoreText
import ImageIO
@testable import MultiScan

@Suite("Recognition")
struct RecognitionTests {

    // MARK: Vision detail bands

    private func line(_ text: String, y: Double, height: Double = 0.02, x: Double = 0.1, width: Double = 0.8) -> VisionDocumentLayout.Line {
        VisionDocumentLayout.Line(text: text, box: NormalizedBox(x: x, y: y, width: width, height: height))
    }

    private func layout(_ lines: [VisionDocumentLayout.Line], transcript: String? = nil, title: String? = nil) -> VisionDocumentLayout {
        let paragraphs = lines.isEmpty ? [] : [VisionDocumentLayout.Paragraph(
            text: lines.map(\.text).joined(separator: "\n"),
            box: NormalizedBox.union(of: lines.map(\.box))!,
            lines: lines
        )]
        return VisionDocumentLayout(
            imageWidth: 1000, imageHeight: 1400,
            transcript: transcript ?? lines.map(\.text).joined(separator: "\n"),
            title: title, paragraphs: paragraphs, tables: [], lists: [], languages: ["en"]
        )
    }

    @Test func bandsAreOverlappingAndCoverTheImage() {
        let portrait = VisionDocumentRecognizer.detailBands(forImageWidth: 2550, height: 3300)
        #expect(portrait.count == 3)
        #expect(portrait.first?.minY == 0 && abs((portrait.last?.maxY ?? 0) - 1) < 0.0001)
        for (upper, lower) in zip(portrait, portrait.dropFirst()) {
            #expect(lower.minY < upper.maxY) // overlap, so a line cut by one band is whole in the next
        }
        #expect(VisionDocumentRecognizer.detailBands(forImageWidth: 3300, height: 2550).count == 2)
        #expect(VisionDocumentRecognizer.detailBands(forImageWidth: 400, height: 500).isEmpty)
    }

    @Test func aPageTheWholePassReadCompletelyComesBackUnchanged() {
        let whole = layout([line("Body one", y: 0.10), line("Body two", y: 0.14)])
        // The top band (0…0.4) sees the same two lines, in its own coordinates.
        let band = layout([line("Body one", y: 0.25, height: 0.05), line("Body two", y: 0.35, height: 0.05)])
        let merged = VisionDocumentRecognizer.merging(whole: whole, bands: [(NormalizedBox(x: 0, y: 0, width: 1, height: 0.4), band)])
        #expect(merged == whole)
    }

    @Test func linesOnlyABandFoundAreAddedInReadingPosition() {
        // The whole pass read the body but not the small footnotes at the bottom.
        let whole = layout([line("Body one", y: 0.10), line("Body two", y: 0.14)], transcript: "Body one\nBody two", title: "Body one")
        // Bottom band (0.6…1): footnotes at 0.90 and 0.93 of the page → (0.90 − 0.6) / 0.4 = 0.75, 0.825 in the band.
        let band = layout([line("1. A footnote", y: 0.75, height: 0.03), line("2. Another", y: 0.825, height: 0.03)])
        let merged = VisionDocumentRecognizer.merging(whole: whole, bands: [(NormalizedBox(x: 0, y: 0.6, width: 1, height: 0.4), band)])

        #expect(merged.paragraphs.count == 2)
        #expect(merged.allLines.map(\.text) == ["Body one", "Body two", "1. A footnote", "2. Another"])
        #expect(merged.transcript == "Body one\nBody two\n1. A footnote\n2. Another")
        #expect(merged.title == "Body one")
        // Recovered boxes are in whole-page coordinates.
        let footnote = merged.allLines[2].box
        #expect(abs(footnote.y - 0.90) < 0.0001 && abs(footnote.height - 0.012) < 0.0001)
    }

    @Test func aPageTheWholePassCouldNotReadIsRecoveredFromTheBands() {
        let empty = layout([])
        let top = layout([line("Small print A", y: 0.5, height: 0.04)])
        let bottom = layout([line("Small print B", y: 0.5, height: 0.04)])
        let merged = VisionDocumentRecognizer.merging(whole: empty, bands: [
            (NormalizedBox(x: 0, y: 0, width: 1, height: 0.4), top),
            (NormalizedBox(x: 0, y: 0.6, width: 1, height: 0.4), bottom)
        ])
        #expect(merged.allLines.map(\.text) == ["Small print A", "Small print B"])
        #expect(merged.transcript == "Small print A\nSmall print B")
    }

    @Test func overlapDuplicatesAndSlicedLinesAreNotAddedTwice() {
        let whole = layout([])
        // Two bands that overlap between 0.3 and 0.4 of the page; the same line (at 0.34) is seen by both.
        let first = layout([line("Shared line", y: 0.85, height: 0.05)])                       // 0.85 × 0.4 = 0.34
        let second = layout([
            line("Shared line", y: 0.10, height: 0.05),                                        // 0.3 + 0.10 × 0.4 = 0.34
            line("Sliced at the top edge", y: 0.0, height: 0.05)                               // touches the band's cut edge
        ])
        let merged = VisionDocumentRecognizer.merging(whole: whole, bands: [
            (NormalizedBox(x: 0, y: 0, width: 1, height: 0.4), first),
            (NormalizedBox(x: 0, y: 0.3, width: 1, height: 0.4), second)
        ])
        #expect(merged.allLines.map(\.text) == ["Shared line"])
    }

    @Test func recognitionLanguagesPutTheUsersLanguagesFirst() {
        let supported = ["en", "fr", "es", "de"].map { Locale.Language(identifier: $0) }
        let preferred = VisionDocumentRecognizer.preferredRecognitionLanguages(supported: supported, preferredIdentifiers: ["es-419", "ja-JP", "en-US"])
        #expect(preferred.map { $0.languageCode?.identifier } == ["es", "en"])
        // English is always in the list.
        #expect(VisionDocumentRecognizer.preferredRecognitionLanguages(supported: supported, preferredIdentifiers: ["fr-FR"]).map { $0.languageCode?.identifier } == ["fr", "en"])
    }

    @Test(.timeLimit(.minutes(3)))
    func smallPrintUnderBodyTextIsRead() async throws {
        // Body text at a comfortable size, then "footnotes" small enough that the whole-page pass alone drops them (measured on macOS 27: 260 of 420 words).
        let width = 2550, height = 3300
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let words = "the quick brown fox jumps over the lazy dog while the patient reader turns another page of this rather ordinary printed book".split(separator: " ").map(String.init)
        func draw(count: Int, seed: Int, size: CGFloat, rect: CGRect) {
            var text = ""
            for index in 0..<count { text += words[(index * 7 + seed) % words.count] + " " }
            let attributed = NSAttributedString(string: text, attributes: [
                NSAttributedString.Key(kCTFontAttributeName as String): CTFontCreateWithName("Times New Roman" as CFString, size, nil),
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 0, alpha: 1)
            ])
            CTFrameDraw(CTFramesetterCreateFrame(CTFramesetterCreateWithAttributedString(attributed), CFRange(location: 0, length: 0), CGPath(rect: rect, transform: nil), nil), context)
        }
        let w = CGFloat(width), h = CGFloat(height)
        draw(count: 260, seed: 0, size: h / 65, rect: CGRect(x: 0.1 * w, y: 0.34 * h, width: 0.8 * w, height: 0.58 * h))
        draw(count: 160, seed: 3, size: h / 150, rect: CGRect(x: 0.1 * w, y: 0.08 * h, width: 0.8 * w, height: 0.2 * h))
        let image = context.makeImage()!

        func wordCount(_ layout: VisionDocumentLayout) -> Int {
            layout.transcript.split(whereSeparator: { $0 == " " || $0 == "\n" }).count
        }
        let single = try await VisionDocumentRecognizer.recognizeSinglePass(image, orientation: .up)
        let thorough = try await VisionDocumentRecognizer.recognize(image, orientation: .up)
        // The detail pass never loses what the whole pass had, and here it recovers the small print.
        #expect(wordCount(thorough) >= wordCount(single))
        #expect(wordCount(thorough) >= 400, "expected nearly all 420 words, got \(wordCount(thorough)) (whole-page pass alone: \(wordCount(single)))")
    }

    // MARK: Model server client

    private func stream(_ text: String) -> AsyncStream<UInt8> {
        AsyncStream { continuation in
            for byte in Array(text.utf8) { continuation.yield(byte) }
            continuation.finish()
        }
    }

    @Test func streamedAnswersAreAssembledFromDeltas() async throws {
        let events = """
        data: {"choices":[{"delta":{"role":"assistant"}}]}

        data: {"choices":[{"delta":{"content":"# Title"}}]}\r
        data: {"choices":[{"delta":{"content":"\\nBody"}}]}

        : keep-alive comment
        data: {"choices":[{"delta":{},"finish_reason":"stop"}]}

        data: [DONE]

        data: {"choices":[{"delta":{"content":" ignored after DONE"}}]}
        """
        let text = try await ModelServerTranscriber.collect(stream(events), contentType: "text/event-stream")
        #expect(text == "# Title\nBody")
    }

    @Test func aServerThatIgnoresStreamingStillWorks() async throws {
        let body = #"{"choices":[{"message":{"role":"assistant","content":"Plain answer"}}]}"#
        #expect(try await ModelServerTranscriber.collect(stream(body), contentType: "application/json") == "Plain answer")
    }

    @Test func serverErrorsAreReportedInTheServersWords() async {
        let body = #"{"error":{"message":"Model does not support images","type":"invalid_request_error"}}"#
        await #expect(throws: ModelTranscriptionError.self) {
            _ = try await ModelServerTranscriber.collect(stream(body), contentType: "application/json")
        }
        #expect(ModelServerTranscriber.errorMessage(from: Data(body.utf8)) == "Model does not support images")
        #expect(ModelServerTranscriber.errorMessage(from: Data("  plain failure  ".utf8)) == "plain failure")

        await #expect(throws: ModelTranscriptionError.self) {
            _ = try await ModelServerTranscriber.collect(stream("<html>not json</html>"), contentType: "text/html")
        }
    }

    @Test func endpointsTolerateHowPeopleTypeTheAddress() {
        let expected = "http://localhost:1234/v1/chat/completions"
        for base in ["http://localhost:1234", "http://localhost:1234/", "http://localhost:1234/v1", "http://localhost:1234/v1/"] {
            #expect(ModelServerTranscriber.endpoint("chat/completions", base: URL(string: base)!).absoluteString == expected)
        }
        #expect(ModelServerPreset.ollama.baseURL.absoluteString == "http://localhost:11434")
    }

    @Test func transcriptsLoseReasoningAndWholeAnswerFences() {
        #expect(ModelTranscriber.cleanedTranscript("<think>Let me look at the page…</think>\n# Heading\nText") == "# Heading\nText")
        #expect(ModelTranscriber.cleanedTranscript("```markdown\n# Heading\nText\n```") == "# Heading\nText")
        #expect(ModelTranscriber.cleanedTranscript("```\nJust text\n```") == "Just text")
        // A fence that is part of the page, or one of several, is content.
        let withCode = "Intro\n```swift\nlet x = 1\n```\nOutro"
        #expect(ModelTranscriber.cleanedTranscript(withCode) == withCode)
        let twoFences = "```\na\n```\ntext\n```\nb\n```"
        #expect(ModelTranscriber.cleanedTranscript(twoFences) == twoFences)
        // Thinking that never finished leaves nothing to use.
        #expect(ModelTranscriber.cleanedTranscript("<think>still going") == "")
    }

    @Test func storedEngineChoicesSurviveTheRename() {
        #expect(OCREngineKind(storedValue: "lmStudio") == .modelServer)
        #expect(OCREngineKind(storedValue: "modelServer") == .modelServer)
        #expect(OCREngineKind(storedValue: "vision") == .vision)
        #expect(OCREngineKind(storedValue: "nonsense") == nil)

        let defaults = Fixtures.defaults("engine-\(UUID().uuidString)")
        defaults.set("lmStudio", forKey: "ocrEngineKind")
        defaults.set("http://localhost:11434", forKey: "ocrLMStudioBaseURL")
        let settings = OCREngineSettings(defaults: defaults)
        #expect(settings.kind == .modelServer)
        #expect(settings.serverPreset == .ollama)
        settings.serverPreset = .lmStudio
        #expect(settings.serverBaseURL.absoluteString == "http://localhost:1234")
        settings.serverBaseURL = URL(string: "http://studio.local:8080")!
        #expect(settings.serverPreset == .custom)
        // A test instance never touches the keychain.
        settings.serverAPIKey = "secret"
        #expect(OCREngineSettings(defaults: defaults).serverAPIKey == "")
    }

    // MARK: Circuit breaker

    private struct FailingTranscriber: PageTranscribing {
        let counter: Counter
        var modelName: String { "broken" }
        func transcribe(_ image: CGImage, orientation: CGImagePropertyOrientation, prompt: String) async throws -> String {
            await counter.increment()
            throw ModelTranscriptionError.serverUnreachable(address: "http://localhost:1")
        }
    }

    private actor Counter {
        private(set) var value = 0
        func increment() { value += 1 }
    }

    @Test func repeatedFailuresStopFurtherAttempts() async {
        let counter = Counter()
        let guarded = GuardedTranscriber(FailingTranscriber(counter: counter))
        let image = Fixtures.scanImage(width: 64, height: 64, columns: [])
        for _ in 0..<6 {
            _ = try? await guarded.transcribe(image, orientation: .up, prompt: "")
        }
        // Three real attempts, then the breaker answers for the server.
        #expect(await counter.value == GuardedTranscriber.failureLimit)
        #expect(guarded.isSuspended)
        await #expect(throws: ModelTranscriptionError.self) {
            _ = try await guarded.transcribe(image, orientation: .up, prompt: "")
        }
    }

    @Test(.timeLimit(.minutes(3)))
    func aFailingModelFallsBackToVisionAndSaysSo() async throws {
        var configuration = OCREngineConfiguration.default
        configuration.kind = .modelServer
        configuration.transformerTimeout = 5
        let image = Fixtures.scanImage(width: 1300, height: 1650, columns: [(0.1, 0.8, "FALLBACK HEADING")])
        let transcriber = GuardedTranscriber(FailingTranscriber(counter: Counter()))
        let recognized = try await OCRService.recognize(image, fileName: "page.jpg", configuration: configuration, transcriber: transcriber)
        #expect(recognized.text.contains("FALLBACK"))
        #expect(recognized.ocrEngine.hasPrefix("vision(fallback:"))
        #expect(recognized.visionLayoutData != nil)
    }
}
