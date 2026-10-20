//
//  Syncable.swift
//  Planer
//
//  Gemeinsame Merkmale der SwiftData-Cache-Entities (spec-ios §3).
//

import Foundation

/// Merkmale, die jede Cache-Entity für Sync und Frischeprüfung mitbringt.
///
/// Zweck: einheitliche Sync-Identität und einheitlicher Cache-Zeitstempel,
/// ohne den Entity-Tabellen zusätzliche Felder aufzuzwingen.
/// Grenze: enthält keine Sync- und keine Konfliktlogik; die Regeln aus
/// spec-ios §3.1–§3.3 liegen in den Repositories der Feature-WPs (I4–I6).
protocol Syncable: AnyObject {
    /// Stabile Identität des Datensatzes im Cache (Unique-Key der Entity).
    var syncIdentifier: String { get }

    /// Zeitpunkt der letzten Server-Antwort bzw. der letzten lokalen Änderung.
    var syncTimestamp: Date { get }
}

extension Syncable {
    /// `true`, wenn der Cache-Zeitstempel älter als `ttl` ist.
    func isCacheStale(ttl: TimeInterval, now: Date = Date()) -> Bool {
        now.timeIntervalSince(syncTimestamp) >= ttl
    }
}
