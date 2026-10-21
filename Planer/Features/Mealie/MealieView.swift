//
//  MealieView.swift
//  Planer
//
//  Rezepte-Tab: Mealie-Wochenplan, durchsuchbare Rezept-Bibliothek und
//  „Zutaten auf Einkaufsliste“ (spec-ios §2.4, §3.3, §10).
//

import Foundation
import SwiftData
import SwiftUI

/// Wurzel-View von Tab 4.
///
/// Zweck: baut das ViewModel mit dem SwiftData-Kontext aus I2 und zeigt
/// Wochenplan bzw. Bibliothek.
/// Grenze: kein Schreibpfad nach Mealie; der einzige Schreibpfad des Tabs geht
/// über `GrocyRepository` auf die Grocy-Einkaufsliste (AD-8).
struct MealieView: View {

    @Environment(\.modelContext) private var modelContext
    @State private var model: MealieViewModel?

    var body: some View {
        NavigationStack {
            Group {
                if let model {
                    MealieContentView(model: model)
                } else {
                    ProgressView()
                }
            }
            .navigationTitle("Rezepte")
            .background(DesignTokens.Palette.groupedBackground)
        }
        .task {
            await prepare()
        }
    }

    /// Baut das ViewModel mit dem Kontext aus I2 und lädt den ersten Stand.
    /// Der Aufruf hängt an `.task` der Wurzel und läuft deshalb bei jeder
    /// Rückkehr in den Tab erneut: eine in den Einstellungen hinterlegte oder
    /// korrigierte Mealie-Basis-URL wird damit ohne App-Neustart wirksam
    /// (MARAAA-140/M1).
    /// Die Grocy-Ablage kommt aus `GrocyRepositoryProvider.shared(context:)` —
    /// diese Instanz hält die app-weit geteilte Pending-Queue, die der
    /// Einkaufs-Tab beim Öffnen liest und replays; der Rezepte-Tab legt keine
    /// eigene an (G2-Befund 1).
    /// Explizit `@MainActor`, weil Repository- und ViewModel-Typen
    /// main-actor-isoliert sind.
    @MainActor
    private func prepare() async {
        let model = self.model ?? MealieViewModel(
            repository: MealieRepository(context: modelContext),
            grocy: GrocyRepositoryProvider.shared(context: modelContext)
        )
        self.model = model
        await model.load()
    }
}

/// Die zwei Sichten des Tabs: Wochenplan und Rezept-Bibliothek.
enum MealieArea: String, CaseIterable, Identifiable {
    case week
    case library

    var id: String { rawValue }

    var title: String {
        switch self {
        case .week:
            return "Wochenplan"
        case .library:
            return "Bibliothek"
        }
    }

    var emptyText: String {
        switch self {
        case .week:
            return "Für diese Woche sind keine Mahlzeiten geplant."
        case .library:
            return "Keine Rezepte gefunden."
        }
    }
}

private struct MealieContentView: View {

    @ObservedObject var model: MealieViewModel
    @State private var area: MealieArea = .week

    var body: some View {
        List {
            if let banner = model.banner {
                Section {
                    bannerRow(banner)
                }
            }

            switch area {
            case .week:
                weekSections
            case .library:
                librarySection
            }
        }
        .listStyle(.insetGrouped)
        .scrollDismissesKeyboard(.interactively)
        .safeAreaInset(edge: .top, spacing: 0) {
            areaPicker
        }
        .searchable(text: $model.query, prompt: "Rezept suchen")
        .onChange(of: model.query) { _, newValue in
            model.queryChanged()
            if !newValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                area = .library
            }
        }
        .refreshable {
            await model.load()
        }
        .toolbar {
            if model.isAddingIngredients {
                ToolbarItem(placement: .topBarTrailing) {
                    ProgressView()
                }
            }
        }
    }

    // MARK: - Wochenplan

    @ViewBuilder
    private var weekSections: some View {
        if model.isLoading && model.week.isEmpty {
            Section {
                ProgressView()
            }
        } else if model.week.isEmpty {
            Section {
                emptyRow(MealieArea.week.emptyText)
            }
        } else {
            ForEach(model.weekGroups) { group in
                Section(dayTitle(group)) {
                    ForEach(group.items) { item in
                        planRow(item)
                    }
                }
            }
        }
    }

    private func planRow(_ item: MealieMealPlanItem) -> some View {
        UnifiedListItemView(
            item.recipeName,
            subtitle: MealieMealType.label(item.mealType),
            systemImage: item.isTextEntry ? "text.alignleft" : "fork.knife"
        ) {
            // Freitext-Zeilen (z. B. „Reste“) haben kein Rezept und damit auch
            // keine Zutaten-Aktion; ohne `recipeID` gibt es nichts nachzuladen.
            if item.isTextEntry {
                Text("Freitext")
                    .font(DesignTokens.Typography.footnote)
                    .foregroundStyle(DesignTokens.Palette.secondaryLabel)
            } else {
                Text(scaleLabel(item.recipeScale))
                    .font(DesignTokens.Typography.footnote)
                    .foregroundStyle(DesignTokens.Palette.secondaryLabel)
            }
        }
    }

    private func dayTitle(_ group: MealiePlanDay) -> String {
        guard let day = group.day else { return group.dateText }
        return day.formatted(.dateTime.weekday(.wide).day().month(.abbreviated))
    }

    private func scaleLabel(_ scale: Double) -> String {
        let number = scale.formatted(.number.precision(.fractionLength(0...2)))
        return "×\(number)"
    }

    // MARK: - Bibliothek

    @ViewBuilder
    private var librarySection: some View {
        if model.recipes.isEmpty {
            Section {
                if model.isLoading {
                    ProgressView()
                } else {
                    emptyRow(MealieArea.library.emptyText)
                }
            }
        } else {
            Section("Rezepte") {
                ForEach(model.recipes) { row in
                    recipeRow(row)
                }
                if model.isLoadingMore {
                    ProgressView()
                }
            }
        }
    }

    /// Rezeptzeile mit Bild, Zeit und Zutaten-Button.
    ///
    /// Eigene Zeile statt `UnifiedListItemView`: die Komponente aus I1 kennt
    /// kein Bildfeld, und `Planer/DesignSystem/**` liegt außerhalb des
    /// Umfangs von I6. Farben, Abstände und Radien kommen aus den Tokens.
    private func recipeRow(_ row: MealieRecipeRow) -> some View {
        HStack(spacing: DesignTokens.Spacing.m) {
            thumbnail(row)

            VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
                Text(row.name)
                    .font(DesignTokens.Typography.headline)
                    .foregroundStyle(DesignTokens.Palette.label)

                if let subtitle = recipeSubtitle(row) {
                    Text(subtitle)
                        .font(DesignTokens.Typography.footnote)
                        .foregroundStyle(DesignTokens.Palette.secondaryLabel)
                }
            }

            Spacer(minLength: DesignTokens.Spacing.s)

            Button {
                Task { await model.addIngredients(of: row) }
            } label: {
                Image(systemName: "cart.badge.plus")
                    .font(DesignTokens.Typography.callout)
            }
            .buttonStyle(.borderless)
            .disabled(model.isAddingIngredients || row.slug == nil)
            .accessibilityLabel("Zutaten auf Einkaufsliste setzen")
        }
        .padding(DesignTokens.Spacing.m)
        .background(
            DesignTokens.Palette.secondaryBackground,
            in: RoundedRectangle(cornerRadius: DesignTokens.Radius.card, style: .continuous)
        )
        .onAppear {
            model.loadMoreIfNeeded(current: row)
        }
    }

    /// Rezeptbild über den authentifizierten Loader; Platzhalter nur, wenn die
    /// Mealie-Antwort keine Rezept-ID für die Bild-Route hatte. Maßgeblich ist
    /// die Rezept-ID (`row.imageID`), **nicht** die beim Laden gebildete
    /// Adresse: die Basis-URL wird erst beim Zugriff aufgelöst, sodass eine
    /// nachträglich hinterlegte oder korrigierte Basis ohne App-Neustart
    /// greift (MARAAA-140/M1). Ein direkter `URLSession`-Aufruf lädt ohne
    /// CF-/Bearer-Header und ist deshalb tabu.
    @ViewBuilder
    private func thumbnail(_ row: MealieRecipeRow) -> some View {
        if let imageID = row.imageID {
            MealieImageView(
                recipeID: imageID,
                repository: model.imageRepository,
                imageURL: row.imageURL
            )
        } else {
            placeholderImage
                .frame(width: 48, height: 48)
                .background(DesignTokens.Palette.tertiaryBackground)
                .clipShape(
                    RoundedRectangle(cornerRadius: DesignTokens.Radius.card, style: .continuous)
                )
                .accessibilityHidden(true)
        }
    }

    private var placeholderImage: some View {
        Image(systemName: "fork.knife")
            .foregroundStyle(DesignTokens.Palette.secondaryLabel)
    }

    private func recipeSubtitle(_ row: MealieRecipeRow) -> String? {
        var parts: [String] = []
        if let totalTime = row.totalTime {
            parts.append(totalTime)
        }
        if row.servings > 0 {
            let count = row.servings.formatted(.number.precision(.fractionLength(0...1)))
            parts.append("\(count) Portionen")
        }
        if row.slug == nil {
            parts.append("offline")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    // MARK: - Gemeinsame Bausteine

    private var areaPicker: some View {
        Picker("Bereich", selection: $area) {
            ForEach(MealieArea.allCases) { value in
                Text(value.title).tag(value)
            }
        }
        .pickerStyle(.segmented)
        .padding(.horizontal, DesignTokens.Spacing.l)
        .padding(.vertical, DesignTokens.Spacing.s)
        .background(DesignTokens.Palette.groupedBackground)
    }

    private func emptyRow(_ text: String) -> some View {
        Text(text)
            .font(DesignTokens.Typography.footnote)
            .foregroundStyle(DesignTokens.Palette.secondaryLabel)
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
}

#Preview("MealieView") {
    MealieView()
        .modelContainer(for: Recipe.self, inMemory: true)
}
