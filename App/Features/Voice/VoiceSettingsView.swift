import SwiftUI
import OpenWebUIKit

struct VoiceSettingsView: View {
    @Environment(\.theme) private var theme
    @StateObject private var downloads = ModelDownloadManager.shared
    @ObservedObject private var speech = SpeechManager.shared
    // Observed so the neural row re-labels the moment the app language changes.
    @ObservedObject private var uiLanguage = LanguageManager.shared
    @ObservedObject private var neural = NeuralVoiceStore.shared
    /// Non-nil while the delete confirmation is up. Freeing ~550 MB is cheap to
    /// undo (re-download) but slow, so it asks first.
    @State private var pendingDelete: NeuralVoiceStore.Pack?
    @State private var customURL = ""
    @State private var addingModel = false

    @AppStorage(STTEngine.key) private var sttEngine = STTEngine.native.rawValue
    @AppStorage("voice.stt.model") private var sttModelID = ""
    @AppStorage("voice.stt.onDeviceOnly") private var sttOnDeviceOnly = false
    @AppStorage(SpeechLanguage.key) private var sttLanguage = SpeechLanguage.followApp
    @AppStorage("voice.tts.engine") private var ttsEngine = "native"
    @AppStorage("voice.tts.pocketVoice") private var pocketVoice = "alba"
    @AppStorage("voice.tts.serverVoice") private var serverVoice = ""
    @AppStorage("voice.tts.serverModel") private var serverModel = ""
    @AppStorage("voice.bargein.enabled") private var bargeEnabled = true
    @AppStorage("voice.bargein.sensitivity") private var bargeSensitivity = 0.5
    @State private var langFilter = "all"

    private var lang: VoiceLang? { VoiceLang(rawValue: langFilter) }

    // The engine is *persisted* as a raw string — that is what the picker binds
    // to — but every question this screen asks about it is asked of the enum.
    private var stt: STTEngine { STTEngine(rawValue: sttEngine) ?? .native }

    var body: some View {
        List {
            Section {
                Picker("Reconhecimento (STT)", selection: $sttEngine) {
                    ForEach(STTEngine.allCases) { engine in
                        Text(verbatim: engine.label).tag(engine.rawValue)
                    }
                }
                if stt == .model {
                    LabeledContent("Modelo ativo", value: modelName(sttModelID) ?? L("nenhum"))
                }
                // Only the native engine has the choice: the Whisper engines are
                // on-device by construction, and the server one never is.
                if stt == .native {
                    Toggle("Processar só no aparelho", isOn: $sttOnDeviceOnly)
                }
                speechLanguagePicker
            } header: { Text("Voz → Texto") } footer: {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Nativo = transcrição ao vivo enquanto você fala (tipo Claude/Gemini). \"Modelo\" = Whisper offline no aparelho. \"Servidor\" = o Whisper do seu Open WebUI (envia o áudio e transcreve no fim).")
                    if sttLanguage == SpeechLanguage.followApp {
                        Text("A voz nativa e o reconhecimento nativo seguem o idioma do app (Ajustes › Idioma).")
                    } else {
                        Text("A voz nativa segue o idioma do app. O reconhecimento usa o idioma escolhido acima; detectar automaticamente erra mais em áudio curto ou com ruído, e o reconhecimento nativo do iOS não detecta nada — nele vale sempre o idioma do app.")
                    }
                    if stt == .native {
                        Text("Processar só no aparelho não envia áudio à Apple, mas o modelo offline erra mais palavras. Deixe desligado se a transcrição estiver ruim.")
                    }
                }
            }

            Section {
                Picker("Voz da IA (TTS)", selection: $ttsEngine) {
                    Text("Nativo iOS").tag("native")
                    // Names the pack that will actually be used, so picking
                    // "Neural" in a language with no pack isn't a surprise.
                    Text(verbatim: speech.neuralAvailableForCurrentLanguage
                         ? L("Neural (%@)", uiLanguage.current.endonym)
                         : L("Neural (indisponível)")).tag("neural")
                    Text("Servidor").tag("server")
                }
                if ttsEngine == "server" {
                    if !speech.serverVoices.isEmpty {
                        Picker("Voz", selection: $serverVoice) {
                            Text("Padrão do servidor").tag("")
                            ForEach(speech.serverVoices) { v in Text(v.name).tag(v.id) }
                        }
                    } else {
                        TextField("Voz (ex: alloy, nova, onyx)", text: $serverVoice)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                    }
                    TextField("Modelo (ex: tts-1 — opcional)", text: $serverModel)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    Button {
                        speech.toggle(L("Olá! Esta é a voz do servidor."), id: "__test__")
                    } label: {
                        if speech.isPreparing("__test__") {
                            HStack { ProgressView(); Text("Sintetizando…") }
                        } else {
                            Label("Testar voz", systemImage: "speaker.wave.2")
                        }
                    }
                }
                if ttsEngine == "neural" {
                    // The 26 voice names are identical in every pack, so the
                    // picker never has to change with the language.
                    Picker("Voz", selection: $pocketVoice) {
                        ForEach(PocketVoices.all, id: \.self) { Text($0).tag($0) }
                    }
                    .disabled(!speech.neuralAvailableForCurrentLanguage)
                    Button { speech.prepareNeural() } label: {
                        if speech.isPreparing("__prepare__") {
                            HStack { ProgressView(); Text("Baixando voz neural…") }
                        } else if speech.neuralReady {
                            Label("Voz neural pronta", systemImage: "checkmark.circle.fill")
                                .foregroundStyle(theme.green)
                        } else {
                            Label("Baixar voz neural (~550 MB)", systemImage: "arrow.down.circle")
                        }
                    }
                    .disabled(speech.isPreparing("__prepare__") || speech.neuralReady
                              || !speech.neuralAvailableForCurrentLanguage)
                }
                // Two rows, because the manager has two things to say and they
                // are not the same thing. "No neural pack for this language —
                // using the native voice" is a notice on a path that goes on to
                // speak; it was sharing the failure row, so most UI languages
                // saw a red line saying the voice was broken when it was
                // working. A refused audio session is the failure.
                //
                // Both are shown for every engine, not just neural and server:
                // the session can be refused under the native voice too — the
                // default — and that message used to have nowhere to appear.
                // Switching engines clears whatever is left over (below).
                if let n = speech.neuralNotice {
                    Text(n).font(.footnote).foregroundStyle(theme.secondaryText)
                }
                if let e = speech.neuralError {
                    Text(e).font(.footnote).foregroundStyle(theme.danger)
                }
            } header: { Text("Texto → Voz") } footer: {
                Text("Neural = PocketTTS (CoreML/Neural Engine), bem mais natural que a voz nativa. Existe em português, inglês, espanhol, francês, alemão e italiano — segue o idioma do app e baixa ~550 MB por idioma na primeira vez. Roda só no iPhone físico (não no simulador).")
            }

            Section {
                Toggle("Interromper ao falar (barge-in)", isOn: $bargeEnabled)
                if bargeEnabled {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("Sensibilidade").font(.ody(.subheadline))
                            Spacer()
                            Text(LocalizedStringKey(bargeSensitivity > 0.66 ? "Alta" : bargeSensitivity < 0.34 ? "Baixa" : "Média"))
                                .font(.ody(size: 11)).foregroundStyle(theme.secondaryText)
                        }
                        Slider(value: $bargeSensitivity, in: 0...1)
                    }
                }
            } header: { Text("Conversa por voz") } footer: {
                Text("Enquanto a IA fala, começar a falar corta a resposta e ele te ouve. Sensibilidade alta interrompe com pouca voz (mas pode disparar sozinho com o eco); baixa exige falar mais firme.")
            }

            Section("Filtrar catálogo por idioma") {
                // Menu (not segmented): 22 options (21 language buckets + "Todos"), text labels only — no flags.
                Picker("Idioma", selection: $langFilter) {
                    Text("Todos").tag("all")
                    ForEach(VoiceLang.allCases, id: \.rawValue) { l in
                        Text(l.label).tag(l.rawValue)
                    }
                }
                .pickerStyle(.menu)
            }

            neuralPacksSection

            customModelSection

            // Two engines, two headers: a Parakeet row under "Whisper" told the
            // user it was something it is not. The brand name needs no catalogue.
            modelSection(title: L("Modelos STT · Whisper"), task: .stt, engine: .whisper,
                         selectedID: sttModelID) { id in sttModelID = id; sttEngine = STTEngine.model.rawValue }
            modelSection(title: "NVIDIA Parakeet", task: .stt, engine: .parakeet,
                         selectedID: sttModelID) { id in sttModelID = id; sttEngine = STTEngine.model.rawValue }

            if totalOnDisk > 0 {
                Section {
                    LabeledContent("Espaço usado",
                                   value: ByteCountFormatter.string(fromByteCount: totalOnDisk, countStyle: .file))
                }
            }
        }
        .navigationTitle("Voz e modelos")
        .navigationBarTitleDisplayMode(.inline)
        .scrollContentBackground(.hidden)
        .background(theme.bg)
        .tint(theme.accent)
        .onAppear { downloads.refresh(); neural.refresh() }
        // Re-scan after a download finishes, so the new pack (and the freed or
        // claimed space) shows up without leaving the screen.
        .onChange(of: speech.neuralReady) { _, ready in if ready { neural.refresh() } }
        // A message belongs to the engine that produced it: leaving it up after
        // a switch has the new engine explaining itself with the old one's words.
        .onChange(of: ttsEngine) { _, _ in speech.clearVoiceMessages() }
        .confirmationDialog(
            Text("Apagar voz neural"),
            isPresented: Binding(get: { pendingDelete != nil },
                                 set: { if !$0 { pendingDelete = nil } }),
            titleVisibility: .visible
        ) {
            Button(deleteButtonTitle, role: .destructive) {
                if let p = pendingDelete { neural.delete(p) }
                pendingDelete = nil
            }
            Button("Cancelar", role: .cancel) { pendingDelete = nil }
        } message: {
            Text("Apagar libera o espaço; a voz é baixada de novo na próxima vez que você usar aquele idioma.")
        }
        .task(id: ttsEngine) { if ttsEngine == "server" { await speech.loadServerVoices() } }
        .alert("Erro no download", isPresented: Binding(get: { downloads.error != nil }, set: { if !$0 { downloads.error = nil } })) {
            Button("OK") { downloads.error = nil }
        } message: { Text(downloads.error ?? "") }
    }

    /// The language the mic listens in — deliberately not the app's language,
    /// which is the only thing the three engines followed before.
    ///
    /// Offered under every engine, the native one included, where "detect"
    /// degrades to the app language: dropping the row when the engine changes
    /// would leave an already-chosen "detect" selecting nothing, and the
    /// section's footer says so instead.
    private var speechLanguagePicker: some View {
        Picker("Idioma da fala", selection: $sttLanguage) {
            Text(verbatim: L("Seguir o app (%@)", uiLanguage.current.endonym))
                .tag(SpeechLanguage.followApp)
            Text("Detectar automaticamente").tag(SpeechLanguage.auto)
            // Endonyms, so someone hunting for their own language can find it
            // without first reading the one that is selected.
            ForEach(AppLanguage.allCases) { l in
                Text(verbatim: l.endonym).tag(l.rawValue)
            }
        }
    }

    private func modelName(_ id: String) -> String? {
        VoiceCatalog.all.first { $0.id == id }?.name
    }

    /// Install a Whisper checkpoint the app doesn't ship, by URL.
    private var customModelSection: some View {
        Section {
            TextField("https://…/ggml-modelo.bin", text: $customURL)
                .font(.ody(size: 12))
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.URL)
                .submitLabel(.go)
                .onSubmit { addCustomModel() }
            Button { addCustomModel() } label: {
                if addingModel {
                    HStack { ProgressView(); Text("Verificando…") }
                } else {
                    Label("Baixar modelo", systemImage: "arrow.down.circle")
                }
            }
            .disabled(addingModel || customURL.trimmingCharacters(in: .whitespaces).isEmpty)
        } header: {
            Text("Modelo próprio")
        } footer: {
            Text("Aceita só link https de um modelo Whisper no formato ggml (.bin) — o mesmo do catálogo abaixo. Cole o link do arquivo; o link da página do Hugging Face é convertido sozinho.")
                .font(.ody(size: 11))
                .foregroundStyle(theme.secondaryText)
        }
    }

    private func addCustomModel() {
        let text = customURL
        guard !addingModel, !text.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        addingModel = true
        Task {
            do {
                try await downloads.addCustomModel(from: text)
                customURL = ""
            } catch {
                downloads.error = OWFailure.msg(error)
            }
            addingModel = false
        }
    }

    /// Names what's being freed, so the destructive button isn't a bare "Delete".
    private var deleteButtonTitle: String {
        guard let p = pendingDelete else { return L("Apagar") }
        return L("Apagar %@ (%@)", NeuralVoiceStore.label(p.language),
                 ByteCountFormatter.string(fromByteCount: p.bytes, countStyle: .file))
    }

    /// Whisper models + the PocketTTS packs — everything this screen downloaded.
    private var totalOnDisk: Int64 {
        downloads.totalInstalledBytes() + neural.totalBytes
    }

    /// Downloaded neural voice packs, with what each costs and a way out.
    /// Only rendered once something is actually on disk, so the common case
    /// (never touched the neural engine) shows nothing.
    @ViewBuilder
    private var neuralPacksSection: some View {
        if !neural.packs.isEmpty {
            Section {
                ForEach(neural.packs) { pack in
                    HStack(spacing: 10) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(verbatim: NeuralVoiceStore.label(pack.language))
                                .font(.ody(.subheadline)).foregroundStyle(theme.fg)
                            Text(verbatim: ByteCountFormatter.string(fromByteCount: pack.bytes, countStyle: .file))
                                .font(.ody(size: 10)).foregroundStyle(theme.secondaryText)
                        }
                        Spacer()
                        Button(role: .destructive) { pendingDelete = pack } label: {
                            Image(systemName: "trash").font(.ody(size: 16))
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel(Text("Apagar voz neural"))
                    }
                    .listRowBackground(theme.bg)
                }
            } header: {
                Text("Vozes neurais baixadas")
            } footer: {
                Text("Apagar libera o espaço; a voz é baixada de novo na próxima vez que você usar aquele idioma.")
                    .font(.ody(size: 11))
                    .foregroundStyle(theme.secondaryText)
            }
        }
    }

    /// ⚡ = Core ML / Neural Engine acceleration for a Whisper model.
    @ViewBuilder
    private func coreMLControl(_ model: VoiceModel) -> some View {
        if let p = downloads.coreMLProgress(model) {
            HStack(spacing: 4) {
                Text("\(Int(p * 100))%").font(.ody(size: 9)).foregroundStyle(theme.secondaryText)
                Button { downloads.cancelCoreML(model) } label: { Image(systemName: "xmark.circle") }
                    .buttonStyle(.borderless)
                    .accessibilityLabel(Text("Cancelar download"))
            }
        } else if downloads.hasCoreML(model) {
            Button { downloads.deleteCoreML(model) } label: {
                Image(systemName: "bolt.fill").font(.ody(size: 18)).foregroundStyle(theme.green)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(Text("Remover aceleração Core ML"))
        } else {
            // The encoder ADDS its weights to the model's RAM (whisper.cpp keeps
            // the ggml encoder too), so on a phone it is offered only when the
            // pair fits under the jetsam line right now.
            let zip = VoiceCatalog.coreMLZipBytes(forID: model.id)
            let fits = STTRunner.fits(model, coreMLBytes: zip) ?? true
            Button { downloads.downloadCoreML(model) } label: {
                Image(systemName: "bolt").font(.ody(size: 18)).foregroundStyle(fits ? theme.secondaryText : theme.secondaryText.opacity(0.35))
            }
            .buttonStyle(.borderless)
            .disabled(!fits)
            .accessibilityLabel(Text("Ativar aceleração Core ML"))
            .help(fits ? L("Baixa o encoder Core ML (%@). A primeira carga compila para o Neural Engine e pode levar minutos.", ByteCountFormatter.string(fromByteCount: zip, countStyle: .file))
                       : L("Este modelo não cabe na memória deste aparelho (precisa de %@, há %@ livres). Use um q5 ou o Parakeet.",
                           MemoryBudget.human(STTRunner.memoryRequired(for: model, coreMLBytes: zip)), MemoryBudget.human(MemoryBudget.availableBytes)))
        }
    }

    @ViewBuilder
    private func modelSection(title: String, task: VoiceTask, engine: STTModelEngine, selectedID: String, select: @escaping (String) -> Void) -> some View {
        let models = VoiceCatalog.filtered(task: task, lang: lang).filter { $0.engine == engine }
        ForEach(VoiceModel.Bucket.allCases, id: \.rawValue) { bucket in
            let items = models.filter { $0.bucket == bucket }
            if !items.isEmpty {
                Section {
                    ForEach(items) { model in
                        modelRow(model, selected: selectedID == model.id, select: select)
                    }
                } header: {
                    Text(verbatim: "\(title) · \(bucket.label)")
                }
            }
        }
    }

    private func modelRow(_ model: VoiceModel, selected: Bool, select: @escaping (String) -> Void) -> some View {
        let fits = STTRunner.fits(model, coreMLBytes: downloads.coreMLBytes(model)) ?? true
        return HStack(spacing: 10) {
            Text(model.lang.label)
                .font(.ody(size: 9))
                .foregroundStyle(theme.secondaryText)
                .padding(.horizontal, 6).padding(.vertical, 3)
                .background(theme.panel, in: Capsule())
            VStack(alignment: .leading, spacing: 2) {
                Text(model.name).font(.ody(.subheadline)).foregroundStyle(theme.fg)
                Text(model.humanSize).font(.ody(size: 10)).foregroundStyle(theme.secondaryText)
                if !fits {
                    // Selecting it would not fail, it would kill the app (jetsam,
                    // no error), so say so here instead.
                    Text("Não cabe na memória deste aparelho")
                        .font(.ody(size: 10)).foregroundStyle(theme.danger)
                }
            }
            Spacer()
            trailing(model, selected: selected, select: select)
        }
        .listRowBackground(theme.bg)
    }

    @ViewBuilder
    private func trailing(_ model: VoiceModel, selected: Bool, select: @escaping (String) -> Void) -> some View {
        if let p = downloads.progress[model.id] {
            HStack(spacing: 8) {
                Text("\(Int(p * 100))%").font(.ody(size: 10)).foregroundStyle(theme.secondaryText)
                Button { downloads.cancel(model) } label: { Image(systemName: "xmark.circle") }
                    .buttonStyle(.borderless)
                    .accessibilityLabel(Text("Cancelar download"))
            }
        } else if downloads.isInstalled(model) {
            HStack(spacing: 16) {
                // Core ML (Neural Engine) acceleration — Whisper STT only.
                if downloads.coreMLAvailable(model) { coreMLControl(model) }
                // Select (use this model)
                Button { select(model.id) } label: {
                    Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                        .font(.ody(size: 20))
                        .foregroundStyle(selected ? theme.green : theme.secondaryText)
                }
                .buttonStyle(.borderless)
                .disabled(!(STTRunner.fits(model, coreMLBytes: downloads.coreMLBytes(model)) ?? true) && !selected)
                .accessibilityLabel(Text("Selecionar modelo"))
                .accessibilityAddTraits(selected ? .isSelected : [])
                // Delete
                Button(role: .destructive) { downloads.delete(model) } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .accessibilityLabel(Text("Apagar modelo"))
            }
        } else {
            HStack(spacing: 16) {
                Button { downloads.download(model) } label: {
                    Image(systemName: "arrow.down.circle").font(.ody(size: 20)).foregroundStyle(theme.accent)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel(Text("Baixar modelo"))
                // A user-added model that failed or was cancelled still holds a
                // row; catalog entries can't be removed, so this is custom-only.
                if model.isCustom {
                    Button(role: .destructive) { downloads.delete(model) } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel(Text("Apagar modelo"))
                }
            }
        }
    }
}
