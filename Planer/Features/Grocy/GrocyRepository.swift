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
/// (TTL 600 s, Server gewinnt) und die persistente Pending-Queue für
/// Offline-Hinzufügen. Die Instanz wird app-weit über `GrocyRepositoryProvider`
/// geteilt, damit Rezepte- und Einkaufs-Tab auf derselben Queue arbeiten.
/// Grenze: keine UI-Zustände; die Queue liegt als `isDirty`-Zeile im Cache und
/// wird nur beim Öffnen des Tabs bzw. auf Knopfdruck übertragen, nicht durch
/// einen Netzwerk-Monitor.
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
    ///
    /// Quelle ist der SwiftData-Cache (`GroceryItem.isDirty`, §3.2); damit
    /// übersteht die Queue einen App-Neustart. Ein Lesefehler liefert eine leere
    /// Liste, verliert aber keine Daten: die Zeilen bleiben gespeichert und
    /// `replayPending()` meldet den Fehler als Fehlschlag.
    var pendingAdds: [GroceryItem] {
        do {
            return try pendingItems()
        } catch {
            return []
        }
    }

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
    ///
    /// Queue-Zeilen (`isDirty`) bleiben außen vor: sie sind keine Serverdaten
    /// und dürfen beim Ersetzen des Caches nicht als „verschwunden“ gelöscht
    /// werden (§3.2, Server gewinnt nur über Serverdaten).
    func cachedItems(kind: GrocyCacheKind) throws -> [GroceryItem] {
        let rawKind = kind.rawValue
        let descriptor = FetchDescriptor<GroceryItem>(
            predicate: #Predicate { $0.kind == rawKind && $0.isDirty == false },
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

    /// Legt ein Hinzufügen dauerhaft in die Pending-Queue (§3.2, offline).
    ///
    /// Die Operation ist eine Cache-Zeile mit `isDirty` und eigenem
    /// `pending:{uuid}`-Schlüssel; `fetchedAt` hält ihre Reihenfolge fest. Ein
    /// Fehler beim Speichern wird geworfen, damit der Aufrufer ihn meldet statt
    /// die Operation stillschweigend zu verlieren.
    func enqueue(name: String, productID: Int, amount: Double, note: String? = nil) throws {
        let item = GroceryItem(
            serverKey: "pending:\(UUID().uuidString)",
            kind: GrocyCacheKind.shopping.rawValue,
            productId: productID,
            name: name,
            amount: amount,
            unit: "",
            note: note,
            fetchedAt: now(),
            isDirty: true
        )
        context.insert(item)
        try context.save()
    }

    /// Replay der persistenten Pending-Queue in Reihenfolge (§3.2).
    ///
    /// Erfolgreich übertragene Zeilen werden gelöscht; fehlgeschlagene bleiben
    /// `isDirty` und werden beim nächsten Lauf erneut versucht.
    func replayPending() async -> GrocyReplayResult {
        let queued: [GroceryItem]
        do {
            queued = try pendingItems()
        } catch {
            // Ohne lesbaren Cache ist kein Replay möglich; als Fehlschlag
            // melden, damit die Ansicht keinen Erfolg suggeriert.
            return GrocyReplayResult(succeeded: 0, failed: 1)
        }

        var succeeded = 0
        var failed = 0
        for item in queued {
            guard let productID = item.productId else {
                failed += 1
                continue
            }
            do {
                try await addProduct(
                    productID: productID,
                    amount: item.amount,
                    note: item.note
                )
                context.delete(item)
                try context.save()
                succeeded += 1
            } catch {
                failed += 1
            }
        }
        return GrocyReplayResult(succeeded: succeeded, failed: failed)
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

    /// Zeilen der persistenten Pending-Queue, älteste zuerst (§3.2).
    private func pendingItems() throws -> [GroceryItem] {
        let descriptor = FetchDescriptor<GroceryItem>(
            predicate: #Predicate { $0.isDirty == true },
            sortBy: [SortDescriptor(\GroceryItem.fetchedAt)]
        )
        return try context.fetch(descriptor)
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
