import SwiftUI
import OpenWebUIKit

/// Ajustes › Diagnóstico. Everything here is read from disk, so it works for
/// the *previous* run — the one that was killed loading a model — and offline.
/// Nothing leaves the device unless the user sends a bug report by hand.
struct DiagnosticsView: View {
    @Environment(\.theme) private var theme
    @State private var showReport = false
    @State private var death: DiagEvent?
    @State private var events: [DiagEvent] = []
    @State private var engineLog: [String] = []
    @State private var exported: Bool?
    @State private var available: Int64?

    var body: some View {
        List {
            Section {
                if let death {
                    Text(death.explanation).font(.ody(.body)).foregroundStyle(theme.fg)
                    Text(death.date.formatted(date: .abbreviated, time: .shortened))
                        .font(.ody(size: 10)).foregroundStyle(theme.secondaryText)
                } else {
                    Text("Nenhum registro.").font(.ody(.body)).foregroundStyle(theme.secondaryText)
                }
            } header: {
                Text("Último encerramento anormal").font(.ody(size: 11)).foregroundStyle(theme.secondaryText)
            } footer: {
                Text("O que o app registrou sobre travamentos, memória e o motor de voz. Fica no aparelho; enviar é opcional.")
                    .font(.ody(size: 10)).foregroundStyle(theme.secondaryText)
            }
            .listRowBackground(theme.panel)

            Section {
                HStack {
                    Text(L("Disponível para o app: %@", MemoryBudget.human(available)))
                    Spacer()
                    Text(L("Física: %@", MemoryBudget.human(MemoryBudget.physicalBytes)))
                }
                .font(.ody(.body)).foregroundStyle(theme.fg)
                #if os(macOS)
                Text("No Mac o limite por app não é exposto pelo sistema.")
                    .font(.ody(size: 10)).foregroundStyle(theme.secondaryText)
                #else
                Text("É quanto o app ainda pode usar antes de o sistema encerrá-lo. Um modelo precisa caber aqui com folga.")
                    .font(.ody(size: 10)).foregroundStyle(theme.secondaryText)
                #endif
            } header: {
                Text("Memória agora").font(.ody(size: 11)).foregroundStyle(theme.secondaryText)
            }
            .listRowBackground(theme.panel)

            Section {
                Button { showReport = true } label: {
                    Label("Reportar bug", systemImage: "ladybug")
                }
                .buttonStyle(.plain).foregroundStyle(theme.accent).font(.ody(.subheadline))
                .sheet(isPresented: $showReport) { BugReportSheet() }
                Text("Abre um e-mail para o desenvolvedor com a última hora de registros. Você vê tudo antes de enviar.")
                    .font(.ody(size: 10)).foregroundStyle(theme.secondaryText)
                HStack {
                    Button {
                        Task { exported = await owSaveJSON(DiagnosticsStore.shared.exportJSON(), suggested: "openwebui-diagnostico.json") }
                    } label: { Label("Exportar diagnóstico", systemImage: "square.and.arrow.up") }
                    .buttonStyle(.plain).foregroundStyle(theme.accent)
                    if exported == true {
                        Label("Exportado", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(theme.green).font(.ody(size: 11))
                    }
                    Spacer()
                }
            }
            .listRowBackground(theme.panel)

            Section {
                if events.isEmpty {
                    Text("Nenhum registro.").font(.ody(.body)).foregroundStyle(theme.secondaryText)
                }
                ForEach(events.reversed().prefix(40)) { e in
                    VStack(alignment: .leading, spacing: 1) {
                        HStack {
                            Text(e.name).font(.ody(size: 11))
                                .foregroundStyle(e.name.hasSuffix(".fail") || e.name.hasPrefix("death") || e.name == "crash" ? theme.danger : theme.fg)
                            Spacer()
                            Text(e.date.formatted(date: .omitted, time: .standard))
                                .font(.ody(size: 10)).foregroundStyle(theme.secondaryText)
                        }
                        if !e.props.isEmpty {
                            Text(e.props.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: "  "))
                                .font(.ody(size: 10)).foregroundStyle(theme.secondaryText).lineLimit(3)
                        }
                    }
                }
            } header: {
                Text("Eventos recentes").font(.ody(size: 11)).foregroundStyle(theme.secondaryText)
            }
            .listRowBackground(theme.panel)

            Section {
                if engineLog.isEmpty {
                    Text("Nenhum registro.").font(.ody(.body)).foregroundStyle(theme.secondaryText)
                } else {
                    ScrollView(.horizontal, showsIndicators: false) {
                        Text(engineLog.suffix(60).joined(separator: "\n"))
                            .font(.system(size: 10, design: .monospaced)).foregroundStyle(theme.fg)
                            .textSelection(.enabled)
                    }
                }
            } header: {
                Text("Log do motor de voz").font(.ody(size: 11)).foregroundStyle(theme.secondaryText)
            }
            .listRowBackground(theme.panel)
        }
        .scrollContentBackground(.hidden)
        .background(theme.bg)
        .navigationTitle("Diagnóstico")
        .navigationBarTitleDisplayMode(.inline)
        .tint(theme.accent)
        .onAppear(perform: reload)
    }

    private func reload() {
        let store = DiagnosticsStore.shared
        death = store.lastSuspectedDeath()
        events = store.recentEvents(limit: 200)
        engineLog = store.engineLogTail(120)
        available = MemoryBudget.availableBytes
    }
}
