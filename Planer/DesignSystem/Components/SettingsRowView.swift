import SwiftUI

/// Zeile der Einstellungen: Beschriftung, Eingabefeld (z. B. `SecureField`) und
/// optionaler Verbindungsstatus. Validierung und Speichern liegen beim Aufrufer
/// (I2); diese View stellt nur dar.
struct SettingsRowView<Content: View>: View {

    enum ConnectionStatus {
        case unknown
        case reachable
        case failed

        var color: Color {
            switch self {
            case .unknown: DesignTokens.Palette.secondaryLabel
            case .reachable: DesignTokens.Palette.success
            case .failed: DesignTokens.Palette.danger
            }
        }

        var accessibilityValue: String {
            switch self {
            case .unknown: "nicht geprüft"
            case .reachable: "erreichbar"
            case .failed: "nicht erreichbar"
            }
        }
    }

    private let title: String
    private let status: ConnectionStatus?
    private let content: Content

    init(
        _ title: String,
        status: ConnectionStatus? = nil,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.status = status
        self.content = content()
    }

    var body: some View {
        HStack(spacing: DesignTokens.Spacing.m) {
            Text(title)
                .font(DesignTokens.Typography.callout)
                .foregroundStyle(DesignTokens.Palette.secondaryLabel)

            Spacer(minLength: DesignTokens.Spacing.s)

            content

            if let status {
                Circle()
                    .fill(status.color)
                    .frame(width: 8, height: 8)
                    .accessibilityLabel(Text("Verbindung"))
                    .accessibilityValue(Text(status.accessibilityValue))
            }
        }
        .padding(.vertical, DesignTokens.Spacing.xs)
    }
}

#Preview("SettingsRowView") {
    Form {
        SettingsRowView("Basis-URL") {
            TextField("https://…", text: .constant(""))
                .multilineTextAlignment(.trailing)
        }
        SettingsRowView("API-Token", status: .reachable) {
            SecureField("Token", text: .constant(""))
                .multilineTextAlignment(.trailing)
        }
    }
}
