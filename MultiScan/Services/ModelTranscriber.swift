//
//  ModelTranscriber.swift
//  MultiScan
//
//  Transformer-based page transcription — the alternative to Vision as the *primary* OCR engine.
//
//  Two concrete transcribers, one protocol:
//  - `CoreAITranscriber` — an on-device model exported with Apple's `coreai-models` tooling (`.aimodel` + tokenizer in a resource folder), loaded through `CoreAILanguageModel(resourcesAt:)` and driven with the Foundation Models `LanguageModelSession` API. Compiled only when the `CoreAILanguageModels` module is present (`canImport`), i.e. once the `https://github.com/apple/coreai-models` package is added to the app target; until then the factory returns the explanatory `CoreAIUnavailableTranscriber`.
//  - `LMStudioTranscriber` — macOS: talks to LM Studio's local server over its OpenAI-compatible HTTP API (`POST {base}/v1/chat/completions`), sending the page as a base64 JPEG `image_url` part. Any server speaking that dialect works (Ollama, llama.cpp's server, …); LM Studio is just the one the settings UI names.
//
//  Both return **markdown**; `MarkdownTranscriptConverter` turns it into stored attributed text. `OCRService` runs Vision first regardless and falls back to Vision's transcript if a transcriber throws or times out.
//
//  ## Why not a `LanguageModel` conformance for LM Studio?
//  Foundation Models (27) has a public `LanguageModel` / `LanguageModelExecutor` protocol pair, so an LM Studio adapter *could* plug into `LanguageModelSession` exactly like `CoreAILanguageModel` does — one session API for all three engines, with guided generation and tool calling for free. That is the right end state. It is not in 2.1 because the executor's streaming channel (`LanguageModelExecutorGenerationChannel.Response.Action`) and the way image attachments appear in `Transcript` could not be verified against the headers from here; a direct HTTP client is small, testable, and reviewable now. The adapter is sketched in `LMStudioLanguageModel.md` notes at the bottom of this file.
//
//  Shipping downloadable models (Background Assets) is out of scope here; `OCREngineConfiguration.coreAIModelURL` just points at a folder, wherever it came from.
//

import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import os

// MARK: - Protocol

/// A page-image → markdown transcriber. `Sendable` so `OCRService`'s `@concurrent` stage can hold one.
nonisolated protocol PageTranscribing: Sendable {
    /// Human-readable model identifier recorded in `Page.ocrEngine`.
    var modelName: String { get }

    /// Transcribes one upright page image to GitHub-flavored markdown.
    /// - Parameters:
    ///   - image: the page bitmap; `orientation` tells the model how to turn it upright (`.up` after Smart Separate has already oriented a crop).
    ///   - prompt: the user-editable instruction (`OCREngineConfiguration.transcriptionPrompt`).
    func transcribe(_ image: CGImage, orientation: CGImagePropertyOrientation, prompt: String) async throws -> String
}

nonisolated enum ModelTranscriptionError: LocalizedError, Sendable {
    case coreAIUnavailable(reason: String)
    case modelNotConfigured
    case server(status: Int, body: String)
    case malformedResponse
    case emptyTranscript
    case imageEncodingFailed
    case timedOut(TimeInterval)

    var errorDescription: String? {
        switch self {
        case .coreAIUnavailable(let reason):
            return String(localized: "The on-device model can't run: \(reason)")
        case .modelNotConfigured:
            return String(localized: "No OCR model is configured.")
        case .server(let status, let body):
            return String(localized: "The model server returned \(status): \(body.prefix(200))")
        case .malformedResponse:
            return String(localized: "The model server's response could not be read.")
        case .emptyTranscript:
            return String(localized: "The model returned no text for this page.")
        case .imageEncodingFailed:
            return String(localized: "The page image could not be encoded for the model.")
        case .timedOut(let seconds):
            return String(localized: "The model didn't answer within \(Int(seconds)) seconds.")
        }
    }
}

// MARK: - Factory

nonisolated enum ModelTranscriber {
    static let logger = Logger(subsystem: "co.jservices.MultiScan", category: "ModelTranscriber")

    /// The transcriber for `configuration`, or `nil` when the configuration says Vision only.
    static func make(for configuration: OCREngineConfiguration) -> (any PageTranscribing)? {
        switch configuration.kind {
        case .vision:
            return nil
        case .coreAI:
            guard let url = configuration.coreAIModelURL else { return nil }
            #if canImport(CoreAILanguageModels) && canImport(FoundationModels)
            return CoreAITranscriber(resourcesURL: url)
            #else
            return CoreAIUnavailableTranscriber(resourcesURL: url)
            #endif
        case .lmStudio:
            return LMStudioTranscriber(baseURL: configuration.lmStudioBaseURL, modelID: configuration.lmStudioModelID)
        }
    }

    /// Runs `operation` with a deadline. Transformers can hang on a pathological page; the pipeline must keep moving.
    static func withTimeout<T: Sendable>(_ seconds: TimeInterval, _ operation: @Sendable @escaping () async throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(for: .seconds(seconds))
                throw ModelTranscriptionError.timedOut(seconds)
            }
            // First to finish wins; cancel the other.
            guard let result = try await group.next() else { throw ModelTranscriptionError.timedOut(seconds) }
            group.cancelAll()
            return result
        }
    }

    /// Downscaled, upright JPEG of `image` for sending to a model. Vision-language models work on ~1–2 MP inputs; sending a 12 MP HEIC wastes bandwidth and context.
    static func jpegForModel(_ image: CGImage, orientation: CGImagePropertyOrientation, maxPixelSize: Int = 2048, quality: CGFloat = 0.85) -> Data? {
        // Route through ImageIO's thumbnail path so EXIF orientation is applied and the downscale is a single pass.
        guard let intermediate = PlatformImage.encode(image, as: .jpeg, quality: 1.0),
              let source = CGImageSourceCreateWithData(intermediate as CFData, nil) else { return nil }
        // The intermediate JPEG has no orientation tag; orient after downscaling.
        guard let small = PlatformImage.thumbnail(from: source, maxPixelSize: maxPixelSize) else { return nil }
        let upright = PlatformImage.oriented(small, orientation) ?? small
        return PlatformImage.encode(upright, as: .jpeg, quality: quality)
    }
}

// MARK: - LM Studio (OpenAI-compatible HTTP)

/// Chat-completions client for a local OpenAI-compatible server. Non-streaming: one request, one JSON answer per page.
nonisolated struct LMStudioTranscriber: PageTranscribing {
    let baseURL: URL
    let modelID: String

    var modelName: String { modelID.isEmpty ? "lmstudio-default" : modelID }

    private var completionsURL: URL { baseURL.appending(path: "v1/chat/completions") }

    func transcribe(_ image: CGImage, orientation: CGImagePropertyOrientation, prompt: String) async throws -> String {
        guard let jpeg = ModelTranscriber.jpegForModel(image, orientation: orientation) else {
            throw ModelTranscriptionError.imageEncodingFailed
        }
        let body = ChatRequest(
            model: modelID.isEmpty ? nil : modelID,
            messages: [
                .init(role: "user", content: [
                    .text(prompt),
                    .imageURL("data:image/jpeg;base64," + jpeg.base64EncodedString())
                ])
            ],
            temperature: 0,
            stream: false
        )

        var request = URLRequest(url: completionsURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(body)
        // LM Studio has no auth by default; an API key field can be added to the settings if the server requires one.

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw ModelTranscriptionError.malformedResponse }
        guard (200..<300).contains(http.statusCode) else {
            throw ModelTranscriptionError.server(status: http.statusCode, body: String(decoding: data, as: UTF8.self))
        }
        let decoded = try JSONDecoder().decode(ChatResponse.self, from: data)
        guard let content = decoded.choices.first?.message.content?.trimmingCharacters(in: .whitespacesAndNewlines) else {
            throw ModelTranscriptionError.malformedResponse
        }
        guard !content.isEmpty else { throw ModelTranscriptionError.emptyTranscript }
        return content
    }

    /// `GET {base}/v1/models` → model identifiers, for the settings picker and the "Test Connection" button.
    static func listModels(baseURL: URL) async throws -> [String] {
        let (data, response) = try await URLSession.shared.data(from: baseURL.appending(path: "v1/models"))
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw ModelTranscriptionError.server(status: (response as? HTTPURLResponse)?.statusCode ?? 0, body: String(decoding: data, as: UTF8.self))
        }
        return try JSONDecoder().decode(ModelList.self, from: data).data.map(\.id)
    }

    // MARK: Wire types (OpenAI chat-completions dialect)

    struct ChatRequest: Encodable {
        struct Message: Encodable {
            enum Part: Encodable {
                case text(String)
                case imageURL(String)

                func encode(to encoder: Encoder) throws {
                    var container = encoder.container(keyedBy: CodingKeys.self)
                    switch self {
                    case .text(let text):
                        try container.encode("text", forKey: .type)
                        try container.encode(text, forKey: .text)
                    case .imageURL(let url):
                        try container.encode("image_url", forKey: .type)
                        try container.encode(["url": url], forKey: .imageURL)
                    }
                }

                enum CodingKeys: String, CodingKey {
                    case type, text
                    case imageURL = "image_url"
                }
            }
            let role: String
            let content: [Part]
        }
        let model: String?
        let messages: [Message]
        let temperature: Double
        let stream: Bool
    }

    struct ChatResponse: Decodable {
        struct Choice: Decodable {
            struct Message: Decodable {
                let content: String?
            }
            let message: Message
        }
        let choices: [Choice]
    }

    struct ModelList: Decodable {
        struct Model: Decodable { let id: String }
        let data: [Model]
    }
}

// MARK: - Core AI (on device, through Foundation Models)

#if canImport(CoreAILanguageModels) && canImport(FoundationModels)
import FoundationModels
import CoreAILanguageModels

/// Keeps the (slow to load) Core AI model alive across pages of an import.
actor CoreAIModelCache {
    static let shared = CoreAIModelCache()
    private var loaded: (url: URL, model: CoreAILanguageModel)?

    func model(at url: URL) async throws -> CoreAILanguageModel {
        if let loaded, loaded.url == url { return loaded.model }
        // Specialization + tokenizer load; can take a while the first time (ahead-of-time compiled models are much faster).
        let model = try await CoreAILanguageModel(resourcesAt: url)
        loaded = (url, model)
        return model
    }
}

nonisolated struct CoreAITranscriber: PageTranscribing {
    let resourcesURL: URL

    var modelName: String { resourcesURL.lastPathComponent }

    func transcribe(_ image: CGImage, orientation: CGImagePropertyOrientation, prompt: String) async throws -> String {
        let model = try await CoreAIModelCache.shared.model(at: resourcesURL)
        // A fresh session per page: no conversation to carry, and the context window stays empty for the image.
        let session = LanguageModelSession(model: model)
        let response = try await session.respond(options: GenerationOptions(samplingMode: .greedy)) {
            prompt
            // Foundation Models applies the orientation before the model sees the pixels.
            Attachment(image, orientation: orientation)
        }
        let content = response.content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !content.isEmpty else { throw ModelTranscriptionError.emptyTranscript }
        return content
    }
}
#else
/// Stands in for `CoreAITranscriber` until the `coreai-models` package is linked. Throws immediately, so `OCRService` falls back to Vision and the page records why.
nonisolated struct CoreAIUnavailableTranscriber: PageTranscribing {
    let resourcesURL: URL
    var modelName: String { resourcesURL.lastPathComponent }

    func transcribe(_ image: CGImage, orientation: CGImagePropertyOrientation, prompt: String) async throws -> String {
        throw ModelTranscriptionError.coreAIUnavailable(
            reason: "the CoreAILanguageModels module isn't linked. Add the coreai-models Swift package (File ▸ Add Package Dependencies ▸ https://github.com/apple/coreai-models, product CoreAILM) to the MultiScan target."
        )
    }
}
#endif

/*
 ## Notes: an LM Studio `LanguageModel` adapter (follow-up)

 The Foundation Models framework in 27 lets any backend be a `LanguageModel`:

     struct LMStudioLanguageModel: LanguageModel {
         typealias Executor = LMStudioExecutor
         var capabilities: LanguageModelCapabilities { LanguageModelCapabilities([.guidedGeneration]) }   // tool calling later
         var executorConfiguration: LMStudioExecutor.Configuration                                        // base URL + model id
     }

     struct LMStudioExecutor: LanguageModelExecutor {
         struct Configuration: Hashable, Sendable { var baseURL: URL; var modelID: String }
         typealias Model = LMStudioLanguageModel
         init(configuration: Configuration) throws
         func prewarm(model: Model, transcript: Transcript) { /* GET /v1/models to warm the connection */ }
         func respond(to request: LanguageModelExecutorGenerationRequest, model: Model, streamingInto channel: LanguageModelExecutorGenerationChannel) async throws {
             // 1. Map request.transcript entries → OpenAI messages:
             //      .instructions → system, .prompt → user (text segments → text parts, attachment segments with image content → image_url parts),
             //      .response → assistant, .toolCalls/.toolOutput → tool messages.
             // 2. request.schema != nil → ask for JSON (response_format / grammar) so guided generation decodes.
             // 3. Stream SSE deltas; for each delta send a response event appending a TextFragment through `channel`:
             //      await channel.send(.response(entryID: id, action: <append-text-fragment action>))
             //    and report usage at the end.
         }
     }

 Then `LanguageModelSession(model: LMStudioLanguageModel(...))` replaces `LMStudioTranscriber`, and `ProjectTitleSuggester`
 could use the same local server when Apple Intelligence is unavailable. Blocked on confirming the exact `Response.Action`
 case for appending text and how `Transcript.AttachmentSegment` exposes image bytes; both are a header lookup away in Xcode.
 */
