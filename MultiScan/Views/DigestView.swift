//
//  DigestView.swift
//  MultiScan
//
//  MultiScan Digest: the project as one continuous, beautifully typeset text — for *reading* what was scanned rather than reviewing it page by page.
//
//  ## Compilation
//  Pages flow into each other. `DigestComposer` joins consecutive pages with a single space when neither side already supplies whitespace (a page ending mid-sentence continues on the next line of the next page); the space exists only in the composed string — nothing is written back to the pages. Chapter titles (`Page.sectionTitle`) become headings; optional faint page markers show where each scan began. Everything comes from the export cache (one read) with the pages' raw text as the fallback, exactly like export.
//
//  ## Typography
//  `DigestSettings` (UserDefaults-backed, shared across projects) holds the theme (paper/sepia/night/…), font family, size, kerning, and line spacing. The composer re-normalizes every run onto the chosen font — bold/italic traits and heading scale survive via `RichTextArchiver.normalizing(_:to:baseSizeOfExisting:)` — then stamps kerning, paragraph spacing, and the theme's text color. Illustrations render through the same attachment view providers as the editor.
//
//  ## Presentation
//  `ReviewView` presents it as a sheet (macOS/iPad) or full-screen cover (iPhone). The text sits in a reading column capped at `DigestView.maximumColumnWidth`.
//

import SwiftUI
import SwiftData
import Observation
#if os(macOS)
import AppKit
#else
import UIKit
#endif

// MARK: - Settings

/// Reading themes. Colors are deliberately fixed (not dynamic system colors) so "Paper" is paper in Dark Mode too.
nonisolated enum DigestTheme: String, CaseIterable, Codable, Sendable {
    case system, paper, sepia, night, highContrast

    var label: LocalizedStringResource {
        switch self {
        case .system: LocalizedStringResource("System", comment: "Digest theme")
        case .paper: LocalizedStringResource("Paper", comment: "Digest theme")
        case .sepia: LocalizedStringResource("Sepia", comment: "Digest theme")
        case .night: LocalizedStringResource("Night", comment: "Digest theme")
        case .highContrast: LocalizedStringResource("High Contrast", comment: "Digest theme")
        }
    }

    /// `nil` = follow the system appearance (dynamic label/background colors).
    var textColor: PlatformColor? {
        switch self {
        case .system: nil
        case .paper: PlatformColor(red: 0.13, green: 0.12, blue: 0.11, alpha: 1)
        case .sepia: PlatformColor(red: 0.36, green: 0.27, blue: 0.17, alpha: 1)
        case .night: PlatformColor(red: 0.85, green: 0.85, blue: 0.83, alpha: 1)
        case .highContrast: .black
        }
    }

    var backgroundColor: Color? {
        switch self {
        case .system: nil
        case .paper: Color(red: 0.98, green: 0.97, blue: 0.94)
        case .sepia: Color(red: 0.96, green: 0.91, blue: 0.80)
        case .night: Color(red: 0.09, green: 0.09, blue: 0.10)
        case .highContrast: .white
        }
    }

    var prefersDarkChrome: Bool { self == .night }
}

/// Font families offered in the Digest. Names resolve through `PlatformFont(name:size:)`; `.system`/`.serif` use the system designs so Dynamic Type and the New York face come for free.
nonisolated enum DigestFontChoice: String, CaseIterable, Codable, Sendable {
    case system, serif, georgia, palatino, charter, times, helvetica, avenir, menlo

    var label: String {
        switch self {
        case .system: String(localized: "System (San Francisco)")
        case .serif: String(localized: "System Serif (New York)")
        case .georgia: "Georgia"
        case .palatino: "Palatino"
        case .charter: "Charter"
        case .times: "Times New Roman"
        case .helvetica: "Helvetica Neue"
        case .avenir: "Avenir Next"
        case .menlo: "Menlo"
        }
    }

    func font(size: CGFloat) -> PlatformFont {
        switch self {
        case .system:
            return .systemFont(ofSize: size)
        case .serif:
            #if os(macOS)
            let descriptor = NSFont.systemFont(ofSize: size).fontDescriptor.withDesign(.serif) ?? NSFont.systemFont(ofSize: size).fontDescriptor
            return NSFont(descriptor: descriptor, size: size) ?? .systemFont(ofSize: size)
            #else
            let descriptor = UIFont.systemFont(ofSize: size).fontDescriptor.withDesign(.serif) ?? UIFont.systemFont(ofSize: size).fontDescriptor
            return UIFont(descriptor: descriptor, size: size)
            #endif
        case .georgia: return PlatformFont(name: "Georgia", size: size) ?? .systemFont(ofSize: size)
        case .palatino: return PlatformFont(name: "Palatino", size: size) ?? .systemFont(ofSize: size)
        case .charter: return PlatformFont(name: "Charter", size: size) ?? .systemFont(ofSize: size)
        case .times: return PlatformFont(name: "Times New Roman", size: size) ?? .systemFont(ofSize: size)
        case .helvetica: return PlatformFont(name: "Helvetica Neue", size: size) ?? .systemFont(ofSize: size)
        case .avenir: return PlatformFont(name: "Avenir Next", size: size) ?? .systemFont(ofSize: size)
        case .menlo: return PlatformFont(name: "Menlo", size: size) ?? .systemFont(ofSize: size)
        }
    }
}

/// The reader's typography, as a value the composer can take off the main actor.
nonisolated struct DigestTypography: Equatable, Sendable {
    var theme: DigestTheme
    var font: DigestFontChoice
    var fontSize: Double
    /// Points of extra tracking per glyph (0 = font default).
    var kerning: Double
    /// Line height multiple (1.0 = font default, 1.6 = airy).
    var lineSpacing: Double
    var showsChapterHeadings: Bool
    var showsPageMarkers: Bool

    static let `default` = DigestTypography(theme: .paper, font: .serif, fontSize: 18, kerning: 0, lineSpacing: 1.35, showsChapterHeadings: true, showsPageMarkers: false)
}

/// UserDefaults-backed Digest preferences (one instance per Digest view; the values are global, not per project).
@Observable
final class DigestSettings {
    private static let key = "digestTypography"
    private let defaults: UserDefaults

    var theme: DigestTheme { didSet { persist() } }
    var font: DigestFontChoice { didSet { persist() } }
    var fontSize: Double { didSet { persist() } }
    var kerning: Double { didSet { persist() } }
    var lineSpacing: Double { didSet { persist() } }
    var showsChapterHeadings: Bool { didSet { persist() } }
    var showsPageMarkers: Bool { didSet { persist() } }

    var typography: DigestTypography {
        DigestTypography(theme: theme, font: font, fontSize: fontSize, kerning: kerning, lineSpacing: lineSpacing, showsChapterHeadings: showsChapterHeadings, showsPageMarkers: showsPageMarkers)
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let stored = defaults.data(forKey: Self.key).flatMap { try? JSONDecoder().decode(StoredTypography.self, from: $0) }
        let base = stored?.typography ?? .default
        theme = base.theme
        font = base.font
        fontSize = base.fontSize
        kerning = base.kerning
        lineSpacing = base.lineSpacing
        showsChapterHeadings = base.showsChapterHeadings
        showsPageMarkers = base.showsPageMarkers
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(StoredTypography(typography)) {
            defaults.set(data, forKey: Self.key)
        }
    }

    /// Codable mirror (the typography value itself stays a plain Sendable struct).
    private struct StoredTypography: Codable {
        var theme: DigestTheme
        var font: DigestFontChoice
        var fontSize: Double
        var kerning: Double
        var lineSpacing: Double
        var showsChapterHeadings: Bool
        var showsPageMarkers: Bool

        init(_ typography: DigestTypography) {
            theme = typography.theme; font = typography.font; fontSize = typography.fontSize
            kerning = typography.kerning; lineSpacing = typography.lineSpacing
            showsChapterHeadings = typography.showsChapterHeadings; showsPageMarkers = typography.showsPageMarkers
        }

        var typography: DigestTypography {
            DigestTypography(theme: theme, font: font, fontSize: fontSize, kerning: kerning, lineSpacing: lineSpacing, showsChapterHeadings: showsChapterHeadings, showsPageMarkers: showsPageMarkers)
        }
    }
}

// MARK: - Composer

/// The composed Digest text. `NSAttributedString` isn't Sendable; the instance is built inside the compose task and never mutated afterwards (same reasoning as `TextExportResult`).
nonisolated struct DigestText: @unchecked Sendable {
    let attributedText: NSAttributedString
    static let empty = DigestText(attributedText: NSAttributedString())
}

nonisolated enum DigestComposer {

    /// Builds the continuous text from export snapshots. Off the main actor; the result is immutable and handed back.
    @concurrent
    static func compose(from snapshots: [TextExporter.PageSnapshot], typography: DigestTypography) async -> DigestText {
        let bodyFont = typography.font.font(size: typography.fontSize)
        let output = NSMutableAttributedString()
        var dummy = false

        for snapshot in snapshots {
            let decoded = RichTextArchiver.attributedString(from: snapshot.textData)
            // Illustrations stay as reference attachments (the Digest renders them with the editor's view providers); tables flatten to text.
            let resolved = TextExporter.resolveAttachments(in: decoded, captures: [], options: digestOptions, baseFont: PageTextStyle.storageFont, hasImages: &dummy)
            let page = trimmedEdges(resolved)

            if typography.showsChapterHeadings, let title = snapshot.sectionTitle, !title.isEmpty {
                if output.length > 0 { output.append(NSAttributedString(string: "\n\n", attributes: [.font: bodyFont])) }
                output.append(NSAttributedString(string: title + "\n", attributes: [.font: PageTextStyle.headingFont(level: 1, base: bodyFont)]))
            } else if output.length > 0, page.length > 0 {
                // Continuous flow: one space between pages, only when neither side already provides whitespace.
                let previousEndsWithWhitespace = output.string.last.map { $0.isWhitespace || $0.isNewline } ?? true
                let nextStartsWithWhitespace = page.string.first.map { $0.isWhitespace || $0.isNewline } ?? true
                if !previousEndsWithWhitespace && !nextStartsWithWhitespace {
                    output.append(NSAttributedString(string: " ", attributes: [.font: bodyFont]))
                }
            }

            if typography.showsPageMarkers {
                let label = snapshot.printedLabel.map { "⟨p. \($0)⟩ " } ?? "⟨\(snapshot.pageNumber)⟩ "
                // Smaller than the body; the theme color is applied uniformly afterwards.
                output.append(NSAttributedString(string: label, attributes: [
                    .font: bodyFont.withSize(max(bodyFont.pointSize * 0.6, 8))
                ]))
            }

            output.append(page)
        }

        return DigestText(attributedText: styled(output, typography: typography, bodyFont: bodyFont))
    }

    private static let digestOptions = ExportOptions(createVisualSeparation: false, separatorStyle: .lineBreak, includePageNumber: false, includeFilename: false, includeStatistics: false, includeChapterHeadings: false, includeCaptures: false, includeDraftReminders: false)

    /// Re-fonts every run onto the Digest font (keeping traits and heading scale), then applies kerning, line spacing, and the theme color.
    static func styled(_ text: NSAttributedString, typography: DigestTypography, bodyFont: PlatformFont) -> NSAttributedString {
        let normalized = NSMutableAttributedString(attributedString: RichTextArchiver.normalizing(text, to: bodyFont, baseSizeOfExisting: PageTextStyle.storageFontSize))
        let fullRange = NSRange(location: 0, length: normalized.length)

        let paragraph = NSMutableParagraphStyle()
        paragraph.lineHeightMultiple = typography.lineSpacing
        paragraph.paragraphSpacing = bodyFont.pointSize * 0.6
        normalized.addAttribute(.paragraphStyle, value: paragraph, range: fullRange)

        if typography.kerning != 0 {
            normalized.addAttribute(.kern, value: typography.kerning, range: fullRange)
        }

        // Theme color — or the dynamic label color for the system theme, which the text view needs explicitly (see RichTextArchiver.applyingDisplayColor).
        #if os(macOS)
        let color = typography.theme.textColor ?? NSColor.labelColor
        #else
        let color = typography.theme.textColor ?? UIColor.label
        #endif
        normalized.addAttribute(.foregroundColor, value: color, range: fullRange)
        return normalized
    }

    /// Drops leading/trailing blank lines of a page so joins stay tight; interior line structure is untouched.
    static func trimmedEdges(_ text: NSAttributedString) -> NSAttributedString {
        let string = text.string as NSString
        var start = 0
        var end = string.length
        let whitespace = CharacterSet.whitespacesAndNewlines
        while start < end, let scalar = Unicode.Scalar(string.character(at: start)), whitespace.contains(scalar) { start += 1 }
        while end > start, let scalar = Unicode.Scalar(string.character(at: end - 1)), whitespace.contains(scalar) { end -= 1 }
        guard start > 0 || end < string.length else { return text }
        return text.attributedSubstring(from: NSRange(location: start, length: end - start))
    }
}

// MARK: - View

struct DigestView: View {
    let document: Document
    @Environment(\.dismiss) private var dismiss

    @State private var settings = DigestSettings()
    @State private var text = NSAttributedString()
    @State private var isComposing = false
    @State private var composeTask: Task<Void, Never>?
    @State private var showTypography = false

    static let maximumColumnWidth: CGFloat = 720

    /// The "System" theme's background: the platform's text background, so it follows Dark Mode.
    private static var systemReadingBackground: Color {
        #if os(macOS)
        Color(nsColor: .textBackgroundColor)
        #else
        Color(uiColor: .systemBackground)
        #endif
    }

    var body: some View {
        NavigationStack {
            reader
                .navigationTitle(document.name)
                #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
                #endif
                .toolbar { toolbarContent }
        }
        .onAppear { recompose() }
        .modifier(TypographyObserver(settings: settings) { recompose() })
        .onDisappear { composeTask?.cancel() }
        .preferredColorScheme(settings.theme.prefersDarkChrome ? .dark : nil)
        #if os(macOS)
        .frame(minWidth: 600, idealWidth: 900, minHeight: 500, idealHeight: 760)
        #endif
    }

    private var reader: some View {
        ZStack {
            (settings.theme.backgroundColor ?? Self.systemReadingBackground)
                .ignoresSafeArea()

            ThemedRichTextView(text: text, horizontalInset: 28)
                .frame(maxWidth: Self.maximumColumnWidth)
                .accessibilityLabel("Digest text")

            if isComposing && text.length == 0 {
                ProgressView("Composing…")
            }
        }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .cancellationAction) {
            Button { dismiss() } label: {
                Label("Done", systemImage: "xmark")
            }
            .keyboardShortcut(.cancelAction)
        }

        ToolbarItemGroup(placement: .primaryAction) {
            Menu {
                Picker("Theme", selection: Bindable(settings).theme) {
                    ForEach(DigestTheme.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                .pickerStyle(.inline)
            } label: {
                Label("Theme", systemImage: "paintpalette")
            }

            Menu {
                Picker("Font", selection: Bindable(settings).font) {
                    ForEach(DigestFontChoice.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                .pickerStyle(.inline)
            } label: {
                Label("Font", systemImage: "textformat")
            }

            Button { showTypography.toggle() } label: {
                Label("Typography", systemImage: "textformat.size")
            }
            .popover(isPresented: $showTypography) {
                DigestTypographyControls(settings: settings)
                    .padding()
                    .frame(minWidth: 280)
                    .presentationCompactAdaptation(.popover)
            }

            ShareLink(item: RichText(text, suggestedName: document.name), preview: SharePreview(document.name)) {
                Label("Share", systemImage: "square.and.arrow.up")
            }
            .disabled(text.length == 0)
        }
    }

    private func recompose() {
        composeTask?.cancel()
        let snapshots = TextExporter.snapshots(for: document)
        let typography = settings.typography
        composeTask = Task {
            isComposing = true
            defer { isComposing = false }
            let composed = await DigestComposer.compose(from: snapshots, typography: typography)
            guard !Task.isCancelled else { return }
            text = composed.attributedText
        }
    }
}

/// Size, kerning, line spacing, markers — the popover body.
struct DigestTypographyControls: View {
    @Bindable var settings: DigestSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            LabeledContent("Size") {
                HStack {
                    Button { settings.fontSize = max(12, settings.fontSize - 1) } label: { Image(systemName: "textformat.size.smaller") }
                        .accessibilityLabel("Smaller text")
                    Slider(value: $settings.fontSize, in: 12...32, step: 1)
                    Button { settings.fontSize = min(32, settings.fontSize + 1) } label: { Image(systemName: "textformat.size.larger") }
                        .accessibilityLabel("Larger text")
                }
            }
            LabeledContent("Kerning") {
                Slider(value: $settings.kerning, in: -0.5...2.0, step: 0.1)
            }
            LabeledContent("Line spacing") {
                Slider(value: $settings.lineSpacing, in: 1.0...2.0, step: 0.05)
            }
            Toggle("Chapter headings", isOn: $settings.showsChapterHeadings)
            Toggle("Page markers", isOn: $settings.showsPageMarkers)
            Button("Reset") {
                let base = DigestTypography.default
                settings.fontSize = base.fontSize
                settings.kerning = base.kerning
                settings.lineSpacing = base.lineSpacing
            }
            .controlSize(.small)
        }
    }
}

/// Owns the typography read so the reader's representable doesn't depend on every slider tick.
private struct TypographyObserver: ViewModifier {
    let settings: DigestSettings
    let onChange: () -> Void

    func body(content: Content) -> some View {
        content.onChange(of: settings.typography) { onChange() }
    }
}

// MARK: - Themed read-only text view

/// Like `RichTextPreview`, but it does **not** stamp the label color (the composer already colored the text for the theme) and it leaves room at the sides for a reading margin.
struct ThemedRichTextView {
    let text: NSAttributedString
    var horizontalInset: CGFloat = 16

    final class Coordinator {
        var lastText: NSAttributedString?
    }
}

#if os(macOS)
extension ThemedRichTextView: NSViewRepresentable {
    func makeNSView(context: Context) -> NSScrollView {
        let (scrollView, textView) = PageTextView.makeScrollable(editable: false)
        textView.textContainerInset = NSSize(width: horizontalInset, height: 32)
        textView.contentStorage.setAttributedString(text)
        context.coordinator.lastText = text
        return scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        guard let textView = nsView.documentView as? PageTextView else { return }
        if context.coordinator.lastText !== text {
            context.coordinator.lastText = text
            textView.contentStorage.setAttributedString(text)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }
}
#else
extension ThemedRichTextView: UIViewRepresentable {
    func makeUIView(context: Context) -> PageTextView {
        let textView = PageTextView.make(editable: false)
        textView.textContainerInset = UIEdgeInsets(top: 24, left: horizontalInset, bottom: 24, right: horizontalInset)
        textView.contentStorage.setAttributedString(text)
        context.coordinator.lastText = text
        return textView
    }

    func updateUIView(_ uiView: PageTextView, context: Context) {
        if context.coordinator.lastText !== text {
            context.coordinator.lastText = text
            uiView.contentStorage.setAttributedString(text)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }
}
#endif
