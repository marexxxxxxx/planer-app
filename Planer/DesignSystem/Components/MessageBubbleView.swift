import SwiftUI

/// Chat-Blase für die drei Zustände der Design-Vorgabe: Nutzer, Agent, Tool-Call.
struct MessageBubbleView: View {

    enum Role {
        case user
        case agent
        case toolCall

        var background: Color {
            switch self {
            case .user: DesignTokens.Palette.userBubble
            case .agent: DesignTokens.Palette.agentBubble
            case .toolCall: DesignTokens.Palette.toolCallBubble
            }
        }

        var foreground: Color {
            switch self {
            // Weiß auf dem Akzent ist in Light und Dark lesbar; der Akzent selbst
            // wird nicht pro Modus angepasst.
            case .user: .white
            case .agent, .toolCall: DesignTokens.Palette.label
            }
        }

        var isUser: Bool { self == .user }

        var accessibilityPrefix: String {
            switch self {
            case .user: "Du"
            case .agent: "Hermes"
            case .toolCall: "Werkzeugaufruf"
            }
        }
    }

    let role: Role
    let text: String

    var body: some View {
        HStack(spacing: 0) {
            if role.isUser {
                Spacer(minLength: DesignTokens.Spacing.xl)
            }

            Text(text)
                .font(DesignTokens.Typography.body)
                .foregroundStyle(role.foreground)
                .padding(.horizontal, DesignTokens.Spacing.l)
                .padding(.vertical, DesignTokens.Spacing.m)
                .background(
                    role.background,
                    in: RoundedRectangle(
                        cornerRadius: DesignTokens.Radius.bubble,
                        style: .continuous
                    )
                )

            if !role.isUser {
                Spacer(minLength: DesignTokens.Spacing.xl)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text("\(role.accessibilityPrefix): \(text)"))
    }
}

#Preview("MessageBubbleView") {
    VStack(spacing: DesignTokens.Spacing.s) {
        MessageBubbleView(role: .user, text: "Einkaufsliste für heute?")
        MessageBubbleView(role: .agent, text: "Ich lese den Wochenplan aus Mealie.")
        MessageBubbleView(role: .toolCall, text: "mealie_get_mealplan")
    }
    .padding()
}
