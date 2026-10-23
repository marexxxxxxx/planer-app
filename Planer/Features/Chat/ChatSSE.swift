//
//  ChatSSE.swift
//  Planer
//
//  Zerlegung von `text/event-stream` und gemeinsame HTTP-Helfer des Chats
//  (spec-chat Rev 4 §6.1).
//

import Foundation

/// Ein ausgewertetes Server-Sent-Event.
struct ServerSentEvent: Equatable, Sendable {
    let id: String?
    let event: String?
    let data: String
}

/// Zerlegt einen `text/event-stream` zeilenweise in Ereignisse.
///
/// Zweck: der Chat liest den Strom an genau einer Stelle; die Zerlegung
/// existiert deshalb nur einmal.
/// Grenze: verarbeitet nur `data`, `event` und `id`; `retry` und Kommentare
/// werden ignoriert. Ein Ereignis über dem Zeichenlimit wird **verworfen** —
/// es beendet den Turn nicht (Rev 9, MARAAA-188): ein einzelnes zu großes
/// Server-Ereignis ist kein Protokollbruch, und die Oberfläche kappt Text
/// ohnehin. Der Puffer bleibt dabei bounded, weil nach dem Überschreiten keine
/// weitere `data`-Zeile aufgenommen wird.
struct ServerSentEventDecoder {
    private var dataLines: [String] = []
    private var eventName: String?
    private var lastIdentifier: String?
    private var bufferedCharacters = 0
    /// `true` = das laufende Ereignis hat das Limit überschritten. Es wird bis
    /// zu seiner Leerzeile verworfen und nicht mehr gepuffert.
    private var discardsCurrentEvent = false
    private let maxCharacters: Int

    init(maxCharacters: Int = HermesChatConfiguration().maxStreamEventCharacters) {
        self.maxCharacters = max(1_024, maxCharacters)
    }

    /// Füttert eine Zeile; liefert ein Ereignis, sobald eine Leerzeile es beendet.
    ///
    /// Grenze: ein verworfenes Ereignis liefert `nil` — der Aufrufer liest
    /// weiter, statt den Turn abzubrechen.
    mutating func consume(line: String) -> ServerSentEvent? {
        if line.isEmpty {
            defer { resetEvent() }
            guard !dataLines.isEmpty || discardsCurrentEvent else {
                return nil
            }
            // Ein zu großes Ereignis wird nicht halb ausgeliefert.
            guard !discardsCurrentEvent else { return nil }
            return ServerSentEvent(
                id: lastIdentifier,
                event: eventName,
                data: dataLines.joined(separator: "\n")
            )
        }

        // Zeilen mit ":" sind Kommentare/Keepalives.
        if line.hasPrefix(":") {
            return nil
        }

        let field: String
        let value: String
        if let separator = line.firstIndex(of: ":") {
            field = String(line[line.startIndex..<separator])
            var remainder = line[line.index(after: separator)...]
            if remainder.hasPrefix(" ") {
                remainder = remainder.dropFirst()
            }
            value = String(remainder)
        } else {
            field = line
            value = ""
        }

        switch field {
        case "data":
            guard !discardsCurrentEvent else { return nil }
            let nextCharacters = bufferedCharacters + value.count
            guard nextCharacters <= maxCharacters else {
                // Grenze erreicht: Ereignis verwerfen und den Puffer freigeben.
                // Die Meldung ist bewusst kein Fehler — der Strom läuft weiter.
                discardsCurrentEvent = true
                dataLines.removeAll(keepingCapacity: false)
                bufferedCharacters = 0
                return nil
            }
            dataLines.append(value)
            bufferedCharacters = nextCharacters
        case "event":
            eventName = value
        case "id":
            // SSE-Vertrag (Rev 9, MARAAA-188): auch ein **leerer** Wert ist
            // eine Zuweisung. `id:` — oder `id` ohne Doppelpunkt — setzt die
            // zuletzt gesehene ID deshalb auf "" zurück, statt die alte ID
            // weiterzuführen. Die Zuweisung bleibt bedingungslos; eine
            // Bedingung auf den Wert wäre der Bruch des Vertrags.
            lastIdentifier = value
        default:
            break
        }
        return nil
    }

    /// Setzt den Zustand **eines** Ereignisses zurück; die zuletzt gesehene
    /// `id` bleibt erhalten (SSE-Vertrag: sie gilt über Ereignisse hinweg).
    private mutating func resetEvent() {
        dataLines.removeAll(keepingCapacity: true)
        eventName = nil
        bufferedCharacters = 0
        discardsCurrentEvent = false
    }
}

/// Gemeinsame HTTP-Helfer des Chat-Features.
///
/// Zweck: Antwortströme begrenzt lesen und SSE-Antworten erkennen — einmal statt
/// im Anbieter und in der API doppelt.
/// Grenze: **keine Authentifizierung, kein Request-Aufbau.** Header setzt
/// ausschließlich `NetworkClient.injectHeaders`; der Chat bezieht seinen
/// Request deshalb über `NetworkClient.stream`.
enum HermesHTTP {
    /// Liest höchstens `limit` Bytes aus einem Antwortstrom.
    static func collect(_ bytes: URLSession.AsyncBytes, limit: Int) async throws -> Data {
        var data = Data()
        data.reserveCapacity(min(max(limit, 1), 8_192))
        for try await byte in bytes {
            data.append(byte)
            if data.count >= limit {
                break
            }
        }
        return data
    }

    /// Ist die Antwort ein SSE-Strom?
    ///
    /// Der Inhaltstyp kommt aus der Konfiguration, damit die Zeichenkette des
    /// Protokolls nicht über die Dateien streut.
    static func isEventStream(
        _ response: HTTPURLResponse,
        eventStreamContentType: String = HermesChatConfiguration().eventStreamContentType
    ) -> Bool {
        let contentType = (response.value(forHTTPHeaderField: "Content-Type") ?? "").lowercased()
        return contentType.contains(eventStreamContentType)
    }
}
