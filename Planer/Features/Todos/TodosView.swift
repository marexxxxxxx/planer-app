//
//  TodosView.swift
//  Planer
//
//  To-Dos-Tab gegen `worldplaner` `/api/tasks` (WP I4, spec-ios §2.2).
//

import SwiftData
import SwiftUI

/// Root-View von Tab 2.
///
/// Zweck: die To-Do-Liste mit den drei Segmenten `Alle|Heute|Erledigt`
/// (spec-ios §1/I4), Abhaken, Swipe-Löschen, Anlegen und sichtbarem
/// Offline-/Konflikt-Zustand.
/// Grenze: keine eigene Netzwerk- oder Cache-Logik; die liegt in
/// `TodosViewModel` und `TodoRepository`.
struct TodosView: View {

    @Environment(\.modelContext) private var modelContext
    @StateObject private var viewModel = TodosViewModel()
    @State private var isPresentingEditor = false

    /// Bindet den Konflikt-Alert an `viewModel.conflict`.
    ///
    /// Der Setter räumt den Zustand auf: SwiftUI setzt `isPresented` beim
    /// Antippen einer Aktion auf `false`, bevor die Aktion läuft. Die Aktionen
    /// bekommen den Konflikt deshalb als Parameter. Ohne dieses Aufräumen
    /// bliebe `conflict` gesetzt und derselbe Alert könnte nach einer
    /// fehlgeschlagenen Auflösung erneut erscheinen.
    private var conflictBinding: Binding<Bool> {
        Binding(
            get: { viewModel.conflict != nil },
            set: { isPresented in
                if !isPresented {
                    viewModel.dismissConflict()
                }
            }
        )
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: DesignTokens.Spacing.s) {
                filterPicker

                if let banner = viewModel.banner {
                    bannerView(banner)
                }

                if viewModel.isUsingCache || viewModel.pendingCount > 0 {
                    syncStateView
                }

                list
            }
            .background(DesignTokens.Palette.groupedBackground)
            .navigationTitle("To-Dos")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        isPresentingEditor = true
                    } label: {
                        Label("Neues To-Do", systemImage: "plus")
                    }
                }
            }
            .task { @MainActor in
                await viewModel.start(context: modelContext)
            }
            .sheet(isPresented: $isPresentingEditor) {
                TodoEditorSheet(viewModel: viewModel)
            }
            .alert(
                "Versionskonflikt",
                isPresented: conflictBinding,
                presenting: viewModel.conflict
            ) { conflict in
                Button("Server behalten") {
                    Task { await viewModel.resolveConflictKeepingServer(conflict) }
                }
                Button("Lokal behalten") {
                    Task { await viewModel.resolveConflictKeepingLocal(conflict) }
                }
                Button("Später", role: .cancel) {
                    viewModel.dismissConflict()
                }
            } message: { conflict in
                Text(conflict.message)
            }
        }
    }

    // MARK: - Kopf

    private var filterPicker: some View {
        Picker(
            "Statusfilter",
            selection: Binding(
                get: { viewModel.filter },
                set: { newValue in
                    Task { await viewModel.setFilter(newValue) }
                }
            )
        ) {
            ForEach(TodoStatusFilter.allCases) { filter in
                Text(filter.title).tag(filter)
            }
        }
        .pickerStyle(.segmented)
        .padding(.horizontal, DesignTokens.Spacing.l)
        .padding(.top, DesignTokens.Spacing.s)
        .accessibilityLabel("Statusfilter")
    }

    private func bannerView(_ message: String) -> some View {
        HStack(alignment: .top, spacing: DesignTokens.Spacing.s) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(DesignTokens.Palette.secondaryLabel)
                .accessibilityHidden(true)

            Text(message)
                .font(DesignTokens.Typography.footnote)
                .foregroundStyle(DesignTokens.Palette.label)
                .frame(maxWidth: .infinity, alignment: .leading)

            Button {
                viewModel.dismissBanner()
            } label: {
                Image(systemName: "xmark")
                    .font(DesignTokens.Typography.footnote)
                    .foregroundStyle(DesignTokens.Palette.secondaryLabel)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Hinweis schließen")
        }
        .padding(DesignTokens.Spacing.m)
        .background(
            DesignTokens.Palette.tertiaryBackground,
            in: RoundedRectangle(cornerRadius: DesignTokens.Radius.card, style: .continuous)
        )
        .padding(.horizontal, DesignTokens.Spacing.l)
    }

    private var syncStateView: some View {
        HStack(spacing: DesignTokens.Spacing.xs) {
            Image(systemName: viewModel.isUsingCache ? "wifi.slash" : "arrow.triangle.2.circlepath")
                .accessibilityHidden(true)

            Text(syncStateText)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(DesignTokens.Typography.footnote)
        .foregroundStyle(DesignTokens.Palette.secondaryLabel)
        .padding(.horizontal, DesignTokens.Spacing.l)
    }

    private var syncStateText: String {
        if viewModel.pendingCount > 0 {
            return "\(viewModel.pendingCount) Änderung(en) warten auf Übertragung"
        }
        return "Offline-Stand aus dem Cache"
    }

    // MARK: - Liste

    private var list: some View {
        List {
            ForEach(viewModel.tasks) { task in
                row(task)
                    .listRowInsets(
                        EdgeInsets(
                            top: DesignTokens.Spacing.xs,
                            leading: DesignTokens.Spacing.l,
                            bottom: DesignTokens.Spacing.xs,
                            trailing: DesignTokens.Spacing.l
                        )
                    )
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
                    .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                        Button(role: .destructive) {
                            Task { await viewModel.delete(task) }
                        } label: {
                            Label("Löschen", systemImage: "trash")
                        }
                    }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .refreshable { @MainActor in
            await viewModel.refresh()
        }
        .overlay {
            emptyState
        }
    }

    private func row(_ task: TodoDTO) -> some View {
        UnifiedListItemView(
            task.title,
            subtitle: task.subtitle,
            systemImage: task.isDone ? "checkmark.circle.fill" : "circle"
        ) {
            Button {
                Task { await viewModel.toggle(task) }
            } label: {
                Image(systemName: task.isDone ? "arrow.uturn.backward" : "checkmark")
                    .font(DesignTokens.Typography.callout.weight(.semibold))
                    .foregroundStyle(
                        task.isDone
                            ? DesignTokens.Palette.secondaryLabel
                            : DesignTokens.Palette.success
                    )
                    .frame(width: 32, height: 32)
                    .background(
                        Circle().strokeBorder(
                            task.isDone
                                ? DesignTokens.Palette.secondaryLabel
                                : DesignTokens.Palette.success,
                            lineWidth: 1
                        )
                    )
            }
            .buttonStyle(.plain)
            .accessibilityLabel(task.isDone ? "Als offen markieren" : "Als erledigt markieren")
        }
        .opacity(task.isDone ? 0.65 : 1)
        .accessibilityAction(
            named: Text(task.isDone ? "Als offen markieren" : "Als erledigt markieren")
        ) {
            Task { await viewModel.toggle(task) }
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        if viewModel.isLoading && viewModel.tasks.isEmpty {
            ProgressView("Lade To-Dos …")
        } else if viewModel.tasks.isEmpty {
            ContentUnavailableView {
                Label(emptyTitle, systemImage: "checklist")
            } description: {
                Text(emptyMessage)
            }
        }
    }

    private var emptyTitle: String {
        switch viewModel.filter {
        case .all:
            return "Keine To-Dos"
        case .today:
            return "Heute nichts fällig"
        case .done:
            return "Nichts erledigt"
        }
    }

    private var emptyMessage: String {
        switch viewModel.filter {
        case .all:
            return "Neue Einträge legst du über das Plus an."
        case .today:
            return "Für heute ist kein offenes To-Do fällig. "
                + "Überfällige und undatierte Einträge stehen unter „Alle“."
        case .done:
            return "Erledigte Einträge erscheinen hier."
        }
    }
}

#Preview("TodosView") {
    TodosView()
        .modelContainer(for: TodoItem.self, inMemory: true)
}
