//
//  TodoItem.swift
//  Planer
//
//  Kanonisches SwiftData-Schema eines To-Dos (spec-ios §3.1).
//

import Foundation
import SwiftData

/// Offline-Cache eines To-Dos, Spiegel von `hermes_tasks`.
///
/// Zweck: lokale Anzeige und Offline-Mutationen; `version` trägt die
/// optimistische Sperre für `PATCH /api/tasks/{id}` (`base_version`).
/// Grenze: kein Netzwerkzugriff und keine Konfliktauflösung; beides liegt bei I4.
@Model
final class TodoItem: Syncable {
    @Attribute(.unique) var id: String
    var title: String
    var itemDescription: String
    /// `open` oder `done` (spec-ios §3.1).
    var status: String
    /// `low`, `normal` oder `high` (spec-ios §3.1).
    var priority: String
    /// `hermes` oder `local` (spec-ios §3.1).
    var source: String
    var dueAt: Date?
    var completedAt: Date?
    /// Optimistische Sperre des Servers (spec-ios §3.1).
    var version: Int
    var updatedAt: Date
    /// Lokale, noch nicht übertragene Änderung.
    var isDirty: Bool
    /// Lokal gelöscht, Löschung noch nicht übertragen.
    var pendingDelete: Bool

    init(
        id: String = UUID().uuidString,
        title: String,
        itemDescription: String = "",
        status: String = "open",
        priority: String = "normal",
        source: String = "local",
        dueAt: Date? = nil,
        completedAt: Date? = nil,
        version: Int = 1,
        updatedAt: Date = Date(),
        isDirty: Bool = false,
        pendingDelete: Bool = false
    ) {
        self.id = id
        self.title = title
        self.itemDescription = itemDescription
        self.status = status
        self.priority = priority
        self.source = source
        self.dueAt = dueAt
        self.completedAt = completedAt
        self.version = version
        self.updatedAt = updatedAt
        self.isDirty = isDirty
        self.pendingDelete = pendingDelete
    }

    var syncIdentifier: String { id }
    var syncTimestamp: Date { updatedAt }
}
