//
//  TodosViewModel.swift
//  Planer
//
//  Zustand und Abläufe des To-Dos-Tabs (spec-ios §1/I4, §2.2, §3.1).
//

import Combine
import Foundation
import SwiftData

/// Ein offener Versionskonflikt: lokaler Stand gegen Serverstand.
struct TodoConflict: Identifiable, Equatable {
    let id: String
    let local: TodoDTO
    let server: TodoDTO

    var message: String {
        "Server: „\(server.title)“ (Version \(server.version))\n"
            + "Lokal: „\(local.title)“ (Basis \(local.version))"
    }
}

/// Vermittelt zwischen `TodosView` und `TodoRepository`.
///
/// Zweck: Filter, Laden, Anlegen, Abhaken, Löschen, Offline-Warteschlange und
/// Konfliktdialog an einer Stelle. Die View bleibt deklarativ.
/// Grenze: keine Netzwerk- oder Cache-Details; die liegen im Repository.
final class TodosViewModel: ObservableObject {

    @Published private(set) var tasks: [TodoDTO] = []
    @Published private(set) var filter: TodoStatusFilter = .all
    @Published private(set) var isLoading = false
    /// `true`, solange die Liste aus dem Cache statt vom Server kommt.
    @Published private(set) var isUsingCache = false
    /// Einzeiliger Hinweis (Fehler, Offline, Konflikt); `nil` = kein Hinweis.
    @Published private(set) var banner: String?
    @Published private(set) var conflict: TodoConflict?
    @Published private(set) var pendingCount = 0

    private var repository: TodoRepository?
    private var hasStarted = false
    private let limit = TodoAPI.maximumLimit

    // MARK: - Lebenszyklus

    /// Bindet den SwiftData-Context und lädt einmalig.
    @MainActor
    func start(context: ModelContext) async {
        if repository == nil {
            repository = TodoRepository(context: context)
        }
        guard !hasStarted else { return }
        hasStarted = true
        await refresh()
    }

    // MARK: - Laden und Filtern

    @MainActor
    func refresh() async {
        guard let repository else { return }
        isLoading = true
        defer { isLoading = false }

        // Erst lokal Vorgemerktes übertragen, dann den Serverstand laden.
        let outcome = await repository.flushPending()
        updatePendingCount()

        do {
            let loaded = try await repository.fetch(status: filter, limit: limit)
            tasks = sorted(loaded)
            isUsingCache = false
            await apply(outcome)
        } catch let error as APIError where TodoRepository.isConnectivityFailure(error) {
            tasks = sorted((try? repository.cached(status: filter, limit: limit)) ?? [])
            isUsingCache = true
            banner = "Offline — zeige den zuletzt geladenen Stand. Änderungen werden vorgemerkt."
        } catch {
            // spec-ios §10: auch bei 5xx/Timeout bleibt der lokale Cache sichtbar.
            let fallback = (try? repository.cached(status: filter, limit: limit)) ?? []
            tasks = sorted(fallback)
            isUsingCache = !fallback.isEmpty
            banner = message(for: error)
        }
    }

    /// Wechselt das Segment `Alle|Heute|Erledigt` (spec-ios §1/I4) und lädt
    /// neu. `Heute` wird serverseitig als `open` geladen und clientseitig über
    /// `due_at` eingeengt.
    @MainActor
    func setFilter(_ newValue: TodoStatusFilter) async {
        guard newValue != filter else { return }
        filter = newValue
        await refresh()
    }

    // MARK: - Anlegen

    /// Legt ein To-Do an. Rückgabe `nil` = Erfolg, sonst die Fehlermeldung
    /// für das Formular. Offline wird lokal vorgemerkt und gilt als Erfolg.
    @MainActor
    func create(_ draft: TodoDraft) async -> String? {
        guard draft.isValid else {
            return "Der Titel muss 1 bis 200 Zeichen haben."
        }
        guard let repository else {
            return "Der Cache ist noch nicht bereit."
        }

        do {
            let dto = try await repository.create(draft)
            tasks = replacingVisible(dto)
            banner = nil
            isUsingCache = false
            updatePendingCount()
            return nil
        } catch let error as APIError where TodoRepository.isConnectivityFailure(error) {
            do {
                let dto = try repository.stageCreate(draft)
                tasks = replacingVisible(dto)
                isUsingCache = true
                updatePendingCount()
                banner = "Offline gespeichert — das To-Do wird beim nächsten Abgleich übertragen."
                return nil
            } catch {
                return message(for: error)
            }
        } catch {
            return message(for: error)
        }
    }

    // MARK: - Ändern und Löschen

    /// Hakt einen Eintrag ab bzw. macht ihn wieder offen. Gesendet wird die
    /// `base_version`, die zuletzt vom Server kam (optimistische Sperre).
    @MainActor
    func toggle(_ task: TodoDTO) async {
        guard let repository else { return }
        let nextStatus = task.isDone ? TodoStatus.open.rawValue : TodoStatus.done.rawValue

        do {
            let dto = try await repository.update(
                id: task.id,
                status: nextStatus,
                baseVersion: task.version
            )
            tasks = replacingVisible(dto)
            banner = nil
            isUsingCache = false
            updatePendingCount()
        } catch let error as APIError {
            await handle(error, for: task)
        } catch {
            banner = message(for: error)
        }
    }

    /// Löscht einen Eintrag. Offline wird die Löschung vorgemerkt und der
    /// Eintrag sofort ausgeblendet (`pendingDelete`).
    @MainActor
    func delete(_ task: TodoDTO) async {
        guard let repository else { return }

        do {
            try await repository.delete(id: task.id)
            tasks.removeAll { $0.id == task.id }
            banner = nil
            updatePendingCount()
        } catch let error as APIError where TodoRepository.isConnectivityFailure(error) {
            do {
                _ = try repository.stageDelete(id: task.id)
                tasks.removeAll { $0.id == task.id }
                isUsingCache = true
                updatePendingCount()
                banner = "Offline gelöscht — der Eintrag wird beim nächsten Abgleich entfernt."
            } catch {
                banner = message(for: error)
            }
        } catch let error as APIError {
            if case .notFound = error {
                tasks.removeAll { $0.id == task.id }
                banner = "Der Eintrag existiert nicht mehr — aus der Liste entfernt."
            } else {
                banner = message(for: error)
            }
        } catch {
            banner = message(for: error)
        }
    }

    // MARK: - Konflikte

    /// „Server behalten“. Der Konflikt kommt als Parameter, weil die View den
    /// Zustand beim Schließen des Alerts bereits zurückgesetzt hat.
    ///
    /// Bei einem Fehler bleibt der Alert geschlossen und der Grund steht als
    /// Banner in der Liste — der Dialog öffnet sich nicht von selbst erneut.
    @MainActor
    func resolveConflictKeepingServer(_ conflict: TodoConflict) async {
        guard let repository else {
            banner = "Der Cache ist noch nicht bereit."
            return
        }
        self.conflict = nil
        do {
            try await repository.discardLocalChanges(id: conflict.id)
            await reloadFromCache()
            updatePendingCount()
            banner = "Serverstand übernommen."
        } catch {
            banner = "Konflikt nicht aufgelöst — \(message(for: error)). "
                + "Beim nächsten Abgleich wird es erneut versucht."
        }
    }

    /// „Lokal behalten“. Meldet der Server erneut `409`, hat sich sein Stand
    /// während der Entscheidung geändert; dann wird bewusst ein neuer
    /// Konfliktdialog aufgebaut. Jeder andere Fehler endet als Banner, nicht
    /// als wiederkehrender Alert.
    @MainActor
    func resolveConflictKeepingLocal(_ conflict: TodoConflict) async {
        guard let repository else {
            banner = "Der Cache ist noch nicht bereit."
            return
        }
        self.conflict = nil
        do {
            let dto = try await repository.forceLocal(id: conflict.id)
            tasks = replacingVisible(dto)
            banner = "Lokaler Stand übernommen."
            updatePendingCount()
        } catch let error as APIError {
            if case .conflict = error {
                await presentConflict(id: conflict.id)
            } else {
                banner = "Konflikt nicht aufgelöst — \(message(for: error))."
            }
        } catch {
            banner = "Konflikt nicht aufgelöst — \(message(for: error))."
        }
    }

    func dismissConflict() {
        conflict = nil
    }

    // MARK: - Hinweise

    func dismissBanner() {
        banner = nil
    }

    // MARK: - Intern

    @MainActor
    private func handle(_ error: APIError, for task: TodoDTO) async {
        switch error {
        case .conflict:
            await presentConflict(id: task.id)
        case .notFound:
            tasks.removeAll { $0.id == task.id }
            banner = "Der Eintrag existiert nicht mehr — aus der Liste entfernt."
            updatePendingCount()
        case .validation:
            // Die lokale Änderung ist ungültig. Sie wird **nicht** automatisch
            // verworfen: Verwerfen ist allein die Entscheidung des Nutzers
            // („Server behalten“ im Konfliktdialog, spec-ios §3.1).
            banner = message(for: error)
        default:
            if TodoRepository.isConnectivityFailure(error) {
                isUsingCache = true
                updatePendingCount()
                banner = "Offline — die Änderung ist vorgemerkt und wird später übertragen."
            } else {
                banner = message(for: error)
            }
        }
    }

    /// Lädt Serverstand und lokalen Stand für den Konfliktdialog.
    @MainActor
    private func presentConflict(id: String) async {
        guard let repository else { return }
        do {
            switch try await repository.serverTask(id: id) {
            case .found(let server):
                let cachedLocal: TodoDTO? = (try? repository.cached(status: .all, limit: limit))?
                    .first(where: { $0.id == id })
                guard let local = cachedLocal ?? tasks.first(where: { $0.id == id }) else {
                    banner = "Konflikt erkannt, aber der lokale Stand ist nicht lesbar."
                    return
                }
                conflict = TodoConflict(id: id, local: local, server: server)
                banner = nil
            case .absent:
                tasks.removeAll { $0.id == id }
                banner = "Der Eintrag existiert nicht mehr — der Konflikt hat sich erledigt."
                updatePendingCount()
            case .unknown:
                // Der Einzelabruf war gekappt: die Abwesenheit ist nicht belegt,
                // der Eintrag bleibt stehen und der Konflikt wird gemeldet.
                banner = "Konflikt erkannt, aber der Serverstand ist nicht vollständig "
                    + "lesbar. Der Eintrag bleibt erhalten."
            }
        } catch {
            banner = message(for: error)
        }
    }

    @MainActor
    private func apply(_ outcome: TodoRepository.TodoFlushOutcome) async {
        if outcome.isOffline {
            // Der GET hat funktioniert, nur die Warteschlange kam nicht durch:
            // die Liste ist frisch, die Änderungen bleiben vorgemerkt.
            banner = "Änderungen sind noch nicht übertragen — der nächste Abgleich versucht es erneut."
        } else if let id = outcome.conflicts.first {
            banner = "Es gibt einen Versionskonflikt. Bitte entscheiden, welcher Stand gilt."
            await presentConflict(id: id)
        } else if !outcome.failures.isEmpty {
            banner = "\(outcome.failures.count) Änderung(en) konnten nicht übertragen werden."
        } else if outcome.uploaded > 0 {
            banner = nil
        }
    }

    @MainActor
    private func reloadFromCache() async {
        guard let repository else { return }
        tasks = sorted((try? repository.cached(status: filter, limit: limit)) ?? [])
    }

    @MainActor
    private func updatePendingCount() {
        guard let repository else {
            pendingCount = 0
            return
        }
        pendingCount = (try? repository.pendingCount()) ?? pendingCount
    }

    /// Ersetzt einen Eintrag und entfernt ihn, wenn er nicht mehr in das
    /// aktuelle Segment gehört — etwa ein To-Do, das unter „Heute“ abgehakt
    /// wird, oder ein neu angelegtes To-Do im Segment „Erledigt“.
    private func replacingVisible(_ dto: TodoDTO) -> [TodoDTO] {
        var next = tasks.filter { $0.id != dto.id }
        let visible = filter.includes(
            itemStatus: dto.status,
            dueAt: dto.dueAt,
            isPendingDelete: false
        )
        if visible {
            next.append(dto)
        }
        return sorted(next)
    }

    private func sorted(_ values: [TodoDTO]) -> [TodoDTO] {
        values.sorted(by: Self.orderedBefore)
    }

    /// Offene zuerst; darunter nach Fälligkeit, Priorität und Titel.
    /// Erledigte nach Erledigt-Zeitpunkt absteigend.
    private static func orderedBefore(_ lhs: TodoDTO, _ rhs: TodoDTO) -> Bool {
        if lhs.isDone != rhs.isDone {
            return !lhs.isDone
        }
        if lhs.isDone {
            let lhsDate = lhs.completedAt ?? .distantPast
            let rhsDate = rhs.completedAt ?? .distantPast
            if lhsDate != rhsDate { return lhsDate > rhsDate }
            return lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
        }

        switch (lhs.dueAt, rhs.dueAt) {
        case let (left?, right?):
            if left != right { return left < right }
        case (nil, _?):
            return false
        case (_?, nil):
            return true
        case (nil, nil):
            break
        }

        let lhsRank = TodoPriority(rawValue: lhs.priority)?.rank ?? 3
        let rhsRank = TodoPriority(rawValue: rhs.priority)?.rank ?? 3
        if lhsRank != rhsRank { return lhsRank < rhsRank }
        return lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
    }

    private func message(for error: Error) -> String {
        if let apiError = error as? APIError {
            return apiError.localizedDescription
        }
        return error.localizedDescription
    }
}
