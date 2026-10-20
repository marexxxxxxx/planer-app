//
//  ToolConfirmationChips.swift
//  Planer
//
//  Action-Chips für einen bestätigungspflichtigen Werkzeugaufruf
//  (Design-Spec §4/Tab 1, Review-Befund N5).
//

import SwiftUI

/// Inline-Freigabe eines Werkzeugaufrufs: „Ausführen“ oder „Ablehnen“.
///
/// Zweck: der Nutzer entscheidet, bevor ein schreibendes `tools/call` an Hermes
/// geht. Der Prompt nennt das Werkzeug; ohne Tipp auf „Ausführen“ passiert
/// nichts.
/// Grenze: führt selbst nichts aus und kennt keine Argumente — die Zustands-
/// übergänge liegen in `ChatViewModel`, das Ergebnis erscheint im `ToolCallBadge`.
struct ToolConfirmationChips: View {

    let toolName: String
    let onApprove: () -> Void
    let onDecline: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.s) {
            Text(ToolCallPolicy.prompt(for: toolName))
                .font(DesignTokens.Typography.footnote)
                .foregroundStyle(DesignTokens.Palette.secondaryLabel)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: DesignTokens.Spacing.s) {
                Button(ToolCallPolicy.approveTitle, action: onApprove)
                    .buttonStyle(.borderedProminent)
                    .accessibilityLabel(
                        Text("Werkzeug \(toolName) ausführen")
                    )

                Button(ToolCallPolicy.declineTitle, action: onDecline)
                    .buttonStyle(.bordered)
                    .accessibilityLabel(
                        Text("Werkzeug \(toolName) ablehnen")
                    )
            }
            .font(DesignTokens.Typography.footnote)
        }
        .padding(.horizontal, DesignTokens.Spacing.m)
        .padding(.vertical, DesignTokens.Spacing.s)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            DesignTokens.Palette.secondaryBackground,
            in: RoundedRectangle(cornerRadius: DesignTokens.Radius.card, style: .continuous)
        )
        .accessibilityElement(children: .contain)
    }
}

#Preview("ToolConfirmationChips") {
    ToolConfirmationChips(
        toolName: "task_create",
        onApprove: {},
        onDecline: {}
    )
    .padding()
}
