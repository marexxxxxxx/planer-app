//
//  ChatConfiguration.swift
//  Planer
//
//  Werte des Hermes-Chats an einer Stelle (spec-chat Rev 6 §4.2).
//

import Foundation

/// Alle Pfade, Zeitlimits, Seitengrößen und Textgrenzen des Chat-Tabs.
///
/// Zweck: keine Magic Numbers im Ablauf; ein Wert ändert sich an genau einer
/// Stelle. Die drei Nutzerwerte (Profil, Stream-Timeout, REST-Timeout) setzt
/// `ChatPreferences`; hier stehen nur ihre Grenzen und Defaults.
/// Grenze: reine Werte und **eine** Prüffunktion. Die Basis-URL selbst wird
/// weiterhin ausschließlich aus der Keychain gelesen (`ServiceConfiguration`).
struct HermesChatConfiguration: Sendable, Equatable {

    // MARK: Profil und Pfade

    /// Hermes-Profil als Pfad-Präfix `/p/<profil>`; `""` = Default-Profil ohne
    /// Präfix (Rev 6 O7).
    var profile: String = ""

    /// Die Pfade sind **berechnet**, damit das Präfix an keiner Stelle
    /// vergessen werden kann. `urlSession`/`NetworkClient` kennen kein Profil.
    var chatPath: String { scoped("/v1/chat/completions") }
    var sessionsPath: String { scoped("/api/sessions") }
    var approvalPath: String { scoped("/v1/runs/%@/approval") }
    var healthPath: String { scoped("/health") }
    var sessionHeader = "X-Hermes-Session-Id"
    /// Source-Tag **beim Anlegen** einer Sitzung; die Verlaufsliste filtert
    /// nicht mehr danach (MARAAA-155).
    var sessionSource = "desktop"
    /// Interne Quellen, die keine Unterhaltung des Nutzers sind und deshalb
    /// nicht im Verlauf erscheinen. Alle anderen Quellen — auch unbekannte —
    /// bleiben sichtbar (MARAAA-155).
    var hiddenSessionSources: Set<String> = ["cron", "subagent"]
    var eventStreamContentType = "text/event-stream"

    // MARK: Zeit und Seiten

    /// REST-Aufrufe (Liste, Nachrichten, Anlegen, Freigabe). Default und
    /// Grenzen kommen aus `ChatPreferences` (Rev 6 O1).
    var restTimeout: TimeInterval = 30
    /// Untätigkeits-Timeout des Stroms; größer als der Server-Freigabe-Timeout
    /// von 300 s, damit eine legitime Freigabe nicht abgeschnitten wird.
    var streamIdleTimeout: TimeInterval = 900
    /// Server-Deckel für die Verlaufsliste ist 200.
    var sessionPageSize = 50
    /// Server-Deckel für Nachrichten ist 500.
    var messagePageSize = 100
    /// 5 × 100 = 500 geladene Nachrichten (Server-Deckel).
    var maxMessagePages = 5

    // MARK: Textgrenzen

    var maxDraftCharacters = 4_000
    var maxTextCharacters = 24_000
    var maxReasoningCharacters = 20_000
    var maxToolDetailCharacters = 4_000
    var maxPreviewCharacters = 80
    var maxNoticeCharacters = 300

    // MARK: Profil-Präfix

    /// Stellt bei gesetztem Profil `/p/<profil>` voran; bei leerem Profil
    /// bleibt der Pfad unverändert. Die **einzige** Stelle, an der das
    /// Profil in einen Pfad übergeht (Rev 6 O7).
    func scoped(_ path: String) -> String {
        guard !profile.isEmpty else { return path }
        let encoded = profile.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? profile
        return "/p/" + encoded + (path.hasPrefix("/") ? path : "/" + path)
    }

    // MARK: Verlaufs-Sichtbarkeit

    /// `true`, wenn eine Sitzung dieser Quelle in der Verlaufsliste erscheinen
    /// darf.
    ///
    /// Die **einzige** Stelle, an der die Sichtbarkeit einer Quelle entschieden
    /// wird. Grenze: reine Prüfung; unbekannte Quellen bleiben sichtbar, damit
    /// ein neuer Server-Wert nicht stillschweigend verschwindet.
    func showsSessionSource(_ source: String) -> Bool {
        !hiddenSessionSources.contains(source)
    }

    // MARK: Basis-URL

    /// Der **einzige** Ort, an dem die Basis-URL gegen einen Pfad geprüft wird.
    ///
    /// `NetworkClient.makeURLRequest` hängt `request.path` an den Pfad der
    /// Basis-URL an: aus `https://host/mcp` plus `/api/sessions` würde
    /// `/mcp/api/sessions` und damit ein `404`. Erlaubt sind deshalb nur `""`
    /// und `"/"`; jeder andere Pfad wird vor dem ersten Request abgelehnt.
    /// Grenze: keine Normalisierung und kein stilles Abschneiden — der
    /// gespeicherte Wert bleibt unverändert.
    static func validateBaseURL(path: String?) throws {
        let value = path ?? ""
        guard value.isEmpty || value == "/" else {
            throw HermesChatConfigurationError.baseURLHasPath(value)
        }
    }
}

/// Fehler der Chat-Konfiguration; nennt den abgelehnten Pfad wörtlich (F22)
/// bzw. das nicht ausgelieferte Profil (Rev 6 F-R6-4).
enum HermesChatConfigurationError: Error, Equatable, LocalizedError {
    case baseURLHasPath(String)
    case profileNotServed(String)

    var errorDescription: String? {
        switch self {
        case .baseURLHasPath(let path):
            return "Die Hermes-Basis-URL enthält einen Pfad (\(path)). Bitte in den Einstellungen nur den Origin eintragen, z. B. http://127.0.0.1:8642."
        case .profileNotServed(let name):
            return "Das Hermes-Profil „\(name)“ wird von diesem Server nicht ausgeliefert. Schritt auf dem Server: hermes gateway migrate --multiplex (danach das Gateway neu starten)."
        }
    }
}
