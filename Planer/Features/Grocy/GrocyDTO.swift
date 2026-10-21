//
//  GrocyDTO.swift
//  Planer
//
//  Wire-Formate der Grocy-API und ihre Normalform (spec-ios §2.3, §3.2).
//

import Foundation

/// Einheitenangabe, wie Grocy sie liefert: entweder ein String oder
/// `{ "name": … }`. Beide Formen deckt auch
/// `worldplaner/backend/app/services/grocy.py` (`_unit_name`) ab.
struct GrocyUnitValue: Decodable, Equatable {
    let name: String

    private struct Wrapped: Decodable {
        let name: String?
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let text = try? container.decode(String.self) {
            name = text
            return
        }
        name = (try? container.decode(Wrapped.self))?.name ?? ""
    }
}

/// Grocy-Flag: `done` steht in `/objects/shopping_list` als Zahl (0/1) in der
/// Tabelle (Migrationen 0075/0117), andere Objekte liefern einen Boolean.
struct GrocyFlagValue: Decodable, Equatable {
    let isOn: Bool

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let flag = try? container.decode(Bool.self) {
            isOn = flag
            return
        }
        if let number = try? container.decode(Int.self) {
            isOn = number != 0
            return
        }
        if let text = try? container.decode(String.self), let number = Int(text) {
            isOn = number != 0
            return
        }
        throw DecodingError.dataCorruptedError(
            in: container,
            debugDescription: "Grocy-Flag ist weder Boolean noch Zahl."
        )
    }
}

/// Tagesdatum aus Grocy (`YYYY-MM-DD`); leere Strings und `null` bedeuten
/// „kein Datum“ (so behandelt es auch `normalize_product` im Backend).
enum GrocyDay {
    static func parse(_ raw: String?) -> Date? {
        guard let raw, !raw.isEmpty else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.date(from: raw)
    }
}

/// Produkt aus `GET /objects/products` bzw. das verschachtelte `product` aus
/// `GET /stock`. Nur die Felder, die die App braucht; unbekannte Schlüssel der
/// API ignoriert `Decodable`.
struct GrocyProduct: Decodable, Identifiable, Equatable, Sendable {
    let id: Int
    let name: String
    /// Bestands-Einheit als ID; der Name steht nur in
    /// `GET /objects/quantity_units` (`{id,name}`).
    let quantityUnitStockID: Int?

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case quantityUnitStockID = "qu_id_stock"
    }
}

/// Zeile aus `GET /objects/quantity_units`. Die App braucht nur die
/// Nachschlagetabelle ID → Name.
struct GrocyQuantityUnit: Decodable, Equatable, Sendable {
    let id: Int
    let name: String
}

/// Rohe Bestandszeile aus `GET /stock` (grocy.openapi.json
/// `CurrentStockResponse`). Einheiten sind je nach Grocy-Version an
/// unterschiedlichen Stellen abgelegt, deshalb die Fallback-Kette.
struct GrocyStockEntry: Decodable, Equatable {
    private let productID: Int?
    private let fallbackID: Int?
    private let amount: Double?
    private let bestBeforeDate: String?
    private let product: GrocyProduct?
    private let stockUnitName: GrocyUnitValue?
    private let quantityUnitName: GrocyUnitValue?
    private let quantityUnit: GrocyUnitValue?
    private let unit: GrocyUnitValue?

    enum CodingKeys: String, CodingKey {
        case productID = "product_id"
        case fallbackID = "id"
        case amount
        case bestBeforeDate = "best_before_date"
        case product
        case stockUnitName = "stock_unit_name"
        case quantityUnitName = "qu_name"
        case quantityUnit = "quantity_unit"
        case unit
    }

    /// Normalform aus §2.3; `nil`, wenn die Zeile keine Produkt-ID trägt
    /// (das Backend verwirft solche Zeilen ebenfalls).
    func normalize(
        today: Date,
        calendar: Calendar,
        unitNames: [Int: String] = [:]
    ) -> GrocyStockItem? {
        guard let productID = productID ?? fallbackID else { return nil }
        let bestBeforeDate = GrocyDay.parse(bestBeforeDate)
        return GrocyStockItem(
            productID: productID,
            name: product?.name ?? "",
            amount: amount ?? 0,
            unit: resolvedUnitName(unitNames: unitNames),
            bestBeforeDate: bestBeforeDate,
            isExpired: Self.isExpired(bestBeforeDate, today: today, calendar: calendar)
        )
    }

    /// MHD vor heute → abgelaufen (fachlich dieselbe Regel wie
    /// `is_expired` in `worldplaner/backend/app/services/grocy.py`).
    static func isExpired(_ bestBeforeDate: Date?, today: Date, calendar: Calendar) -> Bool {
        guard let bestBeforeDate else { return false }
        return calendar.startOfDay(for: bestBeforeDate) < calendar.startOfDay(for: today)
    }

    /// `/api/stock` liefert keinen Einheitennamen, nur `product.qu_id_stock`.
    /// Ein mitgelieferter Name hat Vorrang (Snapshot-Kompatibilität); fehlt er,
    /// löst die Namensmap die ID auf. Unbekannte ID → leerer String.
    private func resolvedUnitName(unitNames: [Int: String]) -> String {
        let candidates = [stockUnitName, quantityUnitName, quantityUnit, unit]
        if let name = candidates.compactMap({ $0?.name }).first(where: { !$0.isEmpty }) {
            return name
        }
        guard let id = product?.quantityUnitStockID else { return "" }
        return unitNames[id] ?? ""
    }
}

/// Normalform eines Bestandseintrags (spec-ios §2.3, Schema §3.4).
struct GrocyStockItem: Equatable, Identifiable, Sendable {
    let productID: Int
    let name: String
    let amount: Double
    let unit: String
    let bestBeforeDate: Date?
    let isExpired: Bool

    var id: Int { productID }
}

/// Rohe Einkaufslisten-Zeile aus `GET /objects/shopping_list`.
///
/// `ShoppingListItem` in grocy.openapi.json kennt `id`, `product_id`, `note`,
/// `amount`; `done` und `qu_id` ergänzen die Tabelle per Migration
/// (0075/0117). `product`/`qu_name` sind Anreicherungen, die nicht jede
/// Grocy-Version mitliefert.
struct GrocyShoppingEntry: Decodable, Equatable {
    let id: Int
    private let productID: Int?
    private let amount: Double?
    private let note: String?
    private let done: GrocyFlagValue?
    private let product: GrocyProduct?
    private let quantityUnitName: GrocyUnitValue?
    private let quantityUnitID: Int?
    private let unit: GrocyUnitValue?

    enum CodingKeys: String, CodingKey {
        case id
        case productID = "product_id"
        case amount
        case note
        case done
        case product
        case quantityUnitName = "qu_name"
        case quantityUnitID = "qu_id"
        case unit
    }

    /// Normalform aus §3.2 mit Produktnamen aus dem Katalog, weil
    /// `/objects/shopping_list` nur `product_id` liefert. Die Einheit kommt
    /// aus `qu_id` über die Namensmap; ein mitgelieferter Name hat Vorrang.
    func normalize(
        catalog: [Int: GrocyProduct],
        unitNames: [Int: String] = [:]
    ) -> GrocyShoppingItem {
        let note = self.note?.trimmingCharacters(in: .whitespacesAndNewlines)
        let catalogName = productID.flatMap { catalog[$0]?.name }
        let fallbackName = productID.map { "Produkt \($0)" } ?? "Einkaufsposten"
        let name = product?.name
            ?? catalogName
            ?? (note?.isEmpty == false ? note : nil)
            ?? fallbackName
        let explicitUnitName = [quantityUnitName, unit]
            .compactMap { $0?.name }
            .first { !$0.isEmpty }
        let unitName = explicitUnitName
            ?? quantityUnitID.flatMap { unitNames[$0] }
            ?? ""
        return GrocyShoppingItem(
            itemID: id,
            productID: productID,
            name: name,
            amount: amount ?? 0,
            unit: unitName,
            note: note,
            isDone: done?.isOn ?? false
        )
    }
}

/// Normalform eines Einkaufslisten-Eintrags (spec-ios §3.2).
struct GrocyShoppingItem: Equatable, Identifiable, Sendable {
    let itemID: Int
    let productID: Int?
    let name: String
    let amount: Double
    let unit: String
    let note: String?
    let isDone: Bool

    var id: Int { itemID }
}
