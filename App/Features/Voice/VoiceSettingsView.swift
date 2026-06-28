import SwiftUI
import OpenWebUIKit

struct VoiceSettingsView: View {
    @Environment(\.theme) private var theme
    @StateObject private var downloads = ModelDownloadManager.shared
    @ObservedObject private var speech = SpeechManager.shared

    @AppStorage("voice.stt.engine") private var sttEngine = "native"
    @AppStorage("voice.stt.model") private var sttModelID = ""
    @AppStorage("voice.tts.engine") private var ttsEngine = "native"
    @AppStorage("voice.tts.pocketVoice") private var pocketVoice = "alba"
    @AppStorage("voice.tts.serverVoice") private var serverVoice = ""
    @AppStorage("voice.tts.serverModel") private var serverModel = ""
    @AppStorage("voice.bargein.enabled") private var bargeEnabled = true
    @AppStorage("voice.bargein.sensitivity") private var bargeSensitivity = 0.5
    @State private var langFilter = "all"

    private var lang: VoiceLang? { VoiceLang(rawValue: langFilter) }

    var body: some View {
        List {
            Section {
                Picker("Reconhecimento (STT)", selection: $sttEngine) {
                    Text("Nativo iOS").tag("native")
                    Text("Modelo on-device").tag("model")
                    Text("Servidor").tag("server")
                }
                if sttEngine == "model" {
                    LabeledContent("Modelo ativo", value: modelName(sttModelID) ?? L("nenhum"))
                }
            } header: { Text("Voz → Texto") } footer: {
                Text("Nativo = transcrição ao vivo enquanto você fala (tipo Claude/Gemini). \"Modelo\" = Whisper offline no aparelho. \"Servidor\" = o Whisper do seu Open WebUI (envia o áudio e transcreve no fim).")
            }

            Section {
                Picker("Voz da IA (TTS)", selection: $ttsEngine) {
                    Text("Nativo iOS").tag("native")
                    Text("Neural pt-BR").tag("neural")
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
                    if let e = speech.neuralError {
                        Text(e).font(.footnote).foregroundStyle(theme.accent)
                    }
                }
                if ttsEngine == "neural" {
                    Picker("Voz", selection: $pocketVoice) {
                        ForEach(PocketVoices.portuguese, id: \.self) { Text($0).tag($0) }
                    }
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
                    .disabled(speech.isPreparing("__prepare__") || speech.neuralReady)
                    if let e = speech.neuralError {
                        Text(e).font(.footnote).foregroundStyle(theme.accent)
                    }
                }
            } header: { Text("Texto → Voz") } footer: {
                Text("Neural = PocketTTS em português (CoreML/Neural Engine), bem mais natural que a voz nativa. Baixa ~550 MB on-device na primeira vez; roda só no iPhone físico (não no simulador).")
            }

            Section {
                Toggle("Interromper ao falar (barge-in)", isOn: $bargeEnabled)
                if bargeEnabled {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("Sensibilidade").font(.ody(.subheadline, design: .monospaced))
                            Spacer()
                            Text(LocalizedStringKey(bargeSensitivity > 0.66 ? "Alta" : bargeSensitivity < 0.34 ? "Baixa" : "Média"))
                                .font(.ody(size: 11, design: .monospaced)).foregroundStyle(theme.secondaryText)
                        }
                        Slider(value: $bargeSensitivity, in: 0...1)
                    }
                }
            } header: { Text("Conversa por voz") } footer: {
                Text("Enquanto a IA fala, começar a falar corta a resposta e ele te ouve. Sensibilidade alta interrompe com pouca voz (mas pode disparar sozinho com o eco); baixa exige falar mais firme.")
            }

            Section("Filtrar catálogo por idioma") {
                Picker("Idioma", selection: $langFilter) {
                    Text("Todos").tag("all")
                    ForEach(VoiceLang.allCases, id: \.rawValue) { l in
                        Text("\(l.flag) \(l.label)").tag(l.rawValue)
                    }
                }
                .pickerStyle(.segmented)
            }

            modelSection(title: L("Modelos STT · Whisper"), task: .stt,
                         selectedID: sttModelID) { id in sttModelID = id; sttEngine = "model" }

            if downloads.totalInstalledBytes() > 0 {
                Section {
                    LabeledContent("Espaço usado",
                                   value: ByteCountFormatter.string(fromByteCount: downloads.totalInstalledBytes(), countStyle: .file))
                }
            }
        }
        .navigationTitle("Voz e modelos")
        .navigationBarTitleDisplayMode(.inline)
        .scrollContentBackground(.hidden)
        .background(theme.bg)
        .tint(theme.accent)
        .onAppear { downloads.refresh() }
        .task(id: ttsEngine) { if ttsEngine == "server" { await speech.loadServerVoices() } }
        .alert("Erro no download", isPresented: Binding(get: { downloads.error != nil }, set: { if !$0 { downloads.error = nil } })) {
            Button("OK") { downloads.error = nil }
        } message: { Text(downloads.error ?? "") }
    }

    private func modelName(_ id: String) -> String? {
        VoiceCatalog.all.first { $0.id == id }?.name
    }

    /// ⚡ = Core ML / Neural Engine acceleration for a Whisper model.
    @ViewBuilder
    private func coreMLControl(_ model: VoiceModel) -> some View {
        if let p = downloads.coreMLProgress(model) {
            HStack(spacing: 4) {
                Text("\(Int(p * 100))%").font(.ody(size: 9, design: .monospaced)).foregroundStyle(theme.secondaryText)
                Button { downloads.cancelCoreML(model) } label: { Image(systemName: "xmark.circle") }
                    .buttonStyle(.borderless)
            }
        } else if downloads.hasCoreML(model) {
            Button { downloads.deleteCoreML(model) } label: {
                Image(systemName: "bolt.fill").font(.ody(size: 18)).foregroundStyle(theme.green)
            }
            .buttonStyle(.borderless)
        } else {
            Button { downloads.downloadCoreML(model) } label: {
                Image(systemName: "bolt").font(.ody(size: 18)).foregroundStyle(theme.secondaryText)
            }
            .buttonStyle(.borderless)
        }
    }

    @ViewBuilder
    private func modelSection(title: String, task: VoiceTask, selectedID: String, select: @escaping (String) -> Void) -> some View {
        let models = VoiceCatalog.filtered(task: task, lang: lang)
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
        HStack(spacing: 10) {
            Text(model.lang.flag)
            VStack(alignment: .leading, spacing: 2) {
                Text(model.name).font(.ody(.subheadline, design: .monospaced)).foregroundStyle(theme.fg)
                Text(model.humanSize).font(.ody(size: 10, design: .monospaced)).foregroundStyle(theme.secondaryText)
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
                Text("\(Int(p * 100))%").font(.ody(size: 10, design: .monospaced)).foregroundStyle(theme.secondaryText)
                Button { downloads.cancel(model) } label: { Image(systemName: "xmark.circle") }
                    .buttonStyle(.borderless)
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
                // Delete
                Button(role: .destructive) { downloads.delete(model) } label: {
                    Image(systemName: "trash").foregroundStyle(theme.accent)
                }
                .buttonStyle(.borderless)
            }
        } else {
            Button { downloads.download(model) } label: {
                Image(systemName: "arrow.down.circle").font(.ody(size: 20)).foregroundStyle(theme.accent)
            }
            .buttonStyle(.borderless)
        }
    }
}
