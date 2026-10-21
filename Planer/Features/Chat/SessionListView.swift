//
//  SessionListView.swift
//  Planer
//
//  Verlaufs-Sheet des Chat-Tabs (spec-chat Rev 4 §4.1).
//

import SwiftUI

/// Liste der Unterhaltungen als Sheet.
///
/// Zweck: eine Zeile je Session mit Titel, Vorschau, relativer Zeit und
/// Nachrichtenzahl; „Neue Unterhaltung“ und „Mehr laden“ sind erreichbar.
/// Grenze: lädt nicht selbst und hält keinen Zustand — Daten und Aktionen
/// kommen aus `ChatViewModel` (§9.3). Die Titel-/Vorschau-Regel ist reine
/// Darstellung und steht deshalb hier, nicht im Modell.
struct SessionListView: View {

    @Environment(\.dismiss) private var dismiss

    let sessions: [SessionSummary]
    let isLoading: Bool
    /// Befund 14: solange keine **leere** Seite kam, bleibt „Mehr laden“ sichtbar.
    let loadedAll: Bool
    /// Während eines Turns ist die Auswahl gesperrt (kein Kontextwechsel).
    let isStreaming: Bool
    /// Die aktuell geöffnete Unterhaltung, falls es eine gibt.
    let selectedSessionID: String?
    /// Fehlertext des letzten Ladens; `nil` heißt: kein Fehler.
    let errorText: String?

    let onSelect: (SessionSummary) -> Void
    let onNewChat: () -> Void
    let onLoadMore: () -> Void
    let onRetry: () -> Void

    /// §4.1: Vorschau auf `maxPreviewCharacters` Zeichen, eine Zeile.
    /// Der Wert kommt aus der Chat-Konfiguration — kein zweites Literal.
    private static var previewLimit: Int {
        HermesChatConfiguration().maxPreviewCharacters
    }

    var body: some View {
        NavigationStack {
            Group {
                if isLoading && sessions.isEmpty {
                    ProgressView("Lade Verlauf …")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if sessions.isEmpty {
                    emptyState
                } else {
                    sessionList
                }
            }
            .background(DesignTokens.Palette.groupedBackground)
            .navigationTitle("Verlauf")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Fertig") { dismiss() }
                        .accessibilityLabel("Verlauf schließen")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Neue Unterhaltung", systemImage: "square.and.pencil") {
                        onNewChat()
                    }
                    .disabled(isStreaming)
                    .accessibilityLabel("Neue Unterhaltung")
                }
            }
        }
    }

    // MARK: Liste

    private var sessionList: some View {
        List {
            ForEach(sessions) { session in
                Button {
                    onSelect(session)
                } label: {
                    row(for: session)
                }
                .buttonStyle(.plain)
                .disabled(isStreaming)
                .accessibilityIdentifier("session-\(session.id)")
            }

            if !loadedAll {
                Button {
                    onLoadMore()
                } label: {
                    HStack {
                        Spacer()
                        Text("Mehr laden")
                        Spacer()
                    }
                }
                .disabled(isLoading)
                .accessibilityLabel("Weitere Unterhaltungen laden")
            } else {
                Text("Keine weiteren Unterhaltungen.")
                    .font(DesignTokens.Typography.footnote)
                    .foregroundStyle(DesignTokens.Palette.secondaryLabel)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .listRowBackground(Color.clear)
            }
        }
        .listStyle(.plain)
        .refreshable { onRetry() }
    }

    private func row(for session: SessionSummary) -> some View {
        HStack(alignment: .top, spacing: DesignTokens.Spacing.m) {
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
                Text(Self.displayTitle(for: session))
                    .font(DesignTokens.Typography.headline)
                    .foregroundStyle(DesignTokens.Palette.label)
                    .lineLimit(1)

                if let preview = preview(of: session) {
                    Text(preview)
                        .font(DesignTokens.Typography.footnote)
                        .foregroundStyle(DesignTokens.Palette.secondaryLabel)
                        .lineLimit(1)
                }

                if let date = session.lastActiveDate {
                    Text(Self.relativeText(for: date))
                        .font(DesignTokens.Typography.footnote)
                        .foregroundStyle(DesignTokens.Palette.secondaryLabel)
                }
            }

            Spacer(minLength: DesignTokens.Spacing.s)

            Text("\(session.messageCount)")
                .font(DesignTokens.Typography.footnote)
                .foregroundStyle(DesignTokens.Palette.secondaryLabel)
                .accessibilityLabel(Text("\(session.messageCount) Nachrichten"))
        }
        .padding(.vertical, DesignTokens.Spacing.xs)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(Self.accessibilityText(for: session)))
        .accessibilityAddTraits(
            session.id == selectedSessionID ? [.isSelected] : []
        )
    }

    // MARK: Zustände

    private var emptyState: some View {
        VStack(spacing: DesignTokens.Spacing.s) {
            if let errorText {
                Image(systemName: "wifi.slash")
                    .font(.largeTitle)
                    .foregroundStyle(DesignTokens.Palette.secondaryLabel)

                Text(errorText)
                    .font(DesignTokens.Typography.callout)
                    .foregroundStyle(DesignTokens.Palette.label)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)

                Button("Erneut laden", action: onRetry)
                    .buttonStyle(.bordered)
            } else {
                Image(systemName: "clock.arrow.circlepath")
                    .font(.largeTitle)
                    .foregroundStyle(DesignTokens.Palette.secondaryLabel)

                Text("Noch keine Unterhaltungen")
                    .font(DesignTokens.Typography.headline)

                Button("Neue Unterhaltung starten", action: onNewChat)
                    .buttonStyle(.bordered)
                    .disabled(isStreaming)
            }
        }
        .padding(DesignTokens.Spacing.l)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Darstellung (§4.1)

    /// Titel-Regel: `title`, sonst gekürzte `preview`, sonst „Neue Unterhaltung“.
    /// Leere Strings zählen nicht als vorhanden.
    static func displayTitle(for session: SessionSummary) -> String {
        if let title = session.title, !title.isEmpty {
            return title
        }
        if let preview = session.preview, !preview.isEmpty {
            return String(preview.prefix(previewLimit))
        }
        return "Neue Unterhaltung"
    }

    private func preview(of session: SessionSummary) -> String? {
        guard let preview = session.preview, !preview.isEmpty else { return nil }
        return String(preview.prefix(Self.previewLimit))
    }

    private static func relativeText(for date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter.localizedString(for: date, relativeTo: Date())
    }

    private static func accessibilityText(for session: SessionSummary) -> String {
        var parts = [displayTitle(for: session)]
        if let date = session.lastActiveDate {
            parts.append(relativeText(for: date))
        }
        parts.append("\(session.messageCount) Nachrichten")
        return parts.joined(separator: ", ")
    }
}

#Preview("SessionListView") {
    SessionListView(
        sessions: [
            SessionSummary(
                id: "20261021_101500_aaaa",
                title: "Einkaufsliste für Samstag",
                preview: "Ich habe die Zutaten für das Abendessen zusammengestellt.",
                messageCount: 12,
                toolCallCount: 3,
                lastActive: Date().timeIntervalSince1970 - 300,
                pinned: false,
                archived: false,
                source: "desktop"
            ),
            SessionSummary(
                id: "20261020_182737_bbbb",
                title: nil,
                preview: "Wochenplan und offene Aufgaben bitte.",
                messageCount: 4,
                toolCallCount: 1,
                lastActive: Date().timeIntervalSince1970 - 86_400,
                pinned: false,
                archived: false,
                source: "desktop"
            )
        ],
        isLoading: false,
        loadedAll: false,
        isStreaming: false,
        selectedSessionID: nil,
        errorText: nil,
        onSelect: { _ in },
        onNewChat: {},
        onLoadMore: {},
        onRetry: {}
    )
}
