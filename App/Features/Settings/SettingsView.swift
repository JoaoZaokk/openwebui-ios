import SwiftUI
import OpenWebUIKit

/// Minimal settings: appearance, account, server — fully themed (rows use
/// theme.panel, headers/text use theme colors) + the Hermes-style backdrop.
struct SettingsView: View {
    @EnvironmentObject private var app: AppState
    @EnvironmentObject private var themes: ThemeStore
    @EnvironmentObject private var lang: LanguageManager
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss
    @State private var showServer = false

    var body: some View {
        NavigationStack {
            ZStack {
                theme.bg.ignoresSafeArea()
                if theme.backdrop { ThemeBackdrop(theme: theme) }
                List {
                    section("IDIOMA") {
                        NavigationLink {
                            LanguagePickerView()
                        } label: {
                            Label {
                                HStack {
                                    Text("Idioma").font(.ody(.body, design: .monospaced)).foregroundStyle(theme.fg)
                                    Spacer(minLength: 8)
                                    Text(verbatim: lang.isAutomatic
                                         ? "🌐 \(LanguageManager.deviceLanguage().endonym)"
                                         : "\(lang.current.flag) \(lang.current.endonym)")
                                        .font(.ody(.subheadline, design: .monospaced))
                                        .foregroundStyle(theme.secondaryText).lineLimit(1)
                                }
                            } icon: { Image(systemName: "globe").foregroundStyle(theme.accent) }
                        }
                        .listRowBackground(theme.panel)
                    }

                    section("APARÊNCIA") {
                        NavigationLink {
                            ThemePickerView(inSheet: false).environmentObject(themes)
                        } label: {
                            Label { Text("Tema").font(.ody(.body, design: .monospaced)).foregroundStyle(theme.fg) }
                            icon: { Image(systemName: "paintpalette").foregroundStyle(theme.accent) }
                        }
                        .listRowBackground(theme.panel)
                    }

                    section("VOZ") {
                        NavigationLink {
                            VoiceSettingsView()
                        } label: {
                            Label { Text("Voz e modelos").font(.ody(.body, design: .monospaced)).foregroundStyle(theme.fg) }
                            icon: { Image(systemName: "waveform").foregroundStyle(theme.accent) }
                        }
                        .listRowBackground(theme.panel)
                    }

                    section("CONTA") {
                        if let u = app.user {
                            labeled("Usuário", u.name ?? u.email ?? "—").listRowBackground(theme.panel)
                            if let email = u.email { labeled("Email", email).listRowBackground(theme.panel) }
                        }
                        Button(role: .destructive) {
                            Task { await app.logout(); dismiss() }
                        } label: {
                            Label("Sair", systemImage: "rectangle.portrait.and.arrow.right")
                                .font(.ody(.body, design: .monospaced))
                        }
                        .listRowBackground(theme.panel)
                    }

                    section("SERVIDOR") {
                        Button { showServer = true } label: {
                            labeled("Endereço", app.serverConfig.baseURL.host ?? app.serverConfig.baseURL.absoluteString)
                        }
                        .listRowBackground(theme.panel)
                    }
                }
                .scrollContentBackground(.hidden)
            }
            .navigationTitle("Ajustes")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("OK") { dismiss() }.foregroundStyle(theme.accent)
                }
            }
            .sheet(isPresented: $showServer) { ServerSheet().environmentObject(app) }
        }
        .tint(theme.accent)
    }

    @ViewBuilder private func section<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
        Section {
            content()
        } header: {
            Text(LocalizedStringKey(title)).font(.ody(size: 11, design: .monospaced)).foregroundStyle(theme.secondaryText)
        }
    }

    private func labeled(_ key: String, _ value: String) -> some View {
        HStack {
            Text(LocalizedStringKey(key)).font(.ody(.body, design: .monospaced)).foregroundStyle(theme.fg)
            Spacer(minLength: 8)
            Text(value).font(.ody(.subheadline, design: .monospaced))
                .foregroundStyle(theme.secondaryText).lineLimit(1)
        }
    }
}

/// Server picker — shown from Settings and from the login screen.
struct ServerSheet: View {
    @EnvironmentObject private var app: AppState
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""

    var body: some View {
        NavigationStack {
            ZStack {
                theme.bg.ignoresSafeArea()
                if theme.backdrop { ThemeBackdrop(theme: theme) }
                Form {
                    Section {
                        TextField("http://localhost:3000", text: $text)
                            .font(.ody(.body, design: .monospaced))
                            .foregroundStyle(theme.fg)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .keyboardType(.URL)
                            .listRowBackground(theme.panel)
                    } header: {
                        Text("ENDEREÇO DO SERVIDOR OPEN WEBUI")
                            .font(.ody(size: 11, design: .monospaced)).foregroundStyle(theme.secondaryText)
                    } footer: {
                        Text("Ex.: http://localhost:3000  ou  https://meu-servidor.com\nSe você não digitar http(s)://, assumimos https.")
                            .font(.ody(size: 10, design: .monospaced)).foregroundStyle(theme.secondaryText)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .scrollContentBackground(.hidden)
            }
            .navigationTitle("Servidor")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancelar") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Salvar") {
                        if let url = ServerConfig.normalize(text) { app.updateServer(url) }
                        dismiss()
                    }
                    .disabled(ServerConfig.normalize(text) == nil)
                }
            }
        }
        .tint(theme.accent)
        // Start empty on first run (don't pre-fill the placeholder); keep the saved one otherwise.
        .onAppear { text = ServerConfig.isConfigured ? app.serverConfig.baseURL.absoluteString : "" }
    }
}
