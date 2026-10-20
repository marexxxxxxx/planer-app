//
//  MCPSession.swift
//  Planer
//
//  Identität und Lebenszyklus einer MCP-Sitzung (spec-ios §9.1).
//

import Foundation

/// Die MCP-Konstanten, die dieser Client tatsächlich verwendet.
///
/// Zweck: die in spec-ios §9.1 belegten Zeichenketten an genau einer Stelle
/// benennen, damit Header und Methodennamen nicht über die Dateien streuen.
/// Grenze: keine Werkzeug-Semantik. Was ein Werkzeug tut, steht im Server —
/// der Client kennt nur den Transport.
enum MCPProtocol {
    /// Header, mit dem der Server die Sitzung benennt (`Mcp-Session-Id`).
    /// Der Client muss ihn auf allen Folge-Requests mitsenden.
    static let sessionHeader = "Mcp-Session-Id"

    /// Belegte Protokollversion aus spec-ios §9.1 (MCP-Spec 2025-03-26).
    static let version = "2025-03-26"

    /// Beide Antwortformen sind zulässig: ein JSON-Objekt oder ein SSE-Strom.
    static let accept = "application/json, text/event-stream"

    /// Content-Type des SSE-Stroms (`text/event-stream`).
    static let eventStreamContentType = "text/event-stream"

    /// Handshake-Methode; startet die Sitzung und liefert `Mcp-Session-Id`.
    static let methodInitialize = "initialize"

    /// Pflicht-Notification direkt nach `initialize` (ohne `id`).
    static let methodInitialized = "notifications/initialized"

    /// Werkzeugkatalog; wird seitenweise über `nextCursor` gelesen.
    static let methodToolsList = "tools/list"

    /// Werkzeugaufruf. Kann schreiben — deshalb nie automatisch wiederholt.
    static let methodToolsCall = "tools/call"
}

/// Zustand einer MCP-Sitzung.
///
/// Zweck: `Mcp-Session-Id`, ausgehandelte Protokollversion und Startzeit an
/// einem Ort halten; `MCPClient` ist ein Actor und mutiert ausschließlich diese
/// Struktur.
/// Grenze: keine Netzwerkzugriffe. Ob nach einem `404` neu initialisiert wird,
/// entscheidet der Client — und dort nur für wiederholbare Methoden.
///
/// `identifier` darf `nil` bleiben: ein zustandsloser Server muss keine
/// Sitzungs-ID vergeben. `initializedAt` unterscheidet „verbunden“ von
/// „identifiziert“.
///
/// **Nicht implementiert (bewusst): Resume über `Last-Event-ID`.** spec-ios
/// §9.1 nennt SSE-`id` + `Last-Event-ID` als Resume-Mechanismus für einen
/// abgerissenen Strom. Der Chat-Tab führt keine serverseitigen Chat-Sitzungen
/// (die sind in §9.3 ausdrücklich offen); ein abgerissener Strom wird deshalb
/// als Fehler gemeldet und die Antwort auf Wunsch neu angestoßen, statt still
/// einen Cursor fortzusetzen. Kein stiller Datenverlust, keine erfundene
/// Fortsetzung.
struct MCPSession: Equatable, Sendable {
    /// Vom Server im `initialize`-Antwortheader gelieferte Sitzungs-ID.
    private(set) var identifier: String?

    /// Vom Server bestätigte Protokollversion (Fallback: `MCPProtocol.version`).
    private(set) var negotiatedVersion: String?

    /// Zeitpunkt des erfolgreichen `initialize`; `nil` heißt „nicht verbunden“.
    private(set) var initializedAt: Date?

    /// `true`, sobald `initialize` erfolgreich beantwortet wurde.
    var isInitialized: Bool { initializedAt != nil }

    init() {}

    /// Übernimmt das Ergebnis eines erfolgreichen `initialize`.
    ///
    /// Leere oder nur aus Leerzeichen bestehende IDs gelten als „keine ID“ —
    /// ein Header mit leerem Wert ist kein gültiger Sitzungsschlüssel.
    mutating func start(identifier: String?, negotiatedVersion: String?, at date: Date) {
        let trimmed = identifier?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.identifier = (trimmed?.isEmpty == false) ? trimmed : nil
        self.negotiatedVersion = negotiatedVersion
        self.initializedAt = date
    }

    /// Verwirft die Sitzung; der nächste Aufruf startet ein neues `initialize`.
    mutating func reset() {
        self = MCPSession()
    }
}
