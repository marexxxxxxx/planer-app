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
/// werden ignoriert. Ein Ereignis über dem Zeichenlimit ist ein Fehler — kein
/// stilles Verwerfen.
struct ServerSentEventDecoder {
    private var dataLines: [String] = []
    private var eventName: String?
    private var lastIdentifier: String?
    private var bufferedCharacters = 0
    private let maxCharacters: Int

    init(maxCharacters: Int = 262_144) {
        self.maxCharacters = max(1_024, maxCharacters)
    }

    /// Füttert eine Zeile; liefert ein Ereignis, sobald eine Leerzeile es beendet.
    mutating func consume(line: String) throws -> ServerSentEvent? {
        if line.isEmpty {
            guard !dataLines.isEmpty else {
                eventName = nil
                return nil
            }
            let event = ServerSentEvent(
                id: lastIdentifier,
                event: eventName,
                data: dataLines.joined(separator: "\n")
            )
            dataLines.removeAll(keepingCapacity: true)
            eventName = nil
            bufferedCharacters = 0
            return event
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
            dataLines.append(value)
            bufferedCharacters += value.count
            guard bufferedCharacters <= maxCharacters else {
                throw ChatStreamError.protocolViolation("SSE-Ereignis überschreitet das Größenlimit.")
            }
        case "event":
            eventName = value
        case "id":
            lastIdentifier = value
        default:
            break
        }
        return nil
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
