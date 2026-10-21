//
//  GrocyViewModel.swift
//  Planer
//
//  Zustand des Einkaufs-Tabs (spec-ios §3.2, §10).
//

import Combine
import Foundation

/// Lädt Bestand/Einkaufsliste über den Cache und führt Hinzufügen aus.
///
/// Zweck: Cache-Regel aus §3.2 (frisch → Cache, sonst Server, Server gewinnt),
/// die Autovervollständigung aus dem Produktkatalog und das Übertragen der
/// app-weit geteilten, persistenten Pending-Queue aus I5/I6.
/// Grenze: die Queue wird beim Öffnen des Tabs und auf Knopfdruck übertragen,
/// nicht durch einen Netzwerk-Monitor.
@MainActor
final class GrocyViewModel: ObservableObject {

    @Published private(set) var stock: [GrocyRow] = []
    @Published private(set) var shopping: [GrocyRow] = []
    @Published private(set) var catalog: [GrocyProduct] = []
    @Published private(set) var suggestions: [GrocyProduct] = []
    @Published private(set) var banner: String?
    @Published private(set) var isLoading = false
    @Published private(set) var pendingCount = 0
    @Published var query = "" {
        didSet { updateSuggestions() }
    }
    /// Mengen-Eingabe als Text, damit Tastatur und Komma-Eingabe funktionieren.
    @Published var amountText = "1"

    private let repository: GrocyRepository

    init(repository: GrocyRepository) {
        self.repository = repository
        self.pendingCount = repository.pendingAdds.count
    }

    /// Gültige Menge; unlesbare oder nicht positive Eingaben fallen auf 1 zurück.
    var amount: Double {
        let normalized = amountText.replacingOccurrences(of: ",", with: ".")
        guard let value = Double(normalized), value > 0 else { return 1 }
        return value
    }

    /// Lädt die Ansicht: frischer Cache bleibt stehen, sonst Server (§3.2).
    ///
    /// Die Queue wird bei jedem Öffnen neu gelesen: sie wird app-weit geteilt
    /// und kann seit dem Bau des ViewModels im Rezepte-Tab gefüllt worden sein.
    func load() async {
        isLoading = true
        defer { isLoading = false }

        pendingCount = repository.pendingAdds.count
        if repository.isCacheFresh(kind: .stock) && repository.isCacheFresh(kind: .shopping) {
            reloadFromCache()
        } else {
            await refresh()
        }
        if pendingCount > 0 {
            await retryPending()
        }
    }

    /// Fügt ein Katalogprodukt zur Einkaufsliste hinzu.
    ///
    /// Optimistische Zeile sofort; bei Offline/Timeout wandert die Operation in
    /// die Pending-Queue, bei fachlichen Fehlern (4xx) wird sie zurückgenommen.
    func add(_ product: GrocyProduct) async {
        let amount = amount
        query = ""
        let optimistic = GrocyRow(
            id: "pending:\(UUID().uuidString)",
            name: product.name,
            amount: amount,
            unit: "",
            note: nil,
            isDone: false,
            bestBeforeDate: nil,
            isExpired: false,
            isPending: true
        )
        shopping.insert(optimistic, at: 0)

        do {
            try await repository.addProduct(productID: product.id, amount: amount)
            await refresh()
        } catch let error as APIError where error.isRetryable {
            do {
                try repository.enqueue(name: product.name, productID: product.id, amount: amount)
                pendingCount = repository.pendingAdds.count
                banner = "Offline — „\(product.name)“ wird übertragen, sobald Grocy erreichbar ist."
            } catch {
                shopping.removeAll { $0.id == optimistic.id }
                banner = "„\(product.name)“ konnte nicht vorgemerkt werden: \(error.localizedDescription)"
            }
        } catch {
            shopping.removeAll { $0.id == optimistic.id }
            banner = "„\(product.name)“ konnte nicht hinzugefügt werden: \(error.localizedDescription)"
        }
    }

    /// Überträgt die Pending-Queue (§3.2) und lädt danach den Serverstand.
    func retryPending() async {
        guard pendingCount > 0 else { return }
        let result = await repository.replayPending()
        pendingCount = repository.pendingAdds.count
        if result.succeeded > 0 {
            await refresh()
        }
        if result.failed > 0 {
            banner = "\(result.failed) Einkaufsposten konnten nicht übertragen werden — Grocy prüfen."
        }
    }

    // MARK: - Intern

    private func refresh() async {
        do {
            let snapshot = try await repository.refresh()
            catalog = snapshot.catalog
            stock = snapshot.stock.map { GrocyRow(stock: $0) }
            shopping = snapshot.shopping.map { GrocyRow(shopping: $0) }
            banner = snapshot.unitsUnavailable
                ? "Einheiten konnten nicht geladen werden — Mengen erscheinen ohne Einheit."
                : nil
        } catch {
            let detail = (error as? APIError)?.localizedDescription ?? error.localizedDescription
            let cached = reloadFromCache()
            banner = cached
                ? "Grocy nicht erreichbar — letzter Stand wird angezeigt. (\(detail))"
                : "Grocy nicht erreichbar. (\(detail))"
        }
        updateSuggestions()
    }

    /// Lädt den Cache in die Anzeige; `false`, wenn kein Cache vorhanden ist.
    @discardableResult
    private func reloadFromCache() -> Bool {
        do {
            stock = try repository.cachedRows(kind: .stock)
            shopping = try repository.cachedRows(kind: .shopping)
            return !stock.isEmpty || !shopping.isEmpty
        } catch {
            stock = []
            shopping = []
            banner = "Cache nicht lesbar: \(error.localizedDescription)"
            return false
        }
    }

    private func updateSuggestions() {
        suggestions = Self.suggestions(for: query, in: catalog)
    }

    /// Autovervollständigung: Treffer im Katalog, alphabetisch, begrenzt.
    /// Reine Funktion, damit sie ohne Netz prüfbar ist.
    static func suggestions(
        for query: String,
        in catalog: [GrocyProduct],
        limit: Int = 8
    ) -> [GrocyProduct] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        let matches = catalog
            .filter { $0.name.localizedCaseInsensitiveContains(trimmed) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        return Array(matches.prefix(limit))
    }
}
