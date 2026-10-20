//
//  TodoDTO.swift
//  Planer
//
//  Wire-Format des To-Dos-Vertrags (spec-ios §2.2).
//

import Foundation

/// Unveränderliche Vertragsgrenzen aus spec-ios §2.2.
///
/// Zweck: die Werte liegen außerhalb des `@MainActor`-Repositories, damit sie
/// auch in `TodoDTO` und in Default-Argumenten ohne Isolationsbruch lesbar sind.
enum TodoAPI {
    /// Server-Default für `limit`.
    static let defaultLimit = 50
    /// Server-Maximum; ein Abruf ohne Grenze wäre eine DoS-Keule.
    static let maximumLimit = 200
    /// Lokale Marke für noch nicht angelegte To-Dos: Server-Versionen beginnen bei 1.
    static let unsyncedVersion = 0
}

/// Ein To-Do genau in der Form, die `GET/POST/PATCH /api/tasks` liefert.
///
/// Zweck: entkoppelt die Ansicht vom SwiftData-Cache. Felder, Schreibweise und
/// Optionalität spiegeln 1:1 den Vertrag aus spec-ios §2.2 (`due_at`,
/// `completed_at`), damit die Fixture `Tests/Fixtures/tasks.json` und der
/// echte Server dieselbe Struktur haben.
/// Grenze: kein Sync und keine Konfliktauflösung — das leistet `TodoRepository`.
struct TodoDTO: Decodable, Equatable, Identifiable, Sendable {
    let id: String
    let title: String
    let description: String?
    let status: String
    let priority: String
    let source: String
    let dueAt: Date?
    let completedAt: Date?
    let version: Int

    enum CodingKeys: String, CodingKey {
        case id
        case title
        case description
        case status
        case priority
        case source
        case version
        case dueAt = "due_at"
        case completedAt = "completed_at"
    }
}

extension TodoDTO {

    /// `true`, wenn der Eintrag auf dem Server erledigt ist.
    var isDone: Bool { status == TodoStatus.done.rawValue }

    /// Ein lokal angelegter Eintrag, der noch nicht auf dem Server existiert.
    /// Server-Versionen beginnen bei 1; 0 ist deshalb die lokale Marke aus
    /// `TodoAPI.unsyncedVersion` und wird nie an den Server gesendet.
    var isUnsynced: Bool { version == TodoAPI.unsyncedVersion }

    /// Sekundärzeile der Liste: Priorität, Fälligkeit, Herkunft, Sync-Zustand.
    var subtitle: String {
        var parts: [String] = [TodoPriority.label(for: priority)]
        if let dueAt {
            parts.append("fällig \(TodoFormatting.day.string(from: dueAt))")
        }
        if isDone, let completedAt {
            parts.append("erledigt \(TodoFormatting.localDay.string(from: completedAt))")
        }
        parts.append(source == "hermes" ? "Hermes" : "lokal")
        if isUnsynced {
            parts.append("nicht synchronisiert")
        }
        return parts.joined(separator: " · ")
    }
}

/// Status-Werte des Vertrags. `all` ist nur ein Filter, kein Server-Status.
enum TodoStatus: String {
    case open
    case done
}

/// Die drei Segmente des To-Dos-Tabs: `Alle|Heute|Erledigt`
/// (spec-ios §1/I4).
///
/// `Heute` ist kein Server-Filter: `GET /api/tasks` kennt nur
/// `all|open|done` (§2.2). Der Server wird deshalb mit `status=open`
/// abgefragt; die Tagesauswahl passiert clientseitig über `due_at`.
/// Grenze: „Heute“ zeigt offene Einträge mit `due_at` = heutiger Kalendertag.
/// Überfällige und undatierte Einträge bleiben unter „Alle“ sichtbar.
enum TodoStatusFilter: String, CaseIterable, Identifiable {
    case all
    case today
    case done

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all:
            return "Alle"
        case .today:
            return "Heute"
        case .done:
            return "Erledigt"
        }
    }

    /// Statusparameter für `GET /api/tasks?status=…` (§2.2).
    ///
    /// `today` wird als `open` geladen und danach über `due_at` eingeengt.
    /// Ein nicht unterstützter Wert darf nie an den Server gehen.
    var serverStatus: String {
        switch self {
        case .all:
            return "all"
        case .today:
            return TodoStatus.open.rawValue
        case .done:
            return TodoStatus.done.rawValue
        }
    }

    /// `true`, wenn ein Cache-Eintrag in dieses Segment gehört.
    ///
    /// Die Tagesauswahl liegt bewusst hier und nicht im Repository, damit
    /// „Heute“ an genau einer Stelle definiert ist: offen **und** `due_at`
    /// auf dem heutigen lokalen Kalendertag.
    func includes(
        itemStatus: String,
        dueAt: Date?,
        isPendingDelete: Bool,
        now: Date = Date()
    ) -> Bool {
        guard !isPendingDelete else { return false }

        switch self {
        case .all:
            return true
        case .today:
            guard itemStatus == TodoStatus.open.rawValue, let dueAt else {
                return false
            }
            return TodoFormatting.isDueToday(dueAt, now: now)
        case .done:
            return itemStatus == TodoStatus.done.rawValue
        }
    }
}

/// Prioritäten des Vertrags mit deutscher Anzeige.
enum TodoPriority: String, CaseIterable, Identifiable {
    case low
    case normal
    case high

    var id: String { rawValue }

    var label: String {
        switch self {
        case .low:
            return "Niedrig"
        case .normal:
            return "Normal"
        case .high:
            return "Hoch"
        }
    }

    static func label(for rawValue: String) -> String {
        TodoPriority(rawValue: rawValue)?.label ?? rawValue
    }

    /// Sortierrang: hohe Priorität zuerst.
    var rank: Int {
        switch self {
        case .high:
            return 0
        case .normal:
            return 1
        case .low:
            return 2
        }
    }
}

/// Eingabe des Anlege-Formulars; noch kein Serverobjekt.
struct TodoDraft: Equatable {
    var title: String = ""
    var details: String = ""
    var priority: String = TodoPriority.normal.rawValue
    var dueDate: Date?

    var trimmedTitle: String {
        title.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Titel 1…200 Zeichen; die Grenze stammt aus `TaskCreate` des Backends.
    var isValid: Bool {
        !trimmedTitle.isEmpty && trimmedTitle.count <= 200
    }
}

/// Datumsformate des Vertrags und der Anzeige.
///
/// `due_at` ist ein reines Kalenderdatum. Es wird durchgehend als UTC-Mitternacht
/// gespeichert, damit Server-Rundreise und Anzeige denselben Tag ergeben.
enum TodoFormatting {

    /// `YYYY-MM-DD` für Request-Bodies (Backend-Muster `^\d{4}-\d{2}-\d{2}$`).
    static let apiDay: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    /// Anzeige eines Kalendertags (`due_at`) in UTC.
    static let day: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "de_DE")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "dd.MM.yyyy"
        return formatter
    }()

    /// Anzeige eines Zeitpunkts (`completed_at`) in der Gerätezeitzone.
    static let localDay: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "de_DE")
        formatter.timeZone = .current
        formatter.dateFormat = "dd.MM.yyyy"
        return formatter
    }()

    /// Wandelt die Tag-Komponenten einer lokalen `Date` in UTC-Mitternacht,
    /// ohne den Tag durch eine Zeitzonenverschiebung zu wechseln.
    static func normalizedDay(_ date: Date) -> Date {
        let components = Calendar.current.dateComponents([.year, .month, .day], from: date)
        var utcCalendar = Calendar(identifier: .gregorian)
        utcCalendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .current
        return utcCalendar.date(from: components) ?? date
    }

    /// `true`, wenn `date` auf denselben lokalen Kalendertag fällt wie `now`.
    ///
    /// `due_at` liegt als UTC-Mitternacht des gewählten Tags vor. Der Vergleich
    /// bildet deshalb zuerst den lokalen Tag von `now` über `normalizedDay` auf
    /// UTC-Mitternacht ab — sonst würde ein Eintrag am Abend je nach
    /// Zeitzonenversatz einen Tag daneben liegen.
    static func isDueToday(_ date: Date, now: Date = Date()) -> Bool {
        var utcCalendar = Calendar(identifier: .gregorian)
        utcCalendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .current
        return utcCalendar.isDate(date, inSameDayAs: normalizedDay(now))
    }
}

/// Body für `POST /api/tasks` (spec-ios §2.2).
struct TodoCreateBody: Encodable {
    let title: String
    let description: String
    let priority: String
    let dueAt: String?

    enum CodingKeys: String, CodingKey {
        case title
        case description
        case priority
        case dueAt = "due_at"
    }
}

/// Body für `PATCH /api/tasks/{id}` (spec-ios §2.2).
///
/// Nur gesetzte Felder werden codiert; `base_version` ist die optimistische
/// Sperre. Fehlt sie, überschreibt das Backend bedingungslos — die App sendet
/// sie deshalb bei jeder Nutzer-Mutation.
struct TodoUpdateBody: Encodable {
    let title: String?
    let description: String?
    let status: String?
    let priority: String?
    let dueAt: String?
    let baseVersion: Int?

    enum CodingKeys: String, CodingKey {
        case title
        case description
        case status
        case priority
        case dueAt = "due_at"
        case baseVersion = "base_version"
    }
}
