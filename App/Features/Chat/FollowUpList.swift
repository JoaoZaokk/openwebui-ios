import SwiftUI

/// The questions the server suggests under the last reply (issue #15) — the
/// web's "Follow up" list: plain rows split by a hairline, and a tap sends the
/// question as the next message.
struct FollowUpList: View {
    let questions: [String]
    let onPick: (String) -> Void
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Continuar a conversa")
                .font(.ody(size: 12))
                .foregroundStyle(theme.secondaryText)
                .padding(.bottom, 4)
            ForEach(Array(questions.enumerated()), id: \.offset) { i, q in
                if i > 0 { Divider().overlay(theme.border.opacity(0.4)) }
                Button { onPick(q) } label: {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Image(systemName: "arrow.turn.down.right")
                            .font(.ody(size: 11))
                            .foregroundStyle(theme.accent)
                        Text(verbatim: q)
                            .font(.ody(.subheadline))
                            .foregroundStyle(theme.fg)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                        Spacer(minLength: 0)
                    }
                    .padding(.vertical, 9)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(verbatim: q))
                .accessibilityHint(Text("Envia esta pergunta"))
                .accessibilityIdentifier("chat.followUp")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 4)
    }
}
