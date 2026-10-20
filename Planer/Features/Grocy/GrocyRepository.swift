//
//  GrocyRepository.swift
//  Planer
//
//  Grocy-Zugriff und Read-through-Cache des Einkaufs-Tabs (spec-ios §2.3, §3.2).
//

import Foundation
import SwiftData

/// Cache-Art, wie sie in `GroceryItem.kind` steht (spec-ios §3.2).
enum GrocyCacheKind: String, CaseIterable {
    case stock
    case shopping
}

/// Ein vollständiger Lese-Stand aus Grocy.
struct GrocySnapshot: Equatable {
    let stock: [GrocyStockItem]
    let shopping: [GrocyShoppingItem]
    let catalog: [GrocyProduct]
}

/// Ein Hinzufügen, das noch nicht bei Grocy angekommen ist (§3.2 Pending-Queue).
struct GrocyPendingAdd: Equatable, Identifiable {
    let id: UUID
    let productID: Int
    let amount: Double
    let note: String?
    /// `true`, wenn der letzte Replay-Versuch fehlgeschlagen ist.
    var failed: Bool
}

/// Ergebnis eines Replay-Laufs der Pending-Queue.
struct GrocyReplayResult: Equatable {
    let succeeded: Int
    let failed: Int
}

/// Darstellbare Zeile des Tabs.
///
/// Zweck: die Ansicht hält keine SwiftData-Objekte, die ein `refresh()` löscht.
/// Grenze: reiner Wertetyp ohne Fachlogik.
struct GrocyRow: Identifiable, Equatable {
    let id: String
    let name: String
    let amount: Double
    let unit: String
    let note: String?
    let isDone: Bool
    let bestBeforeDate: Date?
    let isExpired: Bool
    let isPending: Bool
}

extension GrocyRow {
    init(stock: GrocyStockItem) {
        self.init(
            id: "stock:\(stock.productID)",
            name: stock.name,
            amount: stock.amount,
            unit: stock.unit,
            note: nil,
            isDone: false,
            bestBeforeDate: stock.bestBeforeDate,
            isExpired: stock.isExpired,
            isPending: false
        )
    }

    init(shopping: GrocyShoppingItem) {
        self.init(
            id: "list:\(shopping.itemID)",
            name: shopping.name,
            amount: shopping.amount,
            unit: shopping.unit,
            note: shopping.note,
            isDone: shopping.isDone,
            bestBeforeDate: nil,
            isExpired: false,
            isPending: false
        )
    }
}

/// Spricht Grocy direkt an und spiegelt Bestand und Einkaufsliste in den
/// SwiftData-Cache aus I2.
///
/// Zweck: eine Stelle für die vier Endpunkte aus §2.3, die Cache-Regel aus §3.2
/// (TTL 600 s, Server gewinnt) und die Pending-Queue für Offline-Hinzufügen.
/// Die Instanz wird app-weit über `GrocyRepositoryProvider` geteilt, damit
/// Rezepte- und Einkaufs-Tab auf derselben Queue arbeiten.
/// Grenze: keine UI-Zustände; die Pending-Queue ist bewusst flüchtig, weil die
/// Cache-Entities aus I2 kein Pending-Feld haben und `Planer/Cache/**` für I5
/// gesperrt ist (siehe Abschlussbericht, OFFEN).
@MainActor
final class GrocyRepository {

    /// Pfade relativ zur Basis-URL `https://<grocy>/api` (§2.3).
    enum Path {
        static let stock = "/stock"
        static let shoppingList = "/objects/shopping_list"
        static let products = "/objects/products"
        static let addProduct = "/stock/shoppinglist/add-product"
    }

    private let client: NetworkClient
    private let context: ModelContext
    private let now: () -> Date
    private let calendar: Calendar

    /// Noch nicht übertragene Hinzufügen-Operationen, älteste zuerst.
    private(set) var pendingAdds: [GrocyPendingAdd] = []

    init(
        client: NetworkClient = NetworkClient(),
        context: ModelContext,
        now: @escaping () -> Date = Date.init,
        calendar: Calendar = .current
    ) {
        self.client = client
        self.context = context
        self.now = now
        self.calendar = calendar
    }

    // MARK: - Lesen und Cache

    /// Liest die zwischengespeicherten Einträge einer Art, nach Name sortiert.
    func cachedItems(kind: GrocyCacheKind) throws -> [GroceryItem] {
        let rawKind = kind.rawValue
        let descriptor = FetchDescriptor<GroceryItem>(
            predicate: #Predicate { $0.kind == rawKind },
            sortBy: [SortDescriptor(\GroceryItem.name)]
        )
        return try context.fetch(descriptor)
    }

    /// Darstellbare Zeilen aus dem Cache.
    func cachedRows(kind: GrocyCacheKind) throws -> [GrocyRow] {
        try cachedItems(kind: kind).map { item in
            GrocyRow(
                id: item.serverKey,
                name: item.name,
                amount: item.amount,
                unit: item.unit,
                note: item.note,
                isDone: item.done,
                bestBeforeDate: item.bestBeforeDate,
                isExpired: item.isExpired,
                isPending: false
            )
        }
    }

    /// `true`, wenn der Cache der Art existiert und jünger als
    /// `GroceryItem.cacheTTL` (600 s, §3.2) ist.
    ///
    /// Ein Fetch-Fehler zählt als „nicht frisch“: der folgende `refresh()`
    /// meldet den Fehler, und die Ansicht zeigt den letzten Cache.
    func isCacheFresh(kind: GrocyCacheKind) -> Bool {
        do {
            let newest = try cachedItems(kind: kind).map(\.fetchedAt).max()
            guard let newest else { return false }
            return now().timeIntervalSince(newest) < GroceryItem.cacheTTL
        } catch {
            return false
        }
    }

    // MARK: - Netz

    /// `GET /api/stock` in der Normalform aus §2.3.
    func fetchStock() async throws -> [GrocyStockItem] {
        let entries = try await client.send(
            APIRequest(method: .get, path: Path.stock),
            for: .grocy,
            as: [GrocyStockEntry].self
        )
        let today = now()
        return entries.compactMap { $0.normalize(today: today, calendar: calendar) }
    }

    /// `GET /api/objects/shopping_list`; Produktnamen kommen aus dem Katalog,
    /// weil die Liste nur `product_id` trägt.
    func fetchShoppingList(catalog: [GrocyProduct]) async throws -> [GrocyShoppingItem] {
        let entries = try await client.send(
            APIRequest(method: .get, path: Path.shoppingList),
            for: .grocy,
            as: [GrocyShoppingEntry].self
        )
        let byID = Dictionary(catalog.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return entries.map { $0.normalize(catalog: byID) }
    }

    /// `GET /api/objects/products` — Quelle der Autovervollständigung.
    func fetchCatalog() async throws -> [GrocyProduct] {
        try await client.send(
            APIRequest(method: .get, path: Path.products),
            for: .grocy,
            as: [GrocyProduct].self
        )
    }

    /// Lädt Bestand, Einkaufsliste und Katalog und ersetzt den Cache (§3.2).
    ///
    /// Grocy ist autoritativ: der Cache wird vollständig ersetzt, nicht gemischt.
    @discardableResult
    func refresh() async throws -> GrocySnapshot {
        async let stockTask = fetchStock()
        async let catalogTask = fetchCatalog()
        let (stock, catalog) = try await (stockTask, catalogTask)
        let shopping = try await fetchShoppingList(catalog: catalog)

        let fetchedAt = now()
        try upsertStock(stock, fetchedAt: fetchedAt)
        try upsertShopping(shopping, fetchedAt: fetchedAt)
        try context.save()
        return GrocySnapshot(stock: stock, shopping: shopping, catalog: catalog)
    }

    // MARK: - Schreiben

    /// `POST /api/stock/shoppinglist/add-product` (§2.3).
    ///
    /// `qu_id` bleibt weg: Grocy rechnet dann in der Bestands-Einheit des
    /// Produkts (grocy.openapi.json, `qu_id`-Beschreibung). Antwort ist `204`.
    func addProduct(productID: Int, amount: Double, note: String? = nil) async throws {
        let body = try JSONEncoder().encode(
            AddProductBody(productID: productID, productAmount: amount, note: note)
        )
        _ = try await client.send(
            APIRequest(method: .post, path: Path.addProduct, body: body),
            for: .grocy
        )
    }

    /// Legt ein Hinzufügen in die Pending-Queue (§3.2, offline).
    func enqueue(productID: Int, amount: Double, note: String? = nil) {
        pendingAdds.append(
            GrocyPendingAdd(
                id: UUID(),
                productID: productID,
                amount: amount,
                note: note,
                failed: false
            )
        )
    }

    /// Replay der Pending-Queue in Reihenfolge; Fehlschläge bleiben als
    /// `failed` markiert in der Queue (§3.2).
    func replayPending() async -> GrocyReplayResult {
        var remaining: [GrocyPendingAdd] = []
        var succeeded = 0
        for var pending in pendingAdds {
            do {
                try await addProduct(
                    productID: pending.productID,
                    amount: pending.amount,
                    note: pending.note
                )
                succeeded += 1
            } catch {
                pending.failed = true
                remaining.append(pending)
            }
        }
        pendingAdds = remaining
        return GrocyReplayResult(succeeded: succeeded, failed: remaining.count)
    }

    // MARK: - Cache-Schreiben

    /// Gleicht den Bestands-Cache mit dem Serverstand ab: vorhandene Zeilen
    /// werden aktualisiert, neue eingefügt, verschwundene gelöscht. Aktualisieren
    /// statt Löschen+Einfügen, weil `serverKey` eindeutig ist (I2).
    private func upsertStock(_ items: [GrocyStockItem], fetchedAt: Date) throws {
        let rawKind = GrocyCacheKind.stock.rawValue
        var leftovers = try cacheByServerKey(kind: .stock)
        for item in items {
            let serverKey = "stock:\(item.productID)"
            let cached: GroceryItem
            if let existing = leftovers.removeValue(forKey: serverKey) {
                cached = existing
            } else {
                let created = GroceryItem(
                    serverKey: serverKey,
                    kind: rawKind,
                    productId: item.productID,
                    name: item.name,
                    amount: item.amount,
                    unit: item.unit,
                    bestBeforeDate: item.bestBeforeDate,
                    isExpired: item.isExpired,
                    fetchedAt: fetchedAt
                )
                context.insert(created)
                cached = created
            }
            cached.productId = item.productID
            cached.name = item.name
            cached.amount = item.amount
            cached.unit = item.unit
            cached.bestBeforeDate = item.bestBeforeDate
            cached.isExpired = item.isExpired
            cached.fetchedAt = fetchedAt
        }
        for gone in leftovers.values {
            context.delete(gone)
        }
    }

    /// Gleicht den Einkaufslisten-Cache mit dem Serverstand ab (Grocy gewinnt).
    private func upsertShopping(_ items: [GrocyShoppingItem], fetchedAt: Date) throws {
        let rawKind = GrocyCacheKind.shopping.rawValue
        var leftovers = try cacheByServerKey(kind: .shopping)
        for item in items {
            let serverKey = "list:\(item.itemID)"
            let cached: GroceryItem
            if let existing = leftovers.removeValue(forKey: serverKey) {
                cached = existing
            } else {
                let created = GroceryItem(
                    serverKey: serverKey,
                    kind: rawKind,
                    productId: item.productID,
                    itemId: item.itemID,
                    name: item.name,
                    amount: item.amount,
                    unit: item.unit,
                    note: item.note,
                    done: item.isDone,
                    fetchedAt: fetchedAt
                )
                context.insert(created)
                cached = created
            }
            cached.productId = item.productID
            cached.itemId = item.itemID
            cached.name = item.name
            cached.amount = item.amount
            cached.unit = item.unit
            cached.note = item.note
            cached.done = item.isDone
            cached.fetchedAt = fetchedAt
        }
        for gone in leftovers.values {
            context.delete(gone)
        }
    }

    private func cacheByServerKey(kind: GrocyCacheKind) throws -> [String: GroceryItem] {
        let items = try cachedItems(kind: kind)
        return Dictionary(items.map { ($0.serverKey, $0) }, uniquingKeysWith: { first, _ in first })
    }
}

/// Einzige Bezugsstelle der app-weit geteilten `GrocyRepository`-Instanz.
///
/// Zweck: Rezepte- und Einkaufs-Tab müssen dieselbe Pending-Queue sehen, damit
/// eine im Rezepte-Tab offline vorgemerkte Zutat beim nächsten Öffnen des
/// Einkaufs-Tabs übertragen wird (§3.2). Ein Repository je Tab hätte je eine
/// eigene Queue; die Zutaten gingen verloren.
/// Grenze: hält einen Eintrag je `ModelContext` und gibt ihn nicht aktiv frei;
/// im App-Betrieb gibt es genau einen Kontext, der so lange lebt wie die App.
@MainActor
enum GrocyRepositoryProvider {

    private static var instances: [ObjectIdentifier: GrocyRepository] = [:]

    /// Liefert die geteilte Instanz für den übergebenen SwiftData-Kontext.
    static func shared(context: ModelContext) -> GrocyRepository {
        let key = ObjectIdentifier(context)
        if let existing = instances[key] {
            return existing
        }
        let created = GrocyRepository(context: context)
        instances[key] = created
        return created
    }
}

/// Body von `add-product` (grocy.openapi.json: `product_id`, `qu_id`,
/// `list_id`, `product_amount`, `note`).
private struct AddProductBody: Encodable {
    let productID: Int
    let productAmount: Double
    let note: String?

    enum CodingKeys: String, CodingKey {
        case productID = "product_id"
        case productAmount = "product_amount"
        case note
    }
}
