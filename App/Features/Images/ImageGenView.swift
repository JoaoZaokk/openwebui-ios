import SwiftUI
#if os(iOS)
import UIKit
#endif
import OpenWebUIKit

/// One past generation — enough to re-open the images (server URLs) later.
struct GenRecord: Codable, Identifiable {
    var id = UUID()
    var date = Date()
    var prompt: String
    var urls: [String]
}

@MainActor
final class ImageGenStore: ObservableObject {
    @Published var prompt = ""
    @Published var size = "1024x1024"
    @Published var steps = 20
    @Published var models: [OWNamedItem] = []
    @Published var selectedModel: String?
    @Published var generating = false
    @Published var images: [OWPlatformImage] = []
    /// Server URLs parallel to `images` — lets the viewer/history re-fetch.
    @Published var resultURLs: [String] = []
    @Published var error: String?

    /// Past generations, newest first (kept on-device, capped).
    @Published var history: [GenRecord] = GenRecord.load() {
        didSet { GenRecord.save(history) }
    }

    // AI prompt helper — an LLM rewrites the user's plain idea into a better
    // image prompt, so they don't "spend" a slow generation on a weak prompt.
    @Published var helperIdea = ""
    @Published var helperModel: String?
    @Published var helperResult = ""
    @Published var helping = false
    let llmModels: [OWModel]

    let sizes = ["512x512", "768x768", "1024x1024", "1024x1536", "1536x1024"]

    private let client: OpenWebUIClient
    private let completions: ChatCompletionsClient

    init(client: OpenWebUIClient, completions: ChatCompletionsClient, llmModels: [OWModel]) {
        self.client = client
        self.completions = completions
        self.llmModels = llmModels
        self.helperModel = llmModels.first?.id
    }

    func loadModels() async {
        models = (try? await client.imageModels()) ?? []
    }

    /// Ask the selected LLM (one-off, no saved chat) to turn the idea into a
    /// polished ComfyUI/SD prompt. Streams into `helperResult`.
    func improve() async {
        let idea = helperIdea.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !idea.isEmpty, let model = helperModel, !helping else { return }
        helping = true; helperResult = ""; error = nil
        defer { helping = false }
        let sys = """
        You are an expert text-to-image prompt engineer for ComfyUI / Stable Diffusion. \
        Turn the user's idea into ONE vivid, detailed English prompt: comma-separated \
        descriptors covering subject, style, lighting, composition and quality. \
        Output ONLY the prompt — no preamble, no quotes, no explanations.
        """
        let msgs = [OWChatMessageInput(role: "system", text: sys),
                    OWChatMessageInput(role: "user", text: idea)]
        do {
            for try await u in completions.stream(model: model, messages: msgs) {
                switch u {
                case .textDelta(let d): helperResult += d
                case .error(let m): self.error = m
                default: break
                }
            }
        } catch {
            self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    /// Push the AI's prompt into the actual image-prompt field.
    func usePrompt() {
        let t = helperResult.trimmingCharacters(in: .whitespacesAndNewlines)
        if !t.isEmpty { prompt = t }
    }

    func generate() async {
        let p = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !p.isEmpty, !generating else { return }
        generating = true; error = nil
        defer { generating = false }
        do {
            let urls = try await client.generateImages(
                OWImageRequest(prompt: p, size: size, model: selectedModel, steps: steps))
            var imgs: [OWPlatformImage] = []
            for u in urls {
                if let d = await client.imageData(path: u), let i = OWPlatformImage(data: d) { imgs.append(i) }
            }
            images = imgs
            resultURLs = urls
            if !urls.isEmpty {
                history.insert(GenRecord(prompt: p, urls: urls), at: 0)
                if history.count > 60 { history.removeLast(history.count - 60) }
            }
            if imgs.isEmpty { error = L("Imagem gerada, mas não foi possível carregá-la.") }
        } catch {
            self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }
}

extension GenRecord {
    private static let key = "imagegen.history"
    static func load() -> [GenRecord] {
        guard let d = UserDefaults.standard.data(forKey: key) else { return [] }
        return (try? JSONDecoder().decode([GenRecord].self, from: d)) ?? []
    }
    static func save(_ records: [GenRecord]) {
        if let d = try? JSONEncoder().encode(records) {
            UserDefaults.standard.set(d, forKey: key)
        }
    }
}

/// Image generation (ComfyUI). Size is per-request; steps is best-effort
/// (the canonical steps live in the admin image config).
struct ImageGenView: View {
    let app: AppState
    @Environment(\.theme) private var theme
    @StateObject private var store: ImageGenStore
    @FocusState private var promptFocused: Bool
    @FocusState private var ideaFocused: Bool
    @State private var showHistory = false
    @State private var viewer: ViewerItem?
    struct ViewerItem: Identifiable { let id = UUID(); let url: String }
    private var editing: Bool { promptFocused || ideaFocused }

    init(app: AppState) {
        self.app = app
        _store = StateObject(wrappedValue: ImageGenStore(client: app.client,
                                                         completions: app.completions,
                                                         llmModels: app.models))
    }

    var body: some View {
        NavigationStack {
            ZStack {
                theme.bg.ignoresSafeArea()
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        helperSection
                        promptField
                        controls
                        generateButton
                        if let err = store.error {
                            Text(err).font(.ody(size: 11, design: .monospaced)).foregroundStyle(theme.accent)
                        }
                        results
                    }
                    .padding(16)
                }
                .scrollDismissesKeyboard(.interactively)
            }
            .navigationTitle("Imagem")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                // Generation history (images created on this device).
                ToolbarItem(placement: .topBarLeading) {
                    Button { showHistory = true } label: {
                        Image(systemName: "clock.arrow.circlepath").foregroundStyle(theme.accent)
                    }
                }
                // Keyboard-accessory "Concluído" (the ergonomic spot, on device).
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Concluído") { hideKeyboard() }.foregroundStyle(theme.accent)
                }
                // Nav-bar fallback shown while editing — the fields are multi-line
                // (Return = newline) so this guarantees a tap-to-dismiss affordance.
                ToolbarItem(placement: .topBarTrailing) {
                    if editing {
                        Button("Concluído") { hideKeyboard() }
                            .font(.ody(.subheadline, design: .monospaced))
                            .foregroundStyle(theme.accent)
                    }
                }
            }
            .task { await store.loadModels() }
            .sheet(isPresented: $showHistory) {
                GenHistorySheet(store: store, client: app.client)
                    .environment(\.theme, theme)
            }
            .fullScreenCover(item: $viewer) { v in
                ImageViewerView(url: v.url, client: app.client)
            }
        }
        .tint(theme.accent)
    }

    private func hideKeyboard() {
        promptFocused = false
        ideaFocused = false
        #if os(iOS)
        UIApplication.shared.sendAction(
            #selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        #endif
    }

    // The AI prompt helper: describe an idea → an LLM returns a polished prompt →
    // the ↑ button drops it into the real image-prompt field below.
    private var helperSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Assistente de prompt (IA)", systemImage: "wand.and.stars")
                    .font(.ody(size: 11, design: .monospaced)).foregroundStyle(theme.secondaryText)
                Spacer()
                if !store.llmModels.isEmpty {
                    Menu {
                        ForEach(store.llmModels) { m in Button(m.shortName) { store.helperModel = m.id } }
                    } label: {
                        HStack(spacing: 3) {
                            Text(store.llmModels.first { $0.id == store.helperModel }?.shortName ?? "Modelo")
                                .font(.ody(size: 10, design: .monospaced)).lineLimit(1)
                            Image(systemName: "chevron.up.chevron.down").font(.system(size: 8))
                        }.foregroundStyle(theme.accent).frame(maxWidth: 130, alignment: .trailing)
                    }
                }
            }
            TextField("Descreva sua ideia em palavras simples…", text: $store.helperIdea, axis: .vertical)
                .font(.ody(.subheadline, design: .monospaced)).foregroundStyle(theme.fg)
                .focused($ideaFocused)
                .lineLimit(1...4)
                .padding(10)
                .background(theme.bg.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(theme.border, lineWidth: 1))

            Button {
                promptFocused = false
                Task { await store.improve() }
            } label: {
                HStack(spacing: 6) {
                    if store.helping { ProgressView().controlSize(.small).tint(theme.accent) }
                    Text(LocalizedStringKey(store.helping ? "Pensando…" : "Melhorar com IA"))
                        .font(.ody(.subheadline, design: .monospaced))
                    Image(systemName: "sparkles").font(.system(size: 12))
                }
                .frame(maxWidth: .infinity).padding(.vertical, 10)
                .foregroundStyle(theme.accent)
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(theme.accent, lineWidth: 1))
            }
            .disabled(store.helping || store.helperIdea.trimmingCharacters(in: .whitespaces).isEmpty)

            if !store.helperResult.isEmpty {
                HStack(alignment: .top, spacing: 8) {
                    Text(store.helperResult)
                        .font(.ody(size: 12, design: .monospaced)).foregroundStyle(theme.fg)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Button { store.usePrompt() } label: {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.system(size: 28)).foregroundStyle(theme.accent)
                    }
                }
                .padding(10)
                .background(theme.bg.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(theme.accent.opacity(0.4), lineWidth: 1))
            }
        }
        .padding(14)
        .background(theme.panel.opacity(0.4), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(theme.border, lineWidth: 1))
    }

    private var promptField: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("PROMPT").font(.ody(size: 10, design: .monospaced)).foregroundStyle(theme.secondaryText)
            TextField("Descreva a imagem…", text: $store.prompt, axis: .vertical)
                .font(.ody(.body, design: .monospaced)).foregroundStyle(theme.fg)
                .focused($promptFocused).lineLimit(2...6)
                .padding(12)
                .background(theme.panel, in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(theme.border, lineWidth: 1))
        }
    }

    private var controls: some View {
        VStack(spacing: 10) {
            HStack {
                Text("Tamanho").font(.ody(.subheadline, design: .monospaced)).foregroundStyle(theme.fg)
                Spacer()
                Menu {
                    ForEach(store.sizes, id: \.self) { s in
                        Button(s) { store.size = s }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Text(store.size).font(.ody(.subheadline, design: .monospaced))
                        Image(systemName: "chevron.up.chevron.down").font(.system(size: 10))
                    }.foregroundStyle(theme.accent)
                }
            }
            Divider().overlay(theme.border)
            HStack {
                Text("Passos").font(.ody(.subheadline, design: .monospaced)).foregroundStyle(theme.fg)
                Spacer()
                Stepper("\(store.steps)", value: $store.steps, in: 1...60)
                    .font(.ody(.subheadline, design: .monospaced)).foregroundStyle(theme.fg)
                    .fixedSize()
            }
            if !store.models.isEmpty {
                Divider().overlay(theme.border)
                HStack {
                    Text("Modelo").font(.ody(.subheadline, design: .monospaced)).foregroundStyle(theme.fg)
                    Spacer()
                    Menu {
                        Button("Padrão do servidor") { store.selectedModel = nil }
                        ForEach(store.models) { m in Button(m.name) { store.selectedModel = m.id } }
                    } label: {
                        HStack(spacing: 4) {
                            Text(store.selectedModel.flatMap { id in store.models.first { $0.id == id }?.name } ?? L("Padrão"))
                                .font(.ody(size: 12, design: .monospaced)).lineLimit(1)
                            Image(systemName: "chevron.up.chevron.down").font(.system(size: 10))
                        }.foregroundStyle(theme.accent).frame(maxWidth: 160, alignment: .trailing)
                    }
                }
            }
        }
        .padding(14)
        .background(theme.panel.opacity(0.4), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(theme.border, lineWidth: 1))
    }

    private var generateButton: some View {
        Button {
            promptFocused = false
            Task { await store.generate() }
        } label: {
            HStack {
                if store.generating { ProgressView().tint(.white) }
                Text(LocalizedStringKey(store.generating ? "Gerando…" : "Gerar imagem"))
                    .font(.ody(.headline, design: .monospaced))
                Image(systemName: "sparkles")
            }
            .frame(maxWidth: .infinity).padding(.vertical, 14)
            .background(theme.accent, in: RoundedRectangle(cornerRadius: 12)).foregroundStyle(.white)
        }
        .disabled(store.generating || store.prompt.trimmingCharacters(in: .whitespaces).isEmpty)
        .opacity(store.generating || store.prompt.trimmingCharacters(in: .whitespaces).isEmpty ? 0.6 : 1)
    }

    @ViewBuilder private var results: some View {
        ForEach(Array(store.images.enumerated()), id: \.offset) { i, img in
            VStack(spacing: 8) {
                // Tap to open the zoomable fullscreen viewer.
                Button {
                    if i < store.resultURLs.count { viewer = ViewerItem(url: store.resultURLs[i]) }
                } label: {
                    Image(platformImage: img).resizable().scaledToFit()
                        .frame(maxWidth: .infinity)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                        .overlay(RoundedRectangle(cornerRadius: 12).stroke(theme.border.opacity(0.4), lineWidth: 1))
                }
                .buttonStyle(.plain)
                Button {
                    owSaveImage(img)
                } label: {
                    Label("Salvar na galeria", systemImage: "square.and.arrow.down")
                        .font(.ody(.subheadline, design: .monospaced)).foregroundStyle(theme.accent)
                }
            }
            .padding(.top, 4)
        }
    }
}

/// Past generations (on-device): prompt, date, and tappable thumbnails.
struct GenHistorySheet: View {
    @ObservedObject var store: ImageGenStore
    let client: OpenWebUIClient
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss
    @State private var viewer: ImageGenView.ViewerItem?

    var body: some View {
        NavigationStack {
            ZStack {
                theme.bg.ignoresSafeArea()
                if store.history.isEmpty {
                    Text("Nenhuma imagem gerada ainda.")
                        .font(.ody(.subheadline, design: .monospaced))
                        .foregroundStyle(theme.secondaryText)
                } else {
                    List {
                        ForEach(store.history) { rec in
                            VStack(alignment: .leading, spacing: 8) {
                                Text(rec.prompt)
                                    .font(.ody(size: 12, design: .monospaced))
                                    .foregroundStyle(theme.fg).lineLimit(2)
                                Text(rec.date.formatted(date: .abbreviated, time: .shortened))
                                    .font(.ody(size: 10, design: .monospaced))
                                    .foregroundStyle(theme.secondaryText)
                                ScrollView(.horizontal, showsIndicators: false) {
                                    HStack(spacing: 8) {
                                        ForEach(rec.urls, id: \.self) { url in
                                            Button { viewer = ImageGenView.ViewerItem(url: url) } label: {
                                                AttachmentThumb(url: url, size: 84, client: client)
                                            }
                                            .buttonStyle(.plain)
                                        }
                                    }
                                }
                            }
                            .padding(.vertical, 4)
                            .listRowBackground(theme.panel)
                        }
                        .onDelete { store.history.remove(atOffsets: $0) }
                    }
                    .scrollContentBackground(.hidden)
                }
            }
            .navigationTitle("Histórico")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    if !store.history.isEmpty {
                        Button("Limpar histórico") { store.history.removeAll() }
                            .font(.ody(size: 12, design: .monospaced))
                    }
                }
                ToolbarItem(placement: .confirmationAction) { Button("OK") { dismiss() } }
            }
            .fullScreenCover(item: $viewer) { v in ImageViewerView(url: v.url, client: client) }
        }
        .tint(theme.accent)
    }
}
