//
//  ThinkingDisclosureView.swift
//  Planer
//
//  Denk-Klappe unter einer Agent-Bubble (spec-chat Rev 4 §4.5, §4.10).
//

import SwiftUI

/// Zeigt das Denken eines Eintrags — eingeklappt per Default, je Eintrag
/// aufklappbar.
///
/// Zweck: das Denken ist sichtbar, ohne den Verlauf zu dominieren; der
/// Auf-/Zu-Zustand kommt aus `ChatViewModel.Entry.reasoningDisclosure` und wird
/// vom ViewModel gehalten, nicht hier.
/// Grenze: keine Logik — die View rendert den übergebenen Text und meldet nur
/// den Tipp. Kein Reasoning geliefert heißt: diese View wird gar nicht gebaut
/// (A3), es gibt keinen Platzhalter.
struct ThinkingDisclosureView: View {

    /// Der bereits gekürzte Denk-Text aus dem Eintrag.
    let text: String
    /// `true`, wenn `Entry.reasoningDisclosure == .expanded`.
    let isExpanded: Bool
    /// Tipp auf die Zeile; toggelt genau diesen Eintrag.
    let onToggle: () -> Void

    /// §4.5: max. 240 pt hohe, scrollbare Fläche.
    private let maxHeight: CGFloat = 240

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
            Button(action: onToggle) {
                HStack(spacing: DesignTokens.Spacing.xs) {
                    Image(systemName: "brain")
                        .font(DesignTokens.Typography.footnote)
                        .foregroundStyle(DesignTokens.Palette.secondaryLabel)

                    Text("Gedanken")
                        .font(DesignTokens.Typography.footnote)
                        .foregroundStyle(DesignTokens.Palette.secondaryLabel)

                    Spacer(minLength: DesignTokens.Spacing.xs)

                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(DesignTokens.Typography.footnote)
                        .foregroundStyle(DesignTokens.Palette.secondaryLabel)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text(isExpanded ? "Gedanken ausblenden" : "Gedanken anzeigen"))
            .accessibilityValue(Text(isExpanded ? "ausgeklappt" : "eingeklappt"))
            .accessibilityHint(Text("Blendet die Gedanken dieses Eintrags ein oder aus."))

            if isExpanded {
                ScrollView {
                    Text(text)
                        .font(DesignTokens.Typography.footnote)
                        .foregroundStyle(DesignTokens.Palette.secondaryLabel)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: maxHeight)
                .padding(DesignTokens.Spacing.s)
                .background(
                    DesignTokens.Palette.tertiaryBackground,
                    in: RoundedRectangle(
                        cornerRadius: DesignTokens.Radius.card,
                        style: .continuous
                    )
                )
            }
        }
    }
}

#Preview("ThinkingDisclosureView") {
    VStack(alignment: .leading, spacing: DesignTokens.Spacing.l) {
        ThinkingDisclosureView(
            text: "Ich prüfe zuerst den Wochenplan und danach den Bestand.",
            isExpanded: false,
            onToggle: {}
        )
        ThinkingDisclosureView(
            text: "Ich prüfe zuerst den Wochenplan und danach den Bestand.",
            isExpanded: true,
            onToggle: {}
        )
    }
    .padding()
}
