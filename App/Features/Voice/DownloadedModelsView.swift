import SwiftUI
import OpenWebUIKit

/// Everything the app has downloaded for voice, in one place, each with what it
/// costs and a way out.
///
/// Report from 1.14: "I have 2.66 GB used but I cannot see what I downloaded to
/// remove what I do not use" — the Whisper catalogue only lists models under a
/// language filter and size group, so a model fetched earlier (Large v3 Turbo)
/// could not be found again to delete it. "Espaço usado" now opens this list.
struct DownloadedModelsView: View {
    @Environment(\.theme) private var theme
    @ObservedObject private var downloads = ModelDownloadManager.shared
    @ObservedObject private var neural = NeuralVoiceStore.shared
    @AppStorage("voice.stt.model") private var sttModelID = ""
    @State private var pendingModel: VoiceModel?
    @State private var pendingPack: NeuralVoiceStore.Pack?

    private var models: [VoiceModel] {
        VoiceCatalog.all.filter { downloads.isInstalled($0) }
    }

    private func size(_ m: VoiceModel) -> String {
        let bytes = m.bytes + downloads.coreMLBytes(m)
        return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    var body: some View {
        List {
            if models.isEmpty && neural.packs.isEmpty {
                Section { Text("Nada baixado.").foregroundStyle(theme.secondaryText) }
            }
            if !models.isEmpty {
                Section {
                    ForEach(models) { model in
                        HStack(spacing: 10) {
                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: 6) {
                                    Text(model.name).font(.ody(.subheadline)).foregroundStyle(theme.fg)
                                    if model.id == sttModelID {
                                        Image(systemName: "checkmark.circle.fill")
                                            .font(.ody(size: 12)).foregroundStyle(theme.green)
                                            .accessibilityLabel(Text("Modelo ativo"))
                                    }
                                }
                                Text(verbatim: size(model))
                                    .font(.ody(size: 10)).foregroundStyle(theme.secondaryText)
                            }
                            Spacer()
                            if downloads.hasCoreML(model) {
                                Button { downloads.deleteCoreML(model) } label: {
                                    Image(systemName: "bolt.fill").font(.ody(size: 16)).foregroundStyle(theme.green)
                                }
                                .buttonStyle(.borderless)
                                .accessibilityLabel(Text("Remover aceleração Core ML"))
                            }
                            Button(role: .destructive) { pendingModel = model } label: {
                                Image(systemName: "trash").font(.ody(size: 16))
                            }
                            .buttonStyle(.borderless)
                            .accessibilityLabel(Text("Apagar modelo"))
                        }
                        .listRowBackground(theme.bg)
                    }
                } header: { Text("Modelos de reconhecimento") }
            }
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
                            Button(role: .destructive) { pendingPack = pack } label: {
                                Image(systemName: "trash").font(.ody(size: 16))
                            }
                            .buttonStyle(.borderless)
                            .accessibilityLabel(Text("Apagar voz neural"))
                        }
                        .listRowBackground(theme.bg)
                    }
                } header: { Text("Vozes neurais baixadas") }
            }
            Section {
                LabeledContent("Espaço usado",
                               value: ByteCountFormatter.string(
                                   fromByteCount: downloads.totalInstalledBytes() + neural.totalBytes,
                                   countStyle: .file))
            }
        }
        .navigationTitle("Baixados no aparelho")
        .navigationBarTitleDisplayMode(.inline)
        .scrollContentBackground(.hidden)
        .background(theme.bg)
        .tint(theme.accent)
        .onAppear { downloads.refresh(); neural.refresh() }
        .confirmationDialog(
            Text(verbatim: pendingModel?.name ?? ""),
            isPresented: Binding(get: { pendingModel != nil }, set: { if !$0 { pendingModel = nil } }),
            titleVisibility: .visible
        ) {
            Button(L("Apagar %@ (%@)", pendingModel?.name ?? "", pendingModel.map(size) ?? ""),
                   role: .destructive) {
                if let m = pendingModel { downloads.delete(m) }
                pendingModel = nil
            }
            Button("Cancelar", role: .cancel) { pendingModel = nil }
        }
        .confirmationDialog(
            Text("Apagar voz neural"),
            isPresented: Binding(get: { pendingPack != nil }, set: { if !$0 { pendingPack = nil } }),
            titleVisibility: .visible
        ) {
            Button(L("Apagar %@ (%@)", pendingPack.map { NeuralVoiceStore.label($0.language) } ?? "",
                     ByteCountFormatter.string(fromByteCount: pendingPack?.bytes ?? 0, countStyle: .file)),
                   role: .destructive) {
                if let p = pendingPack { neural.delete(p) }
                pendingPack = nil
            }
            Button("Cancelar", role: .cancel) { pendingPack = nil }
        } message: {
            Text("Apagar libera o espaço; a voz é baixada de novo na próxima vez que você usar aquele idioma.")
        }
    }
}
