//
//  OCREngine.swift
//  MultiScan
//
//  Which engine turns a page image into text, and the user's configuration for it.
//
//  ## The model
//  - **Vision always runs.** Every import produces a `VisionDocumentLayout` (paragraphs, lines, tables, regions) and Vision's transcript, stored on the page whatever the primary engine is. Smart Separate, inline tables, and the layout-aware features depend on that geometry, and keeping Vision's text around means a transformer's hallucination is always one tap from the conventional read.
//  - **The primary engine decides what goes into `richTextData`.** With `.vision` that is Vision's transcript on the storage font. With a transformer engine the model is asked for *markdown* (headings, emphasis, lists, tables — the structure OCR traditionally loses), which `MarkdownTranscriptConverter` turns into the TextKit attributed string MultiScan already stores.
//
//  ## Engines
//  | Kind        | Runs where                           | How                                                                |
//  |-------------|--------------------------------------|--------------------------------------------------------------------|
//  | `vision`    | on device, every platform            | `VisionDocumentRecognizer` (RecognizeDocumentsRequest)             |
//  | `coreAI`    | on device, every platform            | a `.aimodel` resource folder loaded through `CoreAILanguageModel` into a Foundation Models `LanguageModelSession`, prompted with the page image (requires the `coreai-models` package — see `ModelTranscriber.swift`) |
//  | `modelServer` | macOS, talking to a model server   | OpenAI-compatible `POST /v1/chat/completions` (streamed) with the page image as a base64 `image_url`. LM Studio and Ollama are presets; any server speaking that dialect works (llama.cpp's server, mlx-lm, Jan, a machine elsewhere on the network) |
//
//  ## Configuration storage
//  `OCREngineSettings` is the usual `@Observable` + UserDefaults write-through object (see `Preferences.swift` for the pattern). It is read once per import by `ProjectImportPipeline`, so flipping the engine mid-import doesn't change engines halfway through a project.
//
//  2.0 ships the picker in **DEBUG builds only** (Settings ▸ OCR Engine). Release builds always use Vision until a downloadable model exists. The macOS sandbox's outgoing-network entitlement that the model server needs is likewise granted to Debug builds only (`ENABLE_OUTGOING_NETWORK_CONNECTIONS[config=Debug]`); when the engine ships, drop the condition.
//

import Foundation
import Observation

/// The primary OCR engine.
nonisolated enum OCREngineKind: String, CaseIterable, Codable, Sendable {
    case vision
    case coreAI
    /// A model server speaking the OpenAI chat-completions dialect over HTTP (LM Studio, Ollama, …).
    case modelServer

    /// Reads a stored engine choice, accepting the name this case had while LM Studio was the only server ("lmStudio").
    init?(storedValue: String) {
        self.init(rawValue: storedValue == "lmStudio" ? OCREngineKind.modelServer.rawValue : storedValue)
    }

    var label: LocalizedStringResource {
        switch self {
        case .vision: LocalizedStringResource("Apple Vision", comment: "OCR engine name")
        case .coreAI: LocalizedStringResource("On-device model (Core AI)", comment: "OCR engine name")
        case .modelServer: LocalizedStringResource("Local model server", comment: "OCR engine name")
        }
    }

    /// Engines that can run on the current platform at all.
    static var availableOnThisPlatform: [OCREngineKind] {
        #if os(macOS)
        return allCases
        #else
        // A phone can't host a model server; the setting would be a trap.
        return [.vision, .coreAI]
        #endif
    }

    /// The string recorded in `Page.ocrEngine` so a page remembers what produced its text.
    func provenanceIdentifier(modelName: String?) -> String {
        switch self {
        case .vision: return "vision"
        case .coreAI: return "coreai:" + (modelName ?? "unknown")
        // (Pages read while this engine was called "LM Studio" carry "lmstudio:<model>"; both just mean "not Vision" to the app.)
        case .modelServer: return "server:" + (modelName ?? "unknown")
        }
    }
}

/// Model servers MultiScan knows the default address of. They all speak the same OpenAI-compatible API; a preset only fills in the URL.
nonisolated enum ModelServerPreset: String, CaseIterable, Sendable {
    case lmStudio
    case ollama
    case custom

    var label: LocalizedStringResource {
        switch self {
        case .lmStudio: LocalizedStringResource("LM Studio", comment: "Model server preset")
        case .ollama: LocalizedStringResource("Ollama", comment: "Model server preset")
        case .custom: LocalizedStringResource("Other", comment: "Model server preset: a custom address")
        }
    }

    /// The address the server listens on out of the box (`custom` has none of its own and reports LM Studio's).
    var baseURL: URL {
        switch self {
        case .lmStudio, .custom: URL(string: "http://localhost:1234")!
        case .ollama: URL(string: "http://localhost:11434")!
        }
    }
}

/// Everything a transcriber needs, as a value that can travel to the `@concurrent` OCR stage.
nonisolated struct OCREngineConfiguration: Equatable, Sendable {
    var kind: OCREngineKind

    /// Smart Separate: split a scan that shows two physical pages into two project pages, using Vision's layout.
    var smartSeparateEnabled: Bool

    /// Core AI: the exported model resource folder (the `.aimodel` plus tokenizer), chosen in the debug settings. `nil` → Vision fallback.
    var coreAIModelURL: URL?

    /// Model server: its root URL (the client appends `/v1/…`), the model's identifier (empty = let the server use whatever it has loaded), and an optional API key sent as a bearer token (local servers usually need none).
    var serverBaseURL: URL
    var serverModelID: String
    var serverAPIKey: String?

    /// The instruction sent to transformer engines. Users can tune it in the debug pane; the default asks for faithful markdown.
    var transcriptionPrompt: String

    /// Seconds to wait for a transformer response per page before falling back to Vision's text.
    var transformerTimeout: TimeInterval

    static let defaultPrompt = """
    You are transcribing one scanned page from a printed document. Output the page's text as GitHub-flavored Markdown and nothing else: no preamble, no commentary, no code fences around the whole answer.
    Rules: preserve the reading order; mark headings with #/##/###; use **bold** and *italic* only where the print does; reproduce bulleted and numbered lists; reproduce tables as Markdown tables; keep printed page numbers and running headers exactly as printed; do not correct spelling; if a region is an illustration or photo with no text, write a single line `[Illustration]`; if the page is blank, output nothing.
    """

    static let `default` = OCREngineConfiguration(
        kind: .vision,
        smartSeparateEnabled: false,
        coreAIModelURL: nil,
        serverBaseURL: ModelServerPreset.lmStudio.baseURL,
        serverModelID: "",
        serverAPIKey: nil,
        transcriptionPrompt: defaultPrompt,
        transformerTimeout: 120
    )

    /// Whether a transformer engine is selected *and* configured well enough to try.
    var usesTransformer: Bool {
        switch kind {
        case .vision: return false
        case .coreAI: return coreAIModelURL != nil
        case .modelServer: return true
        }
    }
}

/// The user's OCR engine preferences. One shared instance (like `NavigationSettings`): the import pipeline and the settings UI must agree.
@Observable
final class OCREngineSettings {
    static let shared = OCREngineSettings(defaults: .standard)

    private static let kindKey = "ocrEngineKind"
    private static let smartSeparateKey = "ocrSmartSeparateEnabled"
    private static let coreAIModelURLKey = "ocrCoreAIModelURL"
    // The two keys keep their original strings, so a server configured while this was the "LM Studio" engine carries over.
    private static let serverBaseURLKey = "ocrLMStudioBaseURL"
    private static let serverModelIDKey = "ocrLMStudioModelID"
    private static let promptKey = "ocrTranscriptionPrompt"
    private static let timeoutKey = "ocrTransformerTimeout"

    private let defaults: UserDefaults

    var kind: OCREngineKind {
        didSet { defaults.set(kind.rawValue, forKey: Self.kindKey) }
    }

    var smartSeparateEnabled: Bool {
        didSet { defaults.set(smartSeparateEnabled, forKey: Self.smartSeparateKey) }
    }

    /// Stored as a bookmark-free path string; the folder lives in the app's own container (Application Support/Models) so no security scope is needed.
    var coreAIModelURL: URL? {
        didSet { defaults.set(coreAIModelURL?.path, forKey: Self.coreAIModelURLKey) }
    }

    var serverBaseURL: URL {
        didSet { defaults.set(serverBaseURL.absoluteString, forKey: Self.serverBaseURLKey) }
    }

    var serverModelID: String {
        didSet { defaults.set(serverModelID, forKey: Self.serverModelIDKey) }
    }

    /// Optional bearer token for the model server. Kept in the keychain, not in UserDefaults; the shared instance loads it once and writes changes through.
    var serverAPIKey: String {
        didSet {
            guard persistsAPIKey, serverAPIKey != oldValue else { return }
            ModelServerCredentialStore.save(serverAPIKey)
        }
    }

    /// Only the instance backed by `UserDefaults.standard` touches the keychain; test instances keep the key in memory.
    private let persistsAPIKey: Bool

    /// The preset whose address is configured, or `.custom`.
    var serverPreset: ModelServerPreset {
        get { ModelServerPreset.allCases.first { $0 != .custom && $0.baseURL == serverBaseURL } ?? .custom }
        set { if newValue != .custom { serverBaseURL = newValue.baseURL } }
    }

    var transcriptionPrompt: String {
        didSet { defaults.set(transcriptionPrompt, forKey: Self.promptKey) }
    }

    var transformerTimeout: TimeInterval {
        didSet { defaults.set(transformerTimeout, forKey: Self.timeoutKey) }
    }

    /// The configuration the pipeline snapshots at the start of an import.
    /// Release builds ignore the stored kind and always transcribe with Vision — the model picker is a debug feature in 2.0.
    var configuration: OCREngineConfiguration {
        #if DEBUG
        let effectiveKind = OCREngineKind.availableOnThisPlatform.contains(kind) ? kind : .vision
        #else
        let effectiveKind = OCREngineKind.vision
        #endif
        return OCREngineConfiguration(
            kind: effectiveKind,
            smartSeparateEnabled: smartSeparateEnabled,
            coreAIModelURL: coreAIModelURL,
            serverBaseURL: serverBaseURL,
            serverModelID: serverModelID,
            serverAPIKey: serverAPIKey.isEmpty ? nil : serverAPIKey,
            transcriptionPrompt: transcriptionPrompt,
            transformerTimeout: transformerTimeout
        )
    }

    /// Only `shared` should back the app; tests pass their own suite.
    init(defaults: UserDefaults) {
        self.defaults = defaults
        let fallback = OCREngineConfiguration.default
        kind = defaults.string(forKey: Self.kindKey).flatMap(OCREngineKind.init(storedValue:)) ?? fallback.kind
        smartSeparateEnabled = defaults.object(forKey: Self.smartSeparateKey) == nil ? fallback.smartSeparateEnabled : defaults.bool(forKey: Self.smartSeparateKey)
        coreAIModelURL = defaults.string(forKey: Self.coreAIModelURLKey).map { URL(fileURLWithPath: $0) }
        serverBaseURL = defaults.string(forKey: Self.serverBaseURLKey).flatMap(URL.init(string:)) ?? fallback.serverBaseURL
        serverModelID = defaults.string(forKey: Self.serverModelIDKey) ?? fallback.serverModelID
        persistsAPIKey = defaults === UserDefaults.standard
        serverAPIKey = persistsAPIKey ? (ModelServerCredentialStore.load() ?? "") : ""
        transcriptionPrompt = defaults.string(forKey: Self.promptKey) ?? fallback.transcriptionPrompt
        let storedTimeout = defaults.double(forKey: Self.timeoutKey)
        transformerTimeout = storedTimeout > 0 ? storedTimeout : fallback.transformerTimeout
    }

    func resetPrompt() {
        transcriptionPrompt = OCREngineConfiguration.defaultPrompt
    }
}
