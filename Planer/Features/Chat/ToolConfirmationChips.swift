//
//  ToolConfirmationChips.swift
//  Planer
//
//  Freigabe-Chips für ein `approval.request` (spec-chat Rev 4 §4.7, §4.10).
//

import SwiftUI

/// Beantwortet eine Server-Freigabe: „Ausführen“ oder „Ablehnen“.
///
/// Zweck: der Server hat angehalten und bietet Choices an; die Chips zeigen
/// **nur** die angebotenen (`once`/`deny`) und senden erst nach einem Tipp.
/// Grenze: führt nichts aus und entscheidet nichts — der POST läuft über
/// `ChatViewModel.decideApproval`, der auch die fail-closed-Prädikate prüft.
/// Ohne Tipp wird nichts gesendet; während des POST sind beide Chips inaktiv.
/// Befehl und Beschreibung zeigt die Karte, nicht dieser Baustein.
struct ToolConfirmationChips: View {

    /// Die Freigabe mit den angebotenen Choices.
    let approval: ChatApproval
    /// `true`, solange der POST zu dieser Freigabe läuft.
    let isSending: Bool
    /// Meldet die gewählte Choice an das ViewModel.
    let onDecide: (ChatApprovalChoice) -> Void

    var body: some View {
        HStack(spacing: DesignTokens.Spacing.s) {
            if approval.canApproveOnce {
                Button("Ausführen") {
                    onDecide(.once)
                }
                .buttonStyle(.borderedProminent)
                .disabled(isSending)
                .accessibilityLabel(
                    Text("Freigabe für \(approval.command ?? "den Befehl") ausführen")
                )
            }

            if approval.canDeny {
                Button("Ablehnen") {
                    onDecide(.deny)
                }
                .buttonStyle(.bordered)
                .disabled(isSending)
                .accessibilityLabel(
                    Text("Freigabe für \(approval.command ?? "den Befehl") ablehnen")
                )
            }

            if isSending {
                Text("Wird gesendet …")
                    .font(DesignTokens.Typography.footnote)
                    .foregroundStyle(DesignTokens.Palette.secondaryLabel)
            }
        }
        .font(DesignTokens.Typography.footnote)
    }
}

#Preview("ToolConfirmationChips") {
    ToolConfirmationChips(
        approval: ChatApproval(
            runID: "run_123",
            command: "hermes_tasks_create(title: \"Milch kaufen\")",
            description: "Hermes möchte eine Aufgabe anlegen.",
            choices: ["once", "deny", "session"]
        ),
        isSending: false,
        onDecide: { _ in }
    )
    .padding()
}
