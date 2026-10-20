//
//  ToolCallBadge.swift
//  Planer
//
//  Sichtbarer Werkzeugaufruf im Chat (spec-ios §1/I3, §9.3).
//

import SwiftUI

/// Kompakte Anzeige eines Werkzeugaufrufs: Name, Zustand und optionales Ergebnis.
///
/// Zweck: macht sichtbar, dass Hermes ein Werkzeug ausführt (`tools/call`) —
/// nicht nur Text liefert. Der Zustand ist immer eindeutig: „läuft“ wird nie als
/// Erfolg dargestellt.
/// Grenze: zeigt keine Argumente als bearbeitbares Formular und startet keinen
/// Aufruf; der Aufruf gehört dem `ChatViewModel`. Lange Ergebnisse werden
/// eingeklappt, damit die Blase die Liste nicht dominiert.
struct ToolCallBadge: View {

    /// Zustand eines Werkzeugaufrufs.
    enum Status: Equatable, Sendable {
        case running
        case succeeded
        case failed

        var label: String {
            switch self {
            case .running:
                return "läuft"
            case .succeeded:
                return "fertig"
            case .failed:
                return "Fehler"
            }
        }

        var systemImage: String {
            switch self {
            case .running:
                return "hourglass"
            case .succeeded:
                return "checkmark.circle"
            case .failed:
                return "exclamationmark.triangle"
            }
        }

        var tint: Color {
            switch self {
            case .running:
                return DesignTokens.Palette.secondaryLabel
            case .succeeded:
                return DesignTokens.Palette.success
            case .failed:
                return DesignTokens.Palette.danger
            }
        }
    }

    let name: String
    let status: Status
    /// Ergebnis- oder Fehlertext; `nil` solange der Aufruf läuft.
    var detail: String?

    @State private var showsDetail = false

    /// Mehr Zeichen werden nicht angezeigt; die Blase bleibt lesbar.
    private let detailLimit = 600

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
            Button {
                guard detail != nil else { return }
                showsDetail.toggle()
            } label: {
                HStack(spacing: DesignTokens.Spacing.xs) {
                    Image(systemName: "wrench.and.screwdriver")
                        .font(DesignTokens.Typography.footnote)
                        .foregroundStyle(DesignTokens.Palette.secondaryLabel)

                    Text(name)
                        .font(DesignTokens.Typography.footnote.monospaced())
                        .foregroundStyle(DesignTokens.Palette.label)
                        .lineLimit(1)

                    Spacer(minLength: DesignTokens.Spacing.xs)

                    Image(systemName: status.systemImage)
                        .font(DesignTokens.Typography.footnote)
                        .foregroundStyle(status.tint)

                    Text(status.label)
                        .font(DesignTokens.Typography.footnote)
                        .foregroundStyle(DesignTokens.Palette.secondaryLabel)

                    if detail != nil {
                        Image(systemName: showsDetail ? "chevron.up" : "chevron.down")
                            .font(DesignTokens.Typography.footnote)
                            .foregroundStyle(DesignTokens.Palette.secondaryLabel)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("Werkzeugaufruf \(name): \(status.label)"))

            if showsDetail, let detail, !detail.isEmpty {
                Text(trimmed(detail))
                    .font(DesignTokens.Typography.footnote)
                    .foregroundStyle(DesignTokens.Palette.secondaryLabel)
                    .textSelection(.enabled)
            }
        }
        .padding(.horizontal, DesignTokens.Spacing.m)
        .padding(.vertical, DesignTokens.Spacing.s)
        .background(
            DesignTokens.Palette.toolCallBubble,
            in: RoundedRectangle(cornerRadius: DesignTokens.Radius.card, style: .continuous)
        )
    }

    private func trimmed(_ value: String) -> String {
        guard value.count > detailLimit else { return value }
        return String(value.prefix(detailLimit)) + "…"
    }
}

#Preview("ToolCallBadge") {
    VStack(alignment: .leading, spacing: DesignTokens.Spacing.s) {
        ToolCallBadge(name: "tools/list", status: .succeeded)
        ToolCallBadge(name: "hermes_tasks_create", status: .running)
        ToolCallBadge(
            name: "grocy_stock_get",
            status: .failed,
            detail: "Serverfehler (INTERNAL): Bestand nicht lesbar."
        )
    }
    .padding()
}
