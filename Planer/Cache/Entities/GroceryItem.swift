//
//  GroceryItem.swift
//  Planer
//
//  Kanonisches SwiftData-Schema eines Einkaufs-/Bestands-Eintrags (spec-ios §3.2).
//

import Foundation
import SwiftData

/// Read-through-Cache für Grocy-Bestand und Einkaufsliste.
///
/// Zweck: zuletzt geladene Grocy-Daten offline anzeigen; `serverKey` verbindet
/// Bestands- und Einkaufslisten-Einträge eindeutig mit dem Server
/// (`stock:{product_id}` bzw. `list:{item_id}`).
/// Grenze: kein Netzwerkzugriff; Sync und Pending-Replay liegen bei I5.
@Model
final class GroceryItem: Syncable {
    @Attribute(.unique) var serverKey: String
    /// `stock` oder `shopping` (spec-ios §3.2).
    var kind: String
    var productId: Int?
    var itemId: Int?
    var name: String
    var amount: Double
    var unit: String
    var note: String?
    var done: Bool
    var bestBeforeDate: Date?
    var isExpired: Bool
    var fetchedAt: Date

    init(
        serverKey: String,
        kind: String,
        productId: Int? = nil,
        itemId: Int? = nil,
        name: String,
        amount: Double,
        unit: String,
        note: String? = nil,
        done: Bool = false,
        bestBeforeDate: Date? = nil,
        isExpired: Bool = false,
        fetchedAt: Date = Date()
    ) {
        self.serverKey = serverKey
        self.kind = kind
        self.productId = productId
        self.itemId = itemId
        self.name = name
        self.amount = amount
        self.unit = unit
        self.note = note
        self.done = done
        self.bestBeforeDate = bestBeforeDate
        self.isExpired = isExpired
        self.fetchedAt = fetchedAt
    }

    /// Gültigkeitsdauer des Read-through-Cache in Sekunden (spec-ios §3.2).
    static let cacheTTL: TimeInterval = 600

    var syncIdentifier: String { serverKey }
    var syncTimestamp: Date { fetchedAt }
}
