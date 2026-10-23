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
    /// Untätigkeits-Timeout des Stroms; größer als der Server-Freigabe-Timeout,
    /// damit eine legitime Freigabe nicht abgeschnitten wird.
    var streamIdleTimeout: TimeInterval = 900
    /// Schonfrist nach der Rückkehr aus dem Hintergrund (Rev 9, MARAAA-188):
    /// so lange darf ein Strom ohne ein einziges Lebenszeichen still sein,
    /// bevor er als tot gilt und der Serverstand nachgeladen wird.
    ///
    /// Zweck: ein von der Suspension getöteter Strom liefert **nie** einen
    /// Fehler — sein Request lebt bis `streamIdleTimeout` (900 s) weiter. Ohne
    /// Frist bliebe `isStreaming` true und der Composer gesperrt, bis der
    /// Prozess neu startet. Grenze: die Frist ist keine Turn-Grenze; ein
    /// Strom, der seit der Rückkehr ein Lebenszeichen geliefert hat, bleibt
    /// unangetastet (E15).
    ///
    /// Herleitung (Entscheidung MARAAA-193): Hermes
    /// sendet auf `POST /v1/chat/completions` alle 10 s ein SSE-Keepalive
    /// (`CHAT_COMPLETIONS_SSE_KEEPALIVE_SECONDS = 10.0`). Zwei verpasste
    /// Keepalives sind 2 × (10 s + 0,5 s Poll) = 21 s; dazu 4 s Reserve für
    /// iOS-Aufwachen und URLSession-Puffer ergibt 25 s. Die früheren 12 s
    /// lagen nur 1,5 s über dem Worst Case und konnten einen gesunden Strom
    /// abreißen.
    var backgroundResumeGracePeriod: TimeInterval = 25
    /// Obergrenze des Wartens auf das Ende eines technisch abgebrochenen
    /// Stroms (Rev 9, MARAAA-188).
    ///
    /// Zweck: der Turn-Zustand wird danach hart geschlossen, damit ein
    /// hängender Task den Composer nicht sperrt. Grenze: keine Erfolgsprüfung
    /// — nach dieser Zeit ist der Task abgebrochen und liefert nichts mehr,
    /// was die Oberfläche zeigen dürfte.
    var streamStopWaitLimit: TimeInterval = 3
    /// Schrittweite der Prüfung „ist der Strom schon zu Ende?“ innerhalb von
    /// `streamStopWaitLimit`. Klein genug, dass ein normaler Abbruch sofort
    /// erkannt wird, groß genug, dass die Schleife den Main-Actor nicht
    /// blockiert.
    var streamStopPollInterval: TimeInterval = 0.2
    /// Server-Deckel für die Verlaufsliste ist 200.
    var sessionPageSize = 50
    /// Server-Deckel für Nachrichten ist 500.
    var messagePageSize = 100
    /// 5 × 100 = 500 geladene Nachrichten (Server-Deckel).
    var maxMessagePages = 5

    // MARK: Live-Abgleich (spec-chat-live-activity §5.2)

    /// Takt des Verlaufsabgleichs, solange ein Werkzeug läuft.
    ///
    /// Zweck: kleiner als der Server-Keepalive (10 s), damit eine Karte ihren
    /// Inhalt merkbar früher zeigt als das nächste Lebenszeichen; groß genug,
    /// dass ein 60-s-Werkzeuglauf 20 Anfragen kostet. Grenze: der Abgleich
    /// läuft nur zwischen dem ersten Werkzeug-Frame und dem Turn-Ende.
    var liveActivityPollInterval: TimeInterval = 3
    /// Ein Aussetzer ist normal (das Gerät wechselt das Netz), zwei in Folge
    /// sind ein Zustand — dann endet der Abgleich (§5.2).
    var liveActivityMaxConsecutiveFailures = 2
    /// Deckel des Abgleichs: 200 × 3 s = 10 min, kürzer als
    /// `streamIdleTimeout` und länger als jeder gemessene Werkzeuglauf (§5.2).
    var liveActivityMaxPolls = 200
    /// Eine Seite des Abgleichs; deckt einen Turn mit vielen Werkzeugrunden
    /// (§5.2). Bewusst derselbe Wert wie die Verlaufsseite des Merges.
    var liveActivityPageSize: Int { messagePageSize }

    /// Frist einer Server-Freigabe, gespiegelt vom Server-Default
    /// (`approvals.timeout`, `gateway/run.py:4071`). Die App zeigt sie an und
    /// sendet nach ihrem Ablauf nichts mehr — die Wahrheit bleibt der Server.
    var approvalTimeout: TimeInterval = 300

    // MARK: Dauer der Antwort

    /// Kürzeste angezeigte Erzeugungsdauer. Darunter erscheint keine Zeitzeile
    /// (0 s ist keine Information). Nur die Anzeige — der Feldwert bleibt roh.
    var minVisibleGenerationDuration: TimeInterval = 1
    /// Obergrenze einer plausiblen Dauer (24 h). Ein größerer Wert deutet auf
    /// eine geänderte Einheit (z. B. Millisekunden) und wird verworfen statt
    /// angezeigt.
    var maxVisibleGenerationDuration: TimeInterval = 86_400

    // MARK: Stromgrenzen

    /// Obergrenze eines einzelnen SSE-Ereignisses in Zeichen (Rev 9,
    /// MARAAA-188) — der **einzige** Wert dieser Grenze im Baum.
    ///
    /// Zweck: ein einzelnes riesiges Server-Ereignis (z. B. ein großes
    /// Werkzeug-Ergebnis im Status-Ereignis) darf den Turn nicht beenden. Die
    /// Oberfläche kappt Text ohnehin (`maxToolDetailCharacters`/
    /// `maxTextCharacters`). Grenze: das Ereignis wird **verworfen**, nicht
    /// gekürzt, und der Puffer wächst nie über diesen Wert.
    var maxStreamEventCharacters = 262_144

    // MARK: Textgrenzen

    var maxDraftCharacters = 4_000
    var maxTextCharacters = 24_000
    var maxReasoningCharacters = 20_000
    var maxToolDetailCharacters = 4_000
    var maxPreviewCharacters = 80
    var maxNoticeCharacters = 300
    /// Obergrenze für einen Befehl, der noch geprüft freigegeben werden kann.
    /// Darüber zeigt die Karte nur „Ablehnen“ (FF-4): wer den Befehl nicht
    /// lesen kann, darf ihn nicht autorisieren.
    var maxCommandCharacters = 12_000

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
