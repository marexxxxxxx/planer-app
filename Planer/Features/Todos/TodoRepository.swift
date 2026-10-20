//
//  TodoRepository.swift
//  Planer
//
//  REST-Zugriff auf `worldplaner` `/api/tasks` plus SwiftData-Cache (spec-ios §2.2, §3.1).
//

import Foundation
import SwiftData

/// Übersetzt zwischen `TodoDTO`, SwiftData-`TodoItem` und `/api/tasks`.
///
/// Zweck: die einzige Stelle, an der To-Dos geladen, angelegt, geändert und
/// gelöscht werden. Der Server ist die Quelle der Wahrheit; der Cache hält den
/// letzten Stand und lokal noch nicht übertragene Änderungen.
/// Grenze: keine UI-Zustände und keine Konfliktdarstellung — das macht
/// `TodosViewModel`. Es werden keine Cache-Entities neu definiert (I2).
///
/// Vertragsdetails aus spec-ios §2.2:
/// - `GET /tasks?status=all|open|done&limit=1…200`
/// - `POST /tasks` → `201` + Task
/// - `PATCH /tasks/{id}` mit `base_version` → `409 CONFLICT` bei Abweichung
/// - `DELETE /tasks/{id}` → `204`
/// - Dashboard-Auth: nur CF-Access-Header, kein `Authorization` (macht der
///   `NetworkClient`; dieses Repository setzt keine Header selbst).
/// - Die in den Einstellungen hinterlegte Dashboard-Basis-URL enthält `/api`
///   (spec-ios §2.2); die Pfade hier sind deshalb relativ (`/tasks`).
@MainActor
struct TodoRepository {

    private let context: ModelContext
    private let network: NetworkClient

    init(context: ModelContext, network: NetworkClient = NetworkClient()) {
        self.context = context
        self.network = network
    }

    // MARK: - Lesen

    /// Lädt die gefilterte Serverliste und spiegelt sie in den Cache.
    ///
    /// `today` fragt serverseitig `status=open` ab (§2.2 kennt kein `today`)
    /// und liest die Projektion anschließend über `due_at` auf den heutigen
    /// Kalendertag ein.
    /// Rückgabe ist die Cache-Projektion, damit lokal vorgemerkte Änderungen
    /// (dirty/unsynced) sichtbar bleiben, bis sie übertragen sind.
    func fetch(
        status: TodoStatusFilter,
        limit: Int = TodoAPI.defaultLimit
    ) async throws -> [TodoDTO] {
        let effectiveLimit = Self.clamped(limit)
        let tasks = try await requestTasks(status: status, limit: effectiveLimit)

        // Nur ein vollständiger, ungekürzter Abruf sagt etwas über fehlende
        // Einträge aus. Ein gefilterter Abruf darf nur Einträge genau dieses
        // Status aufräumen; ein gekürzter Abruf gar nichts.
        let prune: PruneScope
        if tasks.count < effectiveLimit {
            // `today` lädt serverseitig `open`; der Prune-Bereich ist deshalb
            // der Server-Status, nicht der Segmentname.
            prune = status == .all ? .all : .status(status.serverStatus)
        } else {
            prune = .none
        }
        try merge(tasks, prune: prune)
        return try cached(status: status, limit: effectiveLimit)
    }

    /// Liest den letzten Cache-Stand, ohne das Netz zu berühren (Offline-Pfad).
    func cached(
        status: TodoStatusFilter,
        limit: Int = TodoAPI.maximumLimit
    ) throws -> [TodoDTO] {
        let effectiveLimit = Self.clamped(limit)
        let items = try context.fetch(FetchDescriptor<TodoItem>())
        let visible = items
            .filter {
                status.includes(
                    itemStatus: $0.status,
                    dueAt: $0.dueAt,
                    isPendingDelete: $0.pendingDelete
                )
            }
            .sorted { $0.updatedAt > $1.updatedAt }
            .prefix(effectiveLimit)
        return visible.map(TodoDTO.init(item:))
    }

    /// Holt einen einzelnen Serverstand. Es gibt kein `GET /tasks/{id}`;
    /// deshalb läuft der Abruf über die All-Liste mit Server-Maximum.
    func serverTask(id: String) async throws -> TodoDTO? {
        let tasks = try await requestTasks(status: .all, limit: TodoAPI.maximumLimit)
        try merge(tasks, prune: .none)
        return tasks.first { $0.id == id }
    }

    // MARK: - Schreiben

    /// `POST /tasks`; bei Erfolg ersetzt der Serverstand den lokalen Eintrag.
    func create(_ draft: TodoDraft) async throws -> TodoDTO {
        let body = TodoCreateBody(
            title: draft.trimmedTitle,
            description: draft.details,
            priority: draft.priority,
            dueAt: draft.dueDate.map(Self.apiDay)
        )
        let dto: TodoDTO = try await network.send(
            APIRequest(method: .post, path: "/tasks", body: try encode(body)),
            for: .dashboard,
            as: TodoDTO.self
        )
        try upsert(dto, clearLocalState: true)
        return dto
    }

    /// Legt ein To-Do nur im Cache an (`version = 0`, `isDirty = true`) und
    /// stellt es in die Warteschlange für den nächsten Abgleich.
    func stageCreate(_ draft: TodoDraft) throws -> TodoDTO {
        let item = TodoItem(
            title: draft.trimmedTitle,
            itemDescription: draft.details,
            status: TodoStatus.open.rawValue,
            priority: draft.priority,
            source: "local",
            dueAt: draft.dueDate,
            version: TodoAPI.unsyncedVersion,
            isDirty: true
        )
        context.insert(item)
        try context.save()
        return TodoDTO(item: item)
    }

    /// `PATCH /tasks/{id}` mit optimistischer Sperre.
    ///
    /// Die Änderung wird zuerst lokal sichtbar und als `isDirty` markiert. Bei
    /// Offline/Timeout bleibt sie dirty und wird später erneut gesendet; bei
    /// `409 CONFLICT` bleibt sie ebenfalls stehen, damit der Nutzer entscheiden
    /// kann (spec-ios §3.1, AD-7).
    @discardableResult
    func update(
        id: String,
        title: String? = nil,
        details: String? = nil,
        status: String? = nil,
        priority: String? = nil,
        dueAt: Date? = nil,
        baseVersion: Int
    ) async throws -> TodoDTO {
        guard let item = try item(id: id) else {
            throw APIError.notFound
        }

        if let title { item.title = title }
        if let details { item.itemDescription = details }
        if let status { item.status = status }
        if let priority { item.priority = priority }
        if let dueAt { item.dueAt = dueAt }
        item.isDirty = true
        item.updatedAt = Date()
        try context.save()

        // Ein noch nie angelegter Eintrag hat keine Server-ID; er bleibt lokal
        // und wird beim Abgleich zuerst per POST angelegt (siehe flushPending).
        if item.version == TodoAPI.unsyncedVersion {
            return TodoDTO(item: item)
        }

        let body = TodoUpdateBody(
            title: title,
            description: details,
            status: status,
            priority: priority,
            dueAt: dueAt.map(Self.apiDay),
            baseVersion: baseVersion
        )
        let dto: TodoDTO = try await network.send(
            APIRequest(method: .patch, path: "/tasks/\(id)", body: try encode(body)),
            for: .dashboard,
            as: TodoDTO.self
        )
        try upsert(dto, clearLocalState: true)
        return dto
    }

    /// `DELETE /tasks/{id}` → `204`. Ein bereits serverseitig gelöschter
    /// Eintrag (`404 NOT_FOUND`) wird lokal ebenfalls entfernt.
    func delete(id: String) async throws {
        // Lokal angelegt und nie übertragen: es gibt nichts zu löschen.
        if let item = try item(id: id), item.version == TodoAPI.unsyncedVersion {
            try removeLocal(id: id)
            return
        }

        do {
            _ = try await network.send(
                APIRequest(method: .delete, path: "/tasks/\(id)"),
                for: .dashboard
            )
            try removeLocal(id: id)
        } catch let error as APIError {
            if case .notFound = error {
                try removeLocal(id: id)
                return
            }
            throw error
        }
    }

    /// Merkt eine Löschung offline vor (`pendingDelete`) und blendet den
    /// Eintrag sofort aus. Ein nie angelegter Eintrag wird direkt entfernt.
    func stageDelete(id: String) throws -> TodoDTO? {
        guard let item = try item(id: id) else { return nil }
        if item.version == TodoAPI.unsyncedVersion {
            context.delete(item)
            try context.save()
            return nil
        }
        item.pendingDelete = true
        item.updatedAt = Date()
        try context.save()
        return TodoDTO(item: item)
    }

    // MARK: - Konflikte

    /// „Server behalten“: verwirft die lokale Absicht und übernimmt den
    /// Serverstand. Ist der Eintrag serverseitig weg, verschwindet er lokal.
    func discardLocalChanges(id: String) async throws {
        guard let item = try item(id: id) else { return }
        if let server = try await serverTask(id: id) {
            Self.apply(server, to: item)
            item.isDirty = false
            item.pendingDelete = false
            try context.save()
        } else {
            try removeLocal(id: id)
        }
    }

    /// „Lokal behalten“: sendet den lokalen Stand bewusst gegen die aktuelle
    /// Server-Version. Der Nutzer hat den Konflikt gesehen und entschieden.
    func forceLocal(id: String) async throws -> TodoDTO {
        guard let item = try item(id: id) else {
            throw APIError.notFound
        }
        let server = try await serverTask(id: id)
        return try await update(
            id: id,
            title: item.title,
            details: item.itemDescription,
            status: item.status,
            priority: item.priority,
            dueAt: item.dueAt,
            baseVersion: server?.version ?? item.version
        )
    }

    // MARK: - Warteschlange

    /// Ergebnis eines Abgleichs lokal vorgemerkter Änderungen.
    struct TodoFlushOutcome: Equatable {
        var uploaded = 0
        var conflicts: [String] = []
        var failures: [String] = []
        var isOffline = false
    }

    /// Sendet alle dirty-/pendingDelete-Einträge in der Reihenfolge ihrer
    /// letzten Änderung. Der Abgleich bricht bei fehlender Verbindung ab, damit
    /// die Warteschlange erhalten bleibt und nicht in Fehlerläufe zerfällt.
    func flushPending() async -> TodoFlushOutcome {
        var outcome = TodoFlushOutcome()

        let pending: [TodoItem]
        do {
            pending = try context.fetch(FetchDescriptor<TodoItem>())
                .filter { $0.isDirty || $0.pendingDelete }
                .sorted { $0.updatedAt < $1.updatedAt }
        } catch {
            outcome.failures = ["cache"]
            return outcome
        }

        for item in pending {
            if outcome.isOffline { break }
            do {
                if item.pendingDelete {
                    try await delete(id: item.id)
                    outcome.uploaded += 1
                } else if item.version == TodoAPI.unsyncedVersion {
                    let created = try await create(
                        TodoDraft(
                            title: item.title,
                            details: item.itemDescription,
                            priority: item.priority,
                            dueDate: item.dueAt
                        )
                    )
                    // `POST` legt serverseitig immer `open` an; ein lokal bereits
                    // abgehakter Eintrag braucht danach noch sein PATCH.
                    if item.status == TodoStatus.done.rawValue {
                        _ = try await update(
                            id: created.id,
                            status: TodoStatus.done.rawValue,
                            baseVersion: created.version
                        )
                    }
                    // Aufräumen ist best effort: der Serverdatensatz existiert
                    // bereits, ein Cache-Fehler darf keinen zweiten POST auslösen.
                    try? removeLocal(id: item.id)
                    outcome.uploaded += 1
                } else {
                    _ = try await update(
                        id: item.id,
                        title: item.title,
                        details: item.itemDescription,
                        status: item.status,
                        priority: item.priority,
                        dueAt: item.dueAt,
                        baseVersion: item.version
                    )
                    outcome.uploaded += 1
                }
            } catch let error as APIError {
                if case .conflict = error {
                    outcome.conflicts.append(item.id)
                } else if Self.isConnectivityFailure(error) {
                    outcome.isOffline = true
                } else {
                    if case .notFound = error {
                        try? removeLocal(id: item.id)
                    }
                    outcome.failures.append(item.id)
                }
            } catch {
                outcome.failures.append(item.id)
            }
        }
        return outcome
    }

    /// Anzahl der Einträge, die noch übertragen werden müssen.
    func pendingCount() throws -> Int {
        try context.fetch(FetchDescriptor<TodoItem>())
            .filter { $0.isDirty || $0.pendingDelete }
            .count
    }

    // MARK: - HTTP

    private func requestTasks(
        status: TodoStatusFilter,
        limit: Int
    ) async throws -> [TodoDTO] {
        let query = [
            URLQueryItem(name: "status", value: status.serverStatus),
            URLQueryItem(name: "limit", value: String(limit))
        ]
        return try await network.send(
            APIRequest(method: .get, path: "/tasks", query: query),
            for: .dashboard,
            as: [TodoDTO].self
        )
    }

    private func encode<T: Encodable>(_ body: T) throws -> Data {
        do {
            return try JSONEncoder().encode(body)
        } catch {
            throw APIError.invalidRequest("Payload nicht codierbar: \(error.localizedDescription)")
        }
    }

    /// `true`, wenn der Fehler eher durch fehlende Verbindung als durch eine
    /// Server-Antwort entstanden ist (spec-ios §10, Offline-Pfad).
    static func isConnectivityFailure(_ error: Error) -> Bool {
        guard let apiError = error as? APIError else { return false }
        switch apiError {
        case .offline, .timeout:
            return true
        default:
            return false
        }
    }

    // MARK: - Cache

    /// Reichweite des Aufräumens nach einem Abruf.
    private enum PruneScope {
        /// Kein Aufräumen (z. B. Einzelabruf für den Konfliktdialog).
        case none
        /// Alle sauberen Cache-Einträge, die der Server nicht mehr liefert.
        case all
        /// Nur saubere Einträge dieses Status (gefilterter, vollständiger Abruf).
        case status(String)
    }

    private func merge(_ tasks: [TodoDTO], prune: PruneScope) throws {
        let existing = try context.fetch(FetchDescriptor<TodoItem>())
        var byID: [String: TodoItem] = [:]
        for item in existing {
            byID[item.id] = item
        }

        for dto in tasks {
            if let item = byID[dto.id] {
                // Lokale Absicht nicht still überschreiben (spec-ios §3.1).
                guard !item.isDirty && !item.pendingDelete else { continue }
                Self.apply(dto, to: item)
            } else {
                context.insert(Self.makeItem(from: dto))
            }
        }

        let serverIDs = Set(tasks.map(\.id))
        switch prune {
        case .none:
            break
        case .all:
            for item in existing
                where !serverIDs.contains(item.id) && !item.isDirty && !item.pendingDelete {
                context.delete(item)
            }
        case .status(let status):
            for item in existing
                where item.status == status
                    && !serverIDs.contains(item.id)
                    && !item.isDirty
                    && !item.pendingDelete {
                context.delete(item)
            }
        }
        try context.save()
    }

    private func upsert(_ dto: TodoDTO, clearLocalState: Bool) throws {
        if let existing = try item(id: dto.id) {
            Self.apply(dto, to: existing)
            if clearLocalState {
                existing.isDirty = false
                existing.pendingDelete = false
            }
        } else {
            context.insert(Self.makeItem(from: dto))
        }
        try context.save()
    }

    private func item(id: String) throws -> TodoItem? {
        try context.fetch(FetchDescriptor<TodoItem>()).first { $0.id == id }
    }

    private func removeLocal(id: String) throws {
        guard let item = try item(id: id) else { return }
        context.delete(item)
        try context.save()
    }

    private static func makeItem(from dto: TodoDTO) -> TodoItem {
        TodoItem(
            id: dto.id,
            title: dto.title,
            itemDescription: dto.description ?? "",
            status: dto.status,
            priority: dto.priority,
            source: dto.source,
            dueAt: dto.dueAt,
            completedAt: dto.completedAt,
            version: dto.version,
            updatedAt: Date(),
            isDirty: false,
            pendingDelete: false
        )
    }

    private static func apply(_ dto: TodoDTO, to item: TodoItem) {
        item.title = dto.title
        item.itemDescription = dto.description ?? ""
        item.status = dto.status
        item.priority = dto.priority
        item.source = dto.source
        item.dueAt = dto.dueAt
        item.completedAt = dto.completedAt
        item.version = dto.version
        item.updatedAt = Date()
    }

    /// Formatiert einen bereits normalisierten Kalendertag als `YYYY-MM-DD`.
    private static func apiDay(_ date: Date) -> String {
        TodoFormatting.apiDay.string(from: date)
    }

    private static func clamped(_ limit: Int) -> Int {
        min(max(limit, 1), TodoAPI.maximumLimit)
    }
}

extension TodoDTO {

    /// Projektion eines Cache-Eintrags für die Ansicht.
    init(item: TodoItem) {
        self.init(
            id: item.id,
            title: item.title,
            description: item.itemDescription.isEmpty ? nil : item.itemDescription,
            status: item.status,
            priority: item.priority,
            source: item.source,
            dueAt: item.dueAt,
            completedAt: item.completedAt,
            version: item.version
        )
    }
}
