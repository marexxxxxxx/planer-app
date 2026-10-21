//
//  ToolCallCard.swift
//  Planer
//
//  Werkzeug-Karte: Name, Status, Argumente, Ergebnis — auf-/zuklappbar
//  (spec-chat Rev 4 §4.6, §4.10).
//

import SwiftUI

/// Statuswort und Farbe der Werkzeugkarte.
///
/// Bewusst hier und nicht im ViewModel: es ist reine Darstellung. `completed`
/// heißt „abgeschlossen“, **nicht** „erfolgreich“ — der Live-Strom kennt kein
/// Ergebnis (§4.6).
extension ToolCallStatus {

    var displayLabel: String {
        switch self {
        case .running:
            return "läuft"
        case .completed:
            return "abgeschlossen"
        case .awaitingApproval:
            return "wartet auf Freigabe"
        case .denied:
            return "abgelehnt"
        }
    }

    var displayTint: Color {
        switch self {
        case .running, .completed:
            return DesignTokens.Palette.secondaryLabel
        case .awaitingApproval:
            return DesignTokens.Palette.userBubble
        case .denied:
            return DesignTokens.Palette.danger
        }
    }
}

/// Eine Werkzeugkarte im Verlauf.
///
/// Zweck: Name, Status, Argumente und Ergebnis eines serverseitigen
/// Werkzeugaufrufs an einer Stelle; zugeklappt bleibt die Karte eine Zeile.
/// Grenze: führt nichts aus und lädt nichts nach. Auf-/Zu-Zustand und Inhalte
/// kommen aus `ChatViewModel.Entry`; die View kürzt nicht (das tut das Modell,
/// §5.6).
struct ToolCallCard: View {

    let name: String
    /// E4: `emoji` aus `hermes.tool.progress`; `nil` → generisches SF-Symbol.
    let emoji: String?
    let status: ToolCallStatus
    /// Roher JSON-Text aus `tool_calls[].function.arguments`; `nil` = nicht geladen.
    let argumentsText: String?
    /// Text der `tool`-Nachricht; `nil` = nicht geladen.
    let resultText: String?
    /// `true`, wenn `Entry.toolDetailDisclosure == .expanded`.
    let isExpanded: Bool
    /// Tipp auf die Kopfzeile; toggelt genau diese Karte.
    let onToggle: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
            Button(action: onToggle) {
                HStack(spacing: DesignTokens.Spacing.xs) {
                    if let emoji, !emoji.isEmpty {
                        Text(emoji)
                            .font(DesignTokens.Typography.footnote)
                    } else {
                        Image(systemName: "wrench.and.screwdriver")
                            .font(DesignTokens.Typography.footnote)
                            .foregroundStyle(DesignTokens.Palette.secondaryLabel)
                    }

                    Text(name)
                        .font(DesignTokens.Typography.footnote.monospaced())
                        .foregroundStyle(DesignTokens.Palette.label)
                        .lineLimit(1)

                    Spacer(minLength: DesignTokens.Spacing.xs)

                    Text(status.displayLabel)
                        .font(DesignTokens.Typography.footnote)
                        .foregroundStyle(status.displayTint)

                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(DesignTokens.Typography.footnote)
                        .foregroundStyle(DesignTokens.Palette.secondaryLabel)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("Werkzeug \(name), \(status.displayLabel)"))
            .accessibilityValue(Text(isExpanded ? "ausgeklappt" : "eingeklappt"))
            .accessibilityHint(Text("Blendet Argumente und Ergebnis ein oder aus."))

            if isExpanded {
                detail(
                    title: "Argumente",
                    value: argumentsText,
                    missing: "Argumente nicht geladen"
                )
                detail(
                    title: "Ergebnis",
                    value: resultText,
                    missing: "Ergebnis nicht geladen"
                )
            }
        }
        .padding(.horizontal, DesignTokens.Spacing.m)
        .padding(.vertical, DesignTokens.Spacing.s)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            DesignTokens.Palette.toolCallBubble,
            in: RoundedRectangle(cornerRadius: DesignTokens.Radius.card, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: DesignTokens.Radius.card, style: .continuous)
                .stroke(DesignTokens.Palette.secondaryLabel.opacity(0.25), lineWidth: 1)
        )
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private func detail(title: String, value: String?, missing: String) -> some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
            Text(title)
                .font(DesignTokens.Typography.footnote)
                .foregroundStyle(DesignTokens.Palette.secondaryLabel)

            Text(value ?? missing)
                .font(DesignTokens.Typography.footnote.monospaced())
                .foregroundStyle(
                    value == nil
                        ? DesignTokens.Palette.secondaryLabel
                        : DesignTokens.Palette.label
                )
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.top, DesignTokens.Spacing.xs)
    }
}

#Preview("ToolCallCard") {
    VStack(alignment: .leading, spacing: DesignTokens.Spacing.s) {
        ToolCallCard(
            name: "hermes_tasks_list",
            emoji: "📋",
            status: .running,
            argumentsText: nil,
            resultText: nil,
            isExpanded: false,
            onToggle: {}
        )
        ToolCallCard(
            name: "hermes_tasks_list",
            emoji: "📋",
            status: .completed,
            argumentsText: "{\n  \"status\": \"open\"\n}",
            resultText: "3 offene Aufgaben",
            isExpanded: true,
            onToggle: {}
        )
        ToolCallCard(
            name: "grocy_stock_get",
            emoji: nil,
            status: .completed,
            argumentsText: nil,
            resultText: nil,
            isExpanded: true,
            onToggle: {}
        )
    }
    .padding()
}
