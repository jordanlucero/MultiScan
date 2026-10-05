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
//  | `lmStudio`  | macOS, talking to a local server     | OpenAI-compatible `POST /v1/chat/completions` on `http://localhost:1234` with the page image as a base64 `image_url` |
//
//  ## Configuration storage
//  `OCREngineSettings` is the usual `@Observable` + UserDefaults write-through object (see `Preferences.swift` for the pattern). It is read once per import by `ProjectImportPipeline`, so flipping the engine mid-import doesn't change engines halfway through a project.
//
//  2.1 ships the picker in **DEBUG builds only** (Settings ▸ OCR Engine). Release builds always use Vision until a downloadable model exists.
//

import Foundation
import Observation

/// The primary OCR engine.
nonisolated enum OCREngineKind: String, CaseIterable, Codable, Sendable {
    case vision
    case coreAI
    case lmStudio

    var label: LocalizedStringResource {
        switch self {
        case .vision: LocalizedStringResource("Apple Vision", comment: "OCR engine name")
        case .coreAI: LocalizedStringResource("On-device model (Core AI)", comment: "OCR engine name")
        case .lmStudio: LocalizedStringResource("Local server (LM Studio)", comment: "OCR engine name")
        }
    }

    /// Engines that can run on the current platform at all.
    static var availableOnThisPlatform: [OCREngineKind] {
        #if os(macOS)
        return allCases
        #else
        // A phone can't host an LM Studio server; the setting would be a trap.
        return [.vision, .coreAI]
        #endif
    }

    /// The string recorded in `Page.ocrEngine` so a page remembers what produced its text.
    func provenanceIdentifier(modelName: String?) -> String {
        switch self {
        case .vision: return "vision"
        case .coreAI: return "coreai:" + (modelName ?? "unknown")
        case .lmStudio: return "lmstudio:" + (modelName ?? "unknown")
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

    /// LM Studio: server root (default `http://localhost:1234`) and the loaded model's identifier (empty = let the server pick its default/loaded model).
    var lmStudioBaseURL: URL
    var lmStudioModelID: String

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
        lmStudioBaseURL: URL(string: "http://localhost:1234")!,
        lmStudioModelID: "",
        transcriptionPrompt: defaultPrompt,
        transformerTimeout: 120
    )

    /// Whether a transformer engine is selected *and* configured well enough to try.
    var usesTransformer: Bool {
        switch kind {
        case .vision: return false
        case .coreAI: return coreAIModelURL != nil
        case .lmStudio: return true
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
    private static let lmStudioBaseURLKey = "ocrLMStudioBaseURL"
    private static let lmStudioModelIDKey = "ocrLMStudioModelID"
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

    var lmStudioBaseURL: URL {
        didSet { defaults.set(lmStudioBaseURL.absoluteString, forKey: Self.lmStudioBaseURLKey) }
    }

    var lmStudioModelID: String {
        didSet { defaults.set(lmStudioModelID, forKey: Self.lmStudioModelIDKey) }
    }

    var transcriptionPrompt: String {
        didSet { defaults.set(transcriptionPrompt, forKey: Self.promptKey) }
    }

    var transformerTimeout: TimeInterval {
        didSet { defaults.set(transformerTimeout, forKey: Self.timeoutKey) }
    }

    /// The configuration the pipeline snapshots at the start of an import.
    /// Release builds ignore the stored kind and always transcribe with Vision — the model picker is a debug feature in 2.1.
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
            lmStudioBaseURL: lmStudioBaseURL,
            lmStudioModelID: lmStudioModelID,
            transcriptionPrompt: transcriptionPrompt,
            transformerTimeout: transformerTimeout
        )
    }

    /// Only `shared` should back the app; tests pass their own suite.
    init(defaults: UserDefaults) {
        self.defaults = defaults
        let fallback = OCREngineConfiguration.default
        kind = defaults.string(forKey: Self.kindKey).flatMap(OCREngineKind.init(rawValue:)) ?? fallback.kind
        smartSeparateEnabled = defaults.object(forKey: Self.smartSeparateKey) == nil ? fallback.smartSeparateEnabled : defaults.bool(forKey: Self.smartSeparateKey)
        coreAIModelURL = defaults.string(forKey: Self.coreAIModelURLKey).map { URL(fileURLWithPath: $0) }
        lmStudioBaseURL = defaults.string(forKey: Self.lmStudioBaseURLKey).flatMap(URL.init(string:)) ?? fallback.lmStudioBaseURL
        lmStudioModelID = defaults.string(forKey: Self.lmStudioModelIDKey) ?? fallback.lmStudioModelID
        transcriptionPrompt = defaults.string(forKey: Self.promptKey) ?? fallback.transcriptionPrompt
        let storedTimeout = defaults.double(forKey: Self.timeoutKey)
        transformerTimeout = storedTimeout > 0 ? storedTimeout : fallback.transformerTimeout
    }

    func resetPrompt() {
        transcriptionPrompt = OCREngineConfiguration.defaultPrompt
    }
}
