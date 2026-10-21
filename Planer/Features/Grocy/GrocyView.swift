//
//  GrocyView.swift
//  Planer
//
//  Einkaufs-Tab: Einkaufsliste, Vorrat, Mengen/Einheiten und
//  Katalog-Autovervollständigung (spec-ios §2.3, §3.2, §10).
//

import Foundation
import SwiftData
import SwiftUI

/// Wurzel-View von Tab 3.
///
/// Zweck: baut das ViewModel mit dem SwiftData-Kontext aus I2 und zeigt
/// Einkaufsliste bzw. Vorrat.
/// Grenze: keine Schreibpfade außer „Produkt hinzufügen“ (§2.3).
struct GrocyView: View {

    @Environment(\.modelContext) private var modelContext
    @State private var model: GrocyViewModel?

    var body: some View {
        NavigationStack {
            Group {
                if let model {
                    GrocyContentView(model: model)
                } else {
                    ProgressView()
                }
            }
            .navigationTitle("Einkauf")
            .background(DesignTokens.Palette.groupedBackground)
        }
        .task {
            await prepare()
        }
    }

    /// Baut das ViewModel mit dem Kontext aus I2 und lädt den ersten Stand.
    /// Explizit `@MainActor`, weil die Repository- und ViewModel-Typen
    /// main-actor-isoliert sind.
    @MainActor
    private func prepare() async {
        let model = self.model ?? GrocyViewModel(
            repository: GrocyRepositoryProvider.shared(context: modelContext)
        )
        self.model = model
        await model.load()
    }
}

/// Die zwei Sichten des Tabs: Einkaufsliste und Vorrat.
enum GrocyArea: String, CaseIterable, Identifiable {
    case shopping
    case stock

    var id: String { rawValue }

    var title: String {
        switch self {
        case .shopping:
            return "Einkauf"
        case .stock:
            return "Vorrat"
        }
    }

    var emptyText: String {
        switch self {
        case .shopping:
            return "Die Einkaufsliste ist leer."
        case .stock:
            return "Kein Bestand im Vorrat."
        }
    }
}

private struct GrocyContentView: View {

    @ObservedObject var model: GrocyViewModel
    @State private var area: GrocyArea = .shopping

    private var rows: [GrocyRow] {
        area == .shopping ? model.shopping : model.stock
    }

    var body: some View {
        List {
            if let banner = model.banner {
                Section {
                    bannerRow(banner)
                }
            }

            Section("Hinzufügen") {
                HStack(spacing: DesignTokens.Spacing.s) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(DesignTokens.Palette.secondaryLabel)
                    TextField("Produkt suchen", text: $model.query)
                        .textInputAutocapitalization(.words)
                        .autocorrectionDisabled()
                }
                HStack {
                    Text("Menge")
                        .foregroundStyle(DesignTokens.Palette.secondaryLabel)
                    Spacer()
                    TextField("1", text: $model.amountText)
                        .keyboardType(.decimalPad)
                        .multilineTextAlignment(.trailing)
                        .frame(maxWidth: 120)
                }
                ForEach(model.suggestions) { product in
                    Button {
                        Task { await model.add(product) }
                    } label: {
                        Label(product.name, systemImage: "plus.circle")
                    }
                }
            }

            Section(area.title) {
                if model.isLoading && rows.isEmpty {
                    ProgressView()
                } else if rows.isEmpty {
                    Text(area.emptyText)
                        .font(DesignTokens.Typography.footnote)
                        .foregroundStyle(DesignTokens.Palette.secondaryLabel)
                } else {
                    ForEach(rows) { row in
                        rowView(row)
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .scrollDismissesKeyboard(.interactively)
        .safeAreaInset(edge: .top, spacing: 0) {
            areaPicker
        }
        .refreshable {
            await model.load()
        }
        .toolbar {
            if model.pendingCount > 0 {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Übertragen") {
                        Task { await model.retryPending() }
                    }
                }
            }
        }
    }

    private var areaPicker: some View {
        Picker("Bereich", selection: $area) {
            ForEach(GrocyArea.allCases) { value in
                Text(value.title).tag(value)
            }
        }
        .pickerStyle(.segmented)
        .padding(.horizontal, DesignTokens.Spacing.l)
        .padding(.vertical, DesignTokens.Spacing.s)
        .background(DesignTokens.Palette.groupedBackground)
    }

    private func rowView(_ row: GrocyRow) -> some View {
        UnifiedListItemView(
            row.name,
            subtitle: subtitle(for: row),
            systemImage: row.isExpired ? "exclamationmark.triangle" : "cart"
        ) {
            HStack(spacing: DesignTokens.Spacing.s) {
                Text(amountLabel(for: row))
                    .font(DesignTokens.Typography.callout)
                    .foregroundStyle(DesignTokens.Palette.secondaryLabel)
                if row.isPending {
                    Text("wartet")
                        .font(DesignTokens.Typography.footnote)
                        .foregroundStyle(DesignTokens.Palette.secondaryLabel)
                }
                if row.isDone {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(DesignTokens.Palette.success)
                }
            }
        }
    }

    private func bannerRow(_ text: String) -> some View {
        HStack(alignment: .top, spacing: DesignTokens.Spacing.s) {
            Image(systemName: "exclamationmark.triangle.fill")
            Text(text)
                .font(DesignTokens.Typography.footnote)
            Spacer(minLength: 0)
        }
        .foregroundStyle(DesignTokens.Palette.danger)
    }

    private func subtitle(for row: GrocyRow) -> String? {
        switch area {
        case .stock:
            guard let date = row.bestBeforeDate else {
                return row.isExpired ? "abgelaufen" : nil
            }
            let day = date.formatted(date: .abbreviated, time: .omitted)
            return row.isExpired ? "abgelaufen seit \(day)" : "MHD \(day)"
        case .shopping:
            guard let note = row.note, !note.isEmpty, note != row.name else {
                return nil
            }
            return note
        }
    }

    private func amountLabel(for row: GrocyRow) -> String {
        let number = row.amount.formatted(
            .number.precision(.fractionLength(0...2))
        )
        return row.unit.isEmpty ? number : "\(number) \(row.unit)"
    }
}

#Preview("GrocyView") {
    GrocyView()
        .modelContainer(for: GroceryItem.self, inMemory: true)
}
