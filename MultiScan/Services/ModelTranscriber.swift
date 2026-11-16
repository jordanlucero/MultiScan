//
//  ModelTranscriber.swift
//  MultiScan
//
//  Transformer-based page transcription — the alternative to Vision as the *primary* OCR engine.
//
//  Two concrete transcribers, one protocol:
//  - `CoreAITranscriber` — an on-device model exported with Apple's `coreai-models` tooling (`.aimodel` + tokenizer in a resource folder), loaded through `CoreAILanguageModel(resourcesAt:)` and driven with the Foundation Models `LanguageModelSession` API. Compiled only when the `CoreAILanguageModels` module is present (`canImport`), i.e. once the `https://github.com/apple/coreai-models` package is added to the app target; until then the factory returns the explanatory `CoreAIUnavailableTranscriber`.
//  - `ModelServerTranscriber` — macOS: talks to a model server over the OpenAI-compatible HTTP API (`POST {base}/v1/chat/completions`), sending the page as a base64 JPEG `image_url` part. LM Studio and Ollama are presets in Settings; llama.cpp's server, mlx-lm, Jan, or a machine elsewhere on the network work the same way.
//
//  Both return **markdown**; `MarkdownTranscriptConverter` turns it into stored attributed text. `OCRService` runs Vision first regardless and falls back to Vision's transcript if a transcriber throws or times out.
//
//  ## What the app needs for the server engine to work at all
//  - **App Sandbox ▸ Outgoing Connections (Client)** on macOS — `ENABLE_OUTGOING_NETWORK_CONNECTIONS` in the target's build settings. Without it the sandbox refuses the connection before it leaves the process (this was missing; every request failed). Granted to Debug builds only while the engine picker is Debug-only.
//  - **`NSAllowsLocalNetworking`** in `Info.plist` — App Transport Security otherwise blocks plain `http://` to a local server. It covers loopback, `.local` names, and local IP addresses only; ATS stays on for everything else.
//  - **`NSLocalNetworkUsageDescription`** — the system asks before the app may reach another device on the local network (not needed for a server on the same Mac).
//
//  ## How the client behaves
//  - **Streaming.** The request asks for a server-sent-event stream and assembles the answer from the deltas. A vision model can take a minute on a dense page; with a single buffered response the connection sits silent that whole time and trips `URLSession`'s idle timeout long before the per-page deadline. A server that ignores `stream` and answers with one JSON body is handled too.
//  - **One deadline.** `withTimeout` (the user's "timeout per page") bounds the whole exchange and cancels the request; the request's own idle timeout is set just above it so the two never race.
//  - **Bounded output.** `max_tokens` caps a model that falls into a repetition loop instead of letting it run to the deadline.
//  - **Tidy transcripts.** `cleanedTranscript` drops a reasoning model's `<think>…</think>` preamble and the code fence some models wrap their whole answer in.
//  - **Errors a person can act on.** "Couldn't reach the model server at … — is it running?" rather than a URL error code; the server's own error message when it sends one.
//  - **Circuit breaker.** `GuardedTranscriber` stops calling a transcriber after three consecutive failures, so an import of 300 pages against a server that went away costs three failures, not 300 timeouts. The remaining pages keep Vision's text and say why in `Page.ocrEngine`.
//
//  ## Why not a `LanguageModel` conformance for the server?
//  Foundation Models (27) has a public `LanguageModel` / `LanguageModelExecutor` protocol pair, so a server adapter *could* plug into `LanguageModelSession` exactly like `CoreAILanguageModel` does — one session API for all three engines, with guided generation and tool calling for free. That is a reasonable end state, deliberately not taken yet: a direct HTTP client is small, testable, and has no user-visible downside today. The adapter is sketched in the notes at the bottom of this file.
//
//  Shipping downloadable models (Background Assets) is out of scope here; `OCREngineConfiguration.coreAIModelURL` just points at a folder, wherever it came from.
//

import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import Security
import os

// MARK: - Protocol

/// A page-image → markdown transcriber. `Sendable` so `OCRService`'s `@concurrent` stage can hold one.
nonisolated protocol PageTranscribing: Sendable {
    /// Human-readable model identifier recorded in `Page.ocrEngine`.
    var modelName: String { get }

    /// Transcribes one upright page image to GitHub-flavored markdown.
    /// - Parameters:
    ///   - image: the page bitmap; `orientation` tells the model how to turn it upright (`OCRService` hands over upright bitmaps, so this is `.up` in practice).
    ///   - prompt: the user-editable instruction (`OCREngineConfiguration.transcriptionPrompt`).
    func transcribe(_ image: CGImage, orientation: CGImagePropertyOrientation, prompt: String) async throws -> String
}

nonisolated enum ModelTranscriptionError: LocalizedError, Sendable {
    case coreAIUnavailable(reason: String)
    case modelNotConfigured
    case serverUnreachable(address: String)
    case server(status: Int, message: String)
    case malformedResponse
    case emptyTranscript
    case imageEncodingFailed
    case timedOut(TimeInterval)
    /// The circuit breaker opened: earlier pages failed, so this one wasn't attempted.
    case suspended(after: String)

    var errorDescription: String? {
        switch self {
        case .coreAIUnavailable(let reason):
            return String(localized: "The on-device model can't run: \(reason)")
        case .modelNotConfigured:
            return String(localized: "No OCR model is configured.")
        case .serverUnreachable(let address):
            return String(localized: "Couldn't reach the model server at \(address). Is it running?")
        case .server(let status, let message):
            return String(localized: "The model server returned \(status): \(message)")
        case .malformedResponse:
            return String(localized: "The model server's response could not be read.")
        case .emptyTranscript:
            return String(localized: "The model returned no text for this page.")
        case .imageEncodingFailed:
            return String(localized: "The page image could not be encoded for the model.")
        case .timedOut(let seconds):
            return String(localized: "The model didn't answer within \(Int(seconds)) seconds.")
        case .suspended(let reason):
            return String(localized: "The model was skipped after repeated failures (\(reason)).")
        }
    }
}

// MARK: - Factory

nonisolated enum ModelTranscriber {
    static let logger = Logger(subsystem: "co.jservices.MultiScan", category: "ModelTranscriber")

    /// The transcriber for `configuration`, or `nil` when the configuration says Vision only. Each call returns a fresh circuit breaker, so make one per import (or per one-off page operation) and reuse it for that work.
    static func make(for configuration: OCREngineConfiguration) -> (any PageTranscribing)? {
        switch configuration.kind {
        case .vision:
            return nil
        case .coreAI:
            guard let url = configuration.coreAIModelURL else { return nil }
            #if canImport(CoreAILanguageModels) && canImport(FoundationModels)
            return GuardedTranscriber(CoreAITranscriber(resourcesURL: url))
            #else
            return GuardedTranscriber(CoreAIUnavailableTranscriber(resourcesURL: url))
            #endif
        case .modelServer:
            return GuardedTranscriber(ModelServerTranscriber(
                baseURL: configuration.serverBaseURL,
                modelID: configuration.serverModelID,
                apiKey: configuration.serverAPIKey,
                idleTimeout: configuration.transformerTimeout + 15
            ))
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
            defer { group.cancelAll() }
            guard let result = try await group.next() else { throw ModelTranscriptionError.timedOut(seconds) }
            return result
        }
    }

    /// Downscaled, upright JPEG of `image` for sending to a model. Vision-language models work on ~1–2 MP inputs; sending a 12 MP scan wastes bandwidth and context.
    static func jpegForModel(_ image: CGImage, orientation: CGImagePropertyOrientation, maxPixelSize: Int = 2048, quality: CGFloat = 0.85) -> Data? {
        guard let upright = PlatformImage.oriented(image, orientation) else { return nil }
        return PlatformImage.thumbnailData(of: upright, maxPixelSize: maxPixelSize, as: .jpeg, quality: quality)
    }

    /// A model's answer with the wrapping some models add removed: a reasoning model's `<think>…</think>` block, and a code fence around the *whole* answer (```` ```markdown … ``` ````). Fences inside the transcript are left alone — they may be the page's content.
    static func cleanedTranscript(_ raw: String) -> String {
        var text = raw

        // Reasoning preamble. An unterminated block (the model ran out of tokens while thinking) leaves nothing usable.
        while let open = text.range(of: "<think>", options: .caseInsensitive) {
            if let close = text.range(of: "</think>", options: .caseInsensitive, range: open.upperBound..<text.endIndex) {
                text.removeSubrange(open.lowerBound..<close.upperBound)
            } else {
                text.removeSubrange(open.lowerBound..<text.endIndex)
            }
        }
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)

        // One fence around everything.
        if text.hasPrefix("```"), text.hasSuffix("```"), text.count > 6 {
            var lines = text.components(separatedBy: "\n")
            if lines.count >= 2, lines.last?.trimmingCharacters(in: .whitespaces) == "```" {
                let opener = lines.removeFirst().dropFirst(3).trimmingCharacters(in: .whitespaces).lowercased()
                lines.removeLast()
                let inner = lines.joined(separator: "\n")
                // Only unwrap a fence that labels the answer as markdown/text (or is unlabeled) and isn't the first of several.
                if ["", "markdown", "md", "text"].contains(opener), !inner.contains("```") {
                    text = inner.trimmingCharacters(in: .whitespacesAndNewlines)
                }
            }
        }
        return text
    }
}

// MARK: - Circuit breaker

/// Wraps a transcriber and stops calling it after `failureLimit` consecutive failures; later calls throw `.suspended` immediately. A success resets the count. One per import, so each import starts with a clean slate.
nonisolated final class GuardedTranscriber: PageTranscribing {
    static let failureLimit = 3

    private let base: any PageTranscribing
    private let state = OSAllocatedUnfairLock(initialState: (failures: 0, lastError: ""))

    init(_ base: any PageTranscribing) {
        self.base = base
    }

    var modelName: String { base.modelName }

    /// `true` once the breaker has opened.
    var isSuspended: Bool {
        state.withLock { $0.failures >= Self.failureLimit }
    }

    func transcribe(_ image: CGImage, orientation: CGImagePropertyOrientation, prompt: String) async throws -> String {
        let (failures, lastError) = state.withLock { ($0.failures, $0.lastError) }
        if failures >= Self.failureLimit {
            throw ModelTranscriptionError.suspended(after: lastError)
        }
        do {
            let result = try await base.transcribe(image, orientation: orientation, prompt: prompt)
            state.withLock { $0.failures = 0 }
            return result
        } catch is CancellationError {
            throw CancellationError()
        } catch ModelTranscriptionError.emptyTranscript {
            // The model answered; a blank page isn't the model being broken.
            state.withLock { $0.failures = 0 }
            throw ModelTranscriptionError.emptyTranscript
        } catch {
            state.withLock {
                $0.failures += 1
                $0.lastError = String(error.localizedDescription.prefix(60))
            }
            throw error
        }
    }
}

// MARK: - Model server (OpenAI-compatible HTTP)

/// Chat-completions client for a server speaking the OpenAI dialect (LM Studio, Ollama, llama.cpp, mlx-lm, …). One request per page, streamed.
nonisolated struct ModelServerTranscriber: PageTranscribing {
    let baseURL: URL
    let modelID: String
    var apiKey: String?
    /// Seconds the connection may sit silent (a model loading, or thinking before its first token). Kept above the per-page deadline so that deadline is the one that fires.
    var idleTimeout: TimeInterval = 135

    /// Upper bound on the answer. A full, dense page is on the order of 1,500 tokens; this leaves room for tables while stopping a repetition loop.
    static let maxOutputTokens = 8192

    var modelName: String { modelID.isEmpty ? "default" : modelID }

    /// No caching, no cookies, and fail straight away when the server isn't there instead of waiting for connectivity.
    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.waitsForConnectivity = false
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        configuration.httpShouldSetCookies = false
        return URLSession(configuration: configuration)
    }()

    /// `{base}/v1/<path>`, tolerating a base the user typed with a trailing slash or with `/v1` already on it.
    static func endpoint(_ path: String, base: URL) -> URL {
        var root = base
        if root.lastPathComponent == "v1" { root = root.deletingLastPathComponent() }
        return root.appending(path: "v1").appending(path: path)
    }

    private func authorized(_ request: URLRequest) -> URLRequest {
        var request = request
        if let apiKey, !apiKey.isEmpty {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        return request
    }

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
            maxTokens: Self.maxOutputTokens,
            stream: true
        )

        var request = URLRequest(url: Self.endpoint("chat/completions", base: baseURL))
        request.httpMethod = "POST"
        request.timeoutInterval = idleTimeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream, application/json", forHTTPHeaderField: "Accept")
        request.httpBody = try JSONEncoder().encode(body)
        request = authorized(request)

        let content: String
        do {
            let (bytes, response) = try await Self.session.bytes(for: request)
            guard let http = response as? HTTPURLResponse else { throw ModelTranscriptionError.malformedResponse }
            guard (200..<300).contains(http.statusCode) else {
                var data = Data()
                for try await byte in bytes.prefix(16_384) { data.append(byte) }
                throw ModelTranscriptionError.server(status: http.statusCode, message: Self.errorMessage(from: data))
            }
            content = try await Self.collect(bytes, contentType: http.value(forHTTPHeaderField: "Content-Type") ?? "")
        } catch let error as URLError {
            throw Self.transcriptionError(for: error, address: baseURL.absoluteString)
        }

        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw ModelTranscriptionError.emptyTranscript }
        return trimmed
    }

    /// Assembles the answer from a server-sent-event stream — or, when the server ignored `stream` and sent one JSON document, from that.
    static func collect<Bytes: AsyncSequence & Sendable>(_ bytes: Bytes, contentType: String) async throws -> String where Bytes.Element == UInt8 {
        var eventText = ""
        var raw = Data()
        var sawEvent = false
        var line = Data()

        func consume(_ lineData: Data) throws -> Bool {
            guard let text = String(data: lineData, encoding: .utf8) else { return false }
            let trimmed = text.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("data:") else { return false }
            sawEvent = true
            let payload = trimmed.dropFirst(5).trimmingCharacters(in: .whitespaces)
            if payload == "[DONE]" { return true }
            guard let data = payload.data(using: .utf8) else { return false }
            if let chunk = try? JSONDecoder().decode(StreamChunk.self, from: data) {
                if let delta = chunk.choices.first?.delta?.content { eventText += delta }
            } else if let failure = try? JSONDecoder().decode(ErrorEnvelope.self, from: data) {
                throw ModelTranscriptionError.server(status: 200, message: failure.error.message)
            }
            return false
        }

        for try await byte in bytes {
            try Task.checkCancellation()
            raw.append(byte)
            if byte == UInt8(ascii: "\n") {
                if try consume(line) { return eventText }
                line.removeAll(keepingCapacity: true)
            } else if byte != UInt8(ascii: "\r") {
                line.append(byte)
            }
        }
        if !line.isEmpty, try consume(line) { return eventText }
        if sawEvent { return eventText }

        // Not an event stream: a single chat-completion document.
        if let response = try? JSONDecoder().decode(ChatResponse.self, from: raw), let content = response.choices.first?.message.content {
            return content
        }
        if let failure = try? JSONDecoder().decode(ErrorEnvelope.self, from: raw) {
            throw ModelTranscriptionError.server(status: 200, message: failure.error.message)
        }
        throw ModelTranscriptionError.malformedResponse
    }

    /// `GET {base}/v1/models` → model identifiers, for the settings picker and the "Test Connection" button.
    static func listModels(baseURL: URL, apiKey: String? = nil) async throws -> [String] {
        var request = URLRequest(url: endpoint("models", base: baseURL))
        request.timeoutInterval = 10
        if let apiKey, !apiKey.isEmpty { request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization") }
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw ModelTranscriptionError.malformedResponse }
            guard (200..<300).contains(http.statusCode) else {
                throw ModelTranscriptionError.server(status: http.statusCode, message: errorMessage(from: data))
            }
            guard let list = try? JSONDecoder().decode(ModelList.self, from: data) else { throw ModelTranscriptionError.malformedResponse }
            return list.data.map(\.id)
        } catch let error as URLError {
            throw transcriptionError(for: error, address: baseURL.absoluteString)
        }
    }

    /// The server's own explanation when it sends the OpenAI error shape; otherwise the start of whatever it sent.
    static func errorMessage(from data: Data) -> String {
        if let failure = try? JSONDecoder().decode(ErrorEnvelope.self, from: data) { return failure.error.message }
        return String(String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines).prefix(200))
    }

    static func transcriptionError(for error: URLError, address: String) -> Error {
        switch error.code {
        case .cancelled:
            return CancellationError()
        case .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed, .networkConnectionLost, .notConnectedToInternet, .secureConnectionFailed, .appTransportSecurityRequiresSecureConnection:
            return ModelTranscriptionError.serverUnreachable(address: address)
        case .timedOut:
            return ModelTranscriptionError.serverUnreachable(address: address)
        default:
            return error
        }
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
        let maxTokens: Int
        let stream: Bool

        enum CodingKeys: String, CodingKey {
            case model, messages, temperature, stream
            case maxTokens = "max_tokens"
        }
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

    /// One `data:` event of a streamed completion.
    struct StreamChunk: Decodable {
        struct Choice: Decodable {
            struct Delta: Decodable {
                let content: String?
            }
            let delta: Delta?
        }
        let choices: [Choice]
    }

    struct ErrorEnvelope: Decodable {
        struct Failure: Decodable { let message: String }
        let error: Failure
    }

    struct ModelList: Decodable {
        struct Model: Decodable { let id: String }
        let data: [Model]
    }
}

// MARK: - API key storage

/// The model server's optional API key, in the keychain (a generic password owned by the app). Local servers rarely need one; when they do it is still a credential and doesn't belong in UserDefaults.
nonisolated enum ModelServerCredentialStore {
    private static let service = "co.jservices.MultiScan.model-server"
    private static let account = "api-key"

    private static var baseQuery: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
    }

    static func load() -> String? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Stores `key`; an empty key removes the item.
    static func save(_ key: String) {
        SecItemDelete(baseQuery as CFDictionary)
        guard !key.isEmpty, let data = key.data(using: .utf8) else { return }
        var attributes = baseQuery
        attributes[kSecValueData as String] = data
        SecItemAdd(attributes as CFDictionary, nil)
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
 ## Notes: a model-server `LanguageModel` adapter (follow-up)

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

 Then `LanguageModelSession(model: LMStudioLanguageModel(...))` replaces `ModelServerTranscriber`, and `ProjectTitleSuggester`
 could use the same local server when Apple Intelligence is unavailable. Blocked on confirming the exact `Response.Action`
 case for appending text and how `Transcript.AttachmentSegment` exposes image bytes; both are a header lookup away in Xcode.
 */
