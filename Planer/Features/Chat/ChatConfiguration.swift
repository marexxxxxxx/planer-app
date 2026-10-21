//
//  ChatConfiguration.swift
//  Planer
//
//  Werte des Hermes-Chats an einer Stelle (spec-chat Rev 4 §5.6).
//

import Foundation

/// Alle Pfade, Zeitlimits, Seitengrößen und Textgrenzen des Chat-Tabs.
///
/// Zweck: keine Magic Numbers im Ablauf; ein Wert ändert sich an genau einer
/// Stelle.
/// Grenze: reine Werte und **eine** Prüffunktion. Die Basis-URL selbst wird
/// weiterhin ausschließlich aus der Keychain gelesen (`ServiceConfiguration`).
struct HermesChatConfiguration: Sendable {

    // MARK: Pfade und Protokoll

    var chatPath = "/v1/chat/completions"
    var sessionsPath = "/api/sessions"
    var approvalPath = "/v1/runs/%@/approval"
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

    /// REST-Aufrufe (Liste, Nachrichten, Anlegen, Freigabe).
    var restTimeout: TimeInterval = 15
    /// Untätigkeits-Timeout des Stroms; größer als der Server-Freigabe-Timeout
    /// von 300 s, damit eine legitime Freigabe nicht abgeschnitten wird.
    var streamIdleTimeout: TimeInterval = 600
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

/// Fehler der Chat-Konfiguration; nennt den abgelehnten Pfad wörtlich (F22).
enum HermesChatConfigurationError: Error, Equatable, LocalizedError {
    case baseURLHasPath(String)

    var errorDescription: String? {
        switch self {
        case .baseURLHasPath(let path):
            return "Die Hermes-Basis-URL enthält einen Pfad (\(path)). Bitte in den Einstellungen nur den Origin eintragen, z. B. http://127.0.0.1:8642."
        }
    }
}
