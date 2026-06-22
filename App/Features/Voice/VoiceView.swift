import SwiftUI
import OpenWebUIKit

/// An existing chat to resume in voice mode (passed from a chat's voice button).
struct VoiceSeed: Identifiable {
    let id = UUID()
    let chatID: String?
    let messages: [OWMessage]
    var model: String? = nil
}

/// Voice-first conversation screen — a hands-free "talk to it" companion.
/// Tap the orb to start; it then loops listen → think → speak on its own.
///
/// Two entry points: the **Voz tab** (always a fresh conversation) and a chat's
/// voice button (`seed` set → resumes that conversation, saving back to it).
struct VoiceView: View {
    let app: AppState
    let seed: VoiceSeed?
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss
    @StateObject private var convo: VoiceConversation
    @ObservedObject private var speech = SpeechManager.shared
    @State private var pulse = false

    init(app: AppState, seed: VoiceSeed? = nil) {
        self.app = app
        self.seed = seed
        _convo = StateObject(wrappedValue: VoiceConversation(client: app.client,
                                                             completions: app.completions,
                                                             models: app.models))
    }

    var body: some View {
        NavigationStack {
            ZStack {
                theme.bg.ignoresSafeArea()
                if theme.backdrop { ThemeBackdrop(theme: theme) }
                VStack(spacing: 0) {
                    transcript
                    Spacer(minLength: 8)
                    orb
                    statusLine
                    Spacer(minLength: 8)
                    controlButton
                }
                .padding(16)
            }
            .navigationTitle("Voz")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    if seed != nil {
                        Button("Fechar") { convo.stop(); dismiss() }.foregroundStyle(theme.accent)
                    } else if !convo.turns.isEmpty {
                        Button { convo.reset() } label: { Image(systemName: "square.and.pencil") }
                    }
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    voicePicker
                    modelPicker
                }
            }
        }
        .tint(theme.accent)
        .onChange(of: convo.phase) { _, p in
            pulse = (p == .listening || p == .speaking)
        }
        .onAppear {
            if speech.useServer { Task { await speech.loadServerVoices() } }
            if let seed { convo.seedOnce(chatID: seed.chatID, messages: seed.messages, model: seed.model) }
            else if !convo.active { convo.reset() }   // Voz tab → always a new conversation
        }
    }

    /// Per-conversation TTS voice (only for the server engine, which advertises voices).
    @ViewBuilder private var voicePicker: some View {
        if speech.useServer && !speech.serverVoices.isEmpty {
            Menu {
                Button("Voz padrão") { convo.setVoice("") }
                ForEach(speech.serverVoices) { v in Button(v.name) { convo.setVoice(v.id) } }
            } label: {
                HStack(spacing: 3) {
                    Image(systemName: "person.wave.2").font(.system(size: 9))
                    Text(speech.serverVoices.first { $0.id == convo.ttsVoice }?.name ?? "Voz")
                        .font(.ody(size: 11, design: .monospaced)).lineLimit(1)
                }.foregroundStyle(theme.accent)
            }
        }
    }

    // MARK: - Transcript

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(convo.turns) { turn in
                        bubble(turn).id(turn.id)
                    }
                    if !convo.liveText.isEmpty {
                        bubble(.init(role: "user", text: convo.liveText)).opacity(0.6)
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 4)
            }
            .onChange(of: convo.turns.count) { _, _ in withAnimation { proxy.scrollTo("bottom") } }
            .onChange(of: convo.reply) { _, _ in proxy.scrollTo("bottom") }
        }
    }

    private func bubble(_ turn: VoiceConversation.Turn) -> some View {
        let isUser = turn.role == "user"
        return HStack {
            if isUser { Spacer(minLength: 40) }
            Text(turn.text.isEmpty ? "…" : turn.text)
                .font(.ody(.subheadline, design: .monospaced))
                .foregroundStyle(isUser ? theme.fg : theme.fg)
                .padding(.horizontal, 12).padding(.vertical, 8)
                .background(isUser ? theme.userBubble : theme.aiBubble,
                            in: RoundedRectangle(cornerRadius: 14))
                .overlay(RoundedRectangle(cornerRadius: 14).stroke(theme.border, lineWidth: 1))
            if !isUser { Spacer(minLength: 40) }
        }
    }

    // MARK: - Orb

    private var orb: some View {
        ZStack {
            Circle()
                .fill(theme.accent.opacity(0.18))
                .frame(width: 190, height: 190)
                .scaleEffect(pulse ? 1.12 : 0.9)
                .animation(pulse ? .easeInOut(duration: 0.9).repeatForever(autoreverses: true)
                                 : .easeOut(duration: 0.3), value: pulse)
            Circle()
                .fill(theme.accent.opacity(0.30))
                .frame(width: 140, height: 140)
            Circle()
                .fill(theme.accent)
                .frame(width: 104, height: 104)
            Group {
                switch convo.phase {
                case .thinking:
                    ProgressView().tint(theme.bg).controlSize(.large)
                default:
                    Image(systemName: orbIcon).font(.system(size: 40, weight: .semibold))
                        .foregroundStyle(theme.bg)
                        .symbolEffect(.variableColor.iterative, isActive: convo.phase == .speaking)
                }
            }
        }
        .contentShape(Circle())
        .onTapGesture { convo.tapOrb() }
    }

    private var orbIcon: String {
        switch convo.phase {
        case .listening: return "waveform"
        case .speaking:  return "speaker.wave.3.fill"
        default:         return "mic.fill"
        }
    }

    private var statusLine: some View {
        Text(statusText)
            .font(.ody(.subheadline, design: .monospaced))
            .foregroundStyle(theme.secondaryText)
            .padding(.top, 14)
            .multilineTextAlignment(.center)
    }

    private var statusText: String {
        if let e = convo.error { return e }
        switch convo.phase {
        case .idle:      return convo.active ? "…" : "Toque para conversar"
        case .listening: return "Ouvindo…"
        case .thinking:  return "Pensando…"
        case .speaking:  return "Falando…"
        }
    }

    // MARK: - Controls

    private var controlButton: some View {
        Button { convo.toggleSession() } label: {
            HStack(spacing: 8) {
                Image(systemName: convo.active ? "stop.fill" : "mic.fill")
                Text(convo.active ? "Encerrar" : "Iniciar conversa")
                    .font(.ody(.headline, design: .monospaced))
            }
            .frame(maxWidth: .infinity).padding(.vertical, 15)
            .background(convo.active ? theme.panel : theme.accent,
                        in: RoundedRectangle(cornerRadius: 14))
            .foregroundStyle(convo.active ? theme.accent : .white)
            .overlay(RoundedRectangle(cornerRadius: 14)
                .stroke(convo.active ? theme.accent : .clear, lineWidth: 1))
        }
    }

    private var modelPicker: some View {
        Menu {
            ForEach(convo.models) { m in Button(m.shortName) { convo.model = m.id } }
        } label: {
            HStack(spacing: 3) {
                Text(convo.models.first { $0.id == convo.model }?.shortName ?? "Modelo")
                    .font(.ody(size: 11, design: .monospaced)).lineLimit(1)
                Image(systemName: "chevron.up.chevron.down").font(.system(size: 8))
            }
            .foregroundStyle(theme.accent).frame(maxWidth: 140, alignment: .trailing)
        }
    }
}
