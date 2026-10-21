//
//  MealieViewModel.swift
//  Planer
//
//  Zustand des Rezepte-Tabs (spec-ios §2.4, §3.3, §10).
//

import Combine
import Foundation

/// Ein Tag des Wochenplans mit seinen Mahlzeiten.
struct MealiePlanDay: Identifiable, Equatable {
    let dateText: String
    let day: Date?
    let items: [MealieMealPlanItem]

    var id: String { dateText }
}

/// Ergebnis des Schreibens von Zutaten nach Grocy.
struct MealieTransferResult: Equatable {
    let added: Int
    let queued: Int
    let failed: Int
    let unmatched: [String]

    /// Banner-Text nach dem Schreiben; `nil`, wenn nichts zu berichten ist.
    func message(recipeName: String) -> String? {
        var parts: [String] = []
        if added > 0 {
            parts.append("\(added) Zutat(en) aus „\(recipeName)“ auf die Grocy-Einkaufsliste gesetzt")
        }
        if queued > 0 {
            parts.append("\(queued) offline vorgemerkt — der Einkaufs-Tab versucht die Übertragung beim nächsten Öffnen")
        }
        if failed > 0 {
            parts.append("\(failed) Zutat(en) konnte Grocy nicht annehmen")
        }
        if !unmatched.isEmpty {
            let names = unmatched.prefix(4).joined(separator: ", ")
            let suffix = unmatched.count > 4 ? " …" : ""
            parts.append("nicht im Grocy-Katalog: \(names)\(suffix)")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

/// Lädt Wochenplan und Bibliothek, sucht in der Bibliothek und schreibt
/// Zutaten nach Grocy.
///
/// Zweck: Cache-Regel aus §3.3 (Server zuerst, bei Fehler letzter Cache) und
/// der Grocy-Schreibpfad aus AD-8/§2.3.
/// Grenze: keine Schreibzugriffe auf Mealie; die Grocy-Pending-Queue (I5) liegt
/// persistent im Cache, ist app-weit geteilt und wird beim Öffnen des
/// Einkaufs-Tabs übertragen.
@MainActor
final class MealieViewModel: ObservableObject {

    @Published private(set) var week: [MealieMealPlanItem] = []
    @Published private(set) var recipes: [MealieRecipeRow] = []
    @Published private(set) var banner: String?
    @Published private(set) var isLoading = false
    @Published private(set) var isLoadingMore = false
    @Published private(set) var isAddingIngredients = false
    @Published private(set) var hasMoreRecipes = false
    @Published var query = ""

    private let repository: MealieRepository
    private let grocy: GrocyRepository
    private let perPage: Int
    private var nextPage = 1
    private var searchTask: Task<Void, Never>?

    /// Repository für den authentifizierten Bild-Loader der Ansicht.
    var imageRepository: MealieRepository { repository }

    init(repository: MealieRepository, grocy: GrocyRepository, perPage: Int = 50) {
        self.repository = repository
        self.grocy = grocy
        self.perPage = perPage
    }

    /// Wochenplan nach Tag gruppiert, Tage und Mahlzeiten sortiert.
    var weekGroups: [MealiePlanDay] {
        let grouped = Dictionary(grouping: week, by: \.date)
        return grouped.keys.sorted().map { dateText in
            let items = (grouped[dateText] ?? []).sorted { $0.sortIndex < $1.sortIndex }
            return MealiePlanDay(
                dateText: dateText,
                day: MealieDay.date(from: dateText),
                items: items
            )
        }
    }

    /// Lädt Wochenplan und Bibliothek; bei Netzfehlern bleibt der letzte Cache.
    func load() async {
        isLoading = true
        banner = nil
        defer { isLoading = false }
        await reloadPlan()
        await reloadLibrary(cacheResults: MealieText.trimmed(query).isEmpty)
    }

    /// Debounce der Suche: jede neue Eingabe bricht den vorigen Lauf ab.
    ///
    /// Der `catch` behandelt ausschließlich die erwartete Abbruch-Wegwerfung
    /// von `Task.sleep`; andere Fehler kann der Aufruf nicht werfen.
    func queryChanged() {
        searchTask?.cancel()
        searchTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: 300_000_000)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            await self?.reloadLibrary(cacheResults: false)
        }
    }

    /// Lädt die nächste Seite, wenn die letzte Zeile sichtbar wird.
    func loadMoreIfNeeded(current row: MealieRecipeRow) {
        guard row.id == recipes.last?.id, hasMoreRecipes, !isLoadingMore else { return }
        Task { await loadMore() }
    }

    /// „Zutaten auf Einkaufsliste“ — schreibt nach **Grocy**, nie nach Mealie.
    ///
    /// Zutaten ohne Produkt im Grocy-Katalog werden gemeldet, nicht erfunden;
    /// bei Offline/Timeout wandern sie in die Pending-Queue von I5.
    func addIngredients(of recipe: MealieRecipeRow) async {
        guard let slug = recipe.slug else {
            banner = "Zutaten lassen sich nur für online geladene Rezepte übernehmen."
            return
        }
        guard !isAddingIngredients else { return }
        isAddingIngredients = true
        defer { isAddingIngredients = false }

        let ingredients: [MealieIngredient]
        do {
            ingredients = try await repository.fetchIngredients(slug: slug)
        } catch {
            banner = "Zutaten von „\(recipe.name)“ nicht ladbar. \(detail(error))"
            return
        }
        guard !ingredients.isEmpty else {
            banner = "„\(recipe.name)“ hat keine Zutaten."
            return
        }

        let catalog: [GrocyProduct]
        do {
            catalog = try await grocy.fetchCatalog()
        } catch {
            banner = "Grocy-Katalog nicht ladbar. \(detail(error))"
            return
        }

        let result = await transfer(ingredients, to: catalog)
        banner = result.message(recipeName: recipe.name)
    }

    // MARK: - Netz

    private func reloadPlan() async {
        do {
            let items = try await repository.fetchWeek(containing: Date())
            week = items
            do {
                try repository.cachePlan(items)
            } catch {
                banner = "Wochenplan konnte nicht gespeichert werden: \(detail(error))"
            }
        } catch let loadError {
            do {
                let cached = try repository.cachedPlan()
                week = cached
                banner = cached.isEmpty
                    ? "Mealie nicht erreichbar. \(detail(loadError))"
                    : "Mealie nicht erreichbar — letzter Wochenplan wird angezeigt. \(detail(loadError))"
            } catch {
                week = []
                banner = "Mealie nicht erreichbar. \(detail(loadError))"
            }
        }
    }

    private func reloadLibrary(cacheResults: Bool) async {
        do {
            let result = try await repository.searchRecipes(query: query, page: 1, perPage: perPage)
            let imageBaseURL = repository.resolveImageBaseURL()
            let rows = result.items.compactMap { repository.row(from: $0, imageBaseURL: imageBaseURL) }
            recipes = rows
            nextPage = result.pagination.page + 1
            hasMoreRecipes = result.pagination.page < result.pagination.totalPages
            if cacheResults {
                do {
                    try repository.cacheLibrary(rows)
                } catch {
                    banner = "Bibliothek konnte nicht gespeichert werden: \(detail(error))"
                }
            }
        } catch let loadError {
            do {
                let cached = try repository.cachedLibrary()
                recipes = cached
                hasMoreRecipes = false
                banner = cached.isEmpty
                    ? "Mealie nicht erreichbar. \(detail(loadError))"
                    : "Mealie nicht erreichbar — letzte Bibliothek wird angezeigt. \(detail(loadError))"
            } catch {
                recipes = []
                hasMoreRecipes = false
                banner = "Mealie nicht erreichbar. \(detail(loadError))"
            }
        }
    }

    private func loadMore() async {
        guard hasMoreRecipes, !isLoadingMore else { return }
        isLoadingMore = true
        defer { isLoadingMore = false }
        do {
            let result = try await repository.searchRecipes(query: query, page: nextPage, perPage: perPage)
            let imageBaseURL = repository.resolveImageBaseURL()
            let rows = result.items.compactMap { repository.row(from: $0, imageBaseURL: imageBaseURL) }
            recipes.append(contentsOf: rows.filter { row in !recipes.contains { $0.id == row.id } })
            nextPage = result.pagination.page + 1
            hasMoreRecipes = result.pagination.page < result.pagination.totalPages
        } catch {
            hasMoreRecipes = false
            banner = "Weitere Rezepte nicht ladbar. \(detail(error))"
        }
    }

    // MARK: - Grocy-Schreibpfad

    /// Setzt die Zutaten nacheinander auf die Grocy-Einkaufsliste.
    ///
    /// `product_amount` ist bewusst `1`, nicht Mealies Menge: `GrocyRepository`
    /// (I5) übergibt kein `qu_id`, und ohne Grocys Bestands-Einheit wäre z. B.
    /// „200 g“ als 200 Stück falsch. Die vollständige Zutatenzeile steht im
    /// `note`, sodass Menge und Einheit auf der Liste erhalten bleiben.
    private func transfer(
        _ ingredients: [MealieIngredient],
        to catalog: [GrocyProduct]
    ) async -> MealieTransferResult {
        var added = 0
        var queued = 0
        var failed = 0
        var unmatched: [String] = []
        var offline = false

        for ingredient in ingredients {
            guard let product = MealieIngredientMatcher.product(for: ingredient, in: catalog) else {
                unmatched.append(ingredient.name)
                continue
            }
            if offline {
                if enqueue(product, note: ingredient.display) { queued += 1 } else { failed += 1 }
                continue
            }
            do {
                try await grocy.addProduct(productID: product.id, amount: 1, note: ingredient.display)
                added += 1
            } catch let error as APIError where error.isRetryable {
                if enqueue(product, note: ingredient.display) { queued += 1 } else { failed += 1 }
                offline = true
            } catch {
                failed += 1
            }
        }
        return MealieTransferResult(
            added: added,
            queued: queued,
            failed: failed,
            unmatched: unmatched
        )
    }

    /// Legt eine Zutat in die persistente Pending-Queue (§3.2).
    /// `false`, wenn der Cache die Operation nicht aufnehmen konnte; der
    /// Aufrufer zählt das als Fehlschlag statt als vorgemerkt.
    private func enqueue(_ product: GrocyProduct, note: String) -> Bool {
        do {
            try grocy.enqueue(name: product.name, productID: product.id, amount: 1, note: note)
            return true
        } catch {
            return false
        }
    }

    private func detail(_ error: Error) -> String {
        (error as? APIError)?.localizedDescription ?? error.localizedDescription
    }
}
