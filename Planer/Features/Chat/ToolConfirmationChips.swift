//
//  ToolConfirmationChips.swift
//  Planer
//
//  Freigabe-Chips für ein `approval.request` (spec-chat Rev 7 Delta §3.3.3).
//

import SwiftUI

/// Beantwortet eine Server-Freigabe: „Ausführen“ oder „Ablehnen“.
///
/// Zweck: der Server hat angehalten und bietet Choices an; die Chips zeigen
/// **nur** die angebotenen (`once`/`deny`) und senden erst nach einem Tipp.
/// „Ausführen“ öffnet ausschließlich den Bestätigungsdialog in `ChatView` —
/// gesendet wird dort, nach dem zweiten bewussten Tipp. „Ablehnen“ ist die
/// sichere Richtung und braucht keinen Dialog.
/// Grenze: kennt weder Uhr noch Frist; die abgeleitete `ApprovalPhase` kommt
/// von außen. Führt nichts aus und entscheidet nichts.
struct ToolConfirmationChips: View {

    /// Die Freigabe mit den angebotenen Choices.
    let approval: ChatApproval
    /// Die abgeleitete Phase dieses Eintrags (§4.5).
    let phase: ApprovalPhase
    /// `false`, wenn der Befehl zu lang zum geprüften Freigeben ist (FF-4).
    let allowsExecute: Bool
    /// Öffnet den Bestätigungsdialog; sendet nichts.
    let onRequestExecute: () -> Void
    /// Sendet `deny` sofort.
    let onDeny: () -> Void

    var body: some View {
        HStack(spacing: DesignTokens.Spacing.s) {
            switch phase {
            case .open, .sending:
                buttons
            case .executed, .denied, .expired, .conflict:
                EmptyView()
            }
        }
        .font(DesignTokens.Typography.footnote)
    }

    @ViewBuilder
    private var buttons: some View {
        let isSending = phase == .sending
        let showsExecute = approval.canApproveOnce && allowsExecute

        if showsExecute {
            Button("Ausführen") {
                onRequestExecute()
            }
            .buttonStyle(.borderedProminent)
            .disabled(isSending)
            .accessibilityLabel(
                Text("Freigabe für \(approval.command ?? "den Befehl") ausführen")
            )
        }

        if approval.canDeny {
            Button("Ablehnen") {
                onDeny()
            }
            .buttonStyle(.bordered)
            .disabled(isSending)
            .accessibilityLabel(
                Text("Freigabe für \(approval.command ?? "den Befehl") ablehnen")
            )
        }

        if !showsExecute && !approval.canDeny {
            Text("Keine ausführbare Auswahl.")
                .foregroundStyle(DesignTokens.Palette.secondaryLabel)
        }

        if isSending {
            Text("Wird gesendet …")
                .foregroundStyle(DesignTokens.Palette.secondaryLabel)
        }
    }
}

#Preview("ToolConfirmationChips") {
    VStack(alignment: .leading, spacing: DesignTokens.Spacing.s) {
        ToolConfirmationChips(
            approval: ChatApproval(
                runID: "run_123",
                command: "hermes_tasks_create(title: \"Milch kaufen\")",
                description: "Hermes möchte eine Aufgabe anlegen.",
                choices: ["once", "deny", "session"]
            ),
            phase: .open,
            allowsExecute: true,
            onRequestExecute: {},
            onDeny: {}
        )
        ToolConfirmationChips(
            approval: ChatApproval(
                runID: "run_123",
                command: "hermes_tasks_create(title: \"Milch kaufen\")",
                description: "Hermes möchte eine Aufgabe anlegen.",
                choices: ["once", "deny"]
            ),
            phase: .sending,
            allowsExecute: true,
            onRequestExecute: {},
            onDeny: {}
        )
        ToolConfirmationChips(
            approval: ChatApproval(
                runID: "run_123",
                command: nil,
                description: nil,
                choices: ["session", "always"]
            ),
            phase: .open,
            allowsExecute: true,
            onRequestExecute: {},
            onDeny: {}
        )
    }
    .padding()
}
