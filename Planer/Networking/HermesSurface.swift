//
//  HermesSurface.swift
//  Planer
//
//  Welche Hermes-Oberfläche der Verbindungstest erreicht hat (MARAAA-159).
//

import Foundation

/// Die für die Diagnose relevanten Felder von `GET /api/status`.
///
/// Zweck: Das Dashboard beantwortet `/api/status` mit einem Statusbericht, der
/// unter `gateway_platforms.api_server` Zustand und `listener_base` des
/// API-Servers nennt. Daraus lässt sich ablesen, ob der API-Server läuft und
/// an welche Adresse er gebunden ist.
/// Grenze: alle Felder sind optional und unbekannte Schlüssel werden ignoriert
/// — eine ältere oder neuere Hermes-Version darf den Verbindungstest nicht am
/// Dekodieren scheitern lassen. Die Datei kennt keine UI und keinen Netzaufruf.
struct HermesDashboardStatus: Decodable, Equatable, Sendable {
    /// Zustand der Gateway-Plattformen (`gateway_platforms`).
    struct GatewayPlatforms: Decodable, Equatable, Sendable {
        /// Der `api_server`-Eintrag; fehlt er, ist der API-Server nicht startbar.
        struct APIServer: Decodable, Equatable, Sendable {
            /// `connected`, `disconnected` oder ein anderer Zustand.
            let state: String?
            /// Adresse, an die der API-Server tatsächlich gebunden ist.
            let listenerBase: String?

            enum CodingKeys: String, CodingKey {
                case state
                case listenerBase = "listener_base"
            }
        }

        let apiServer: APIServer?

        enum CodingKeys: String, CodingKey {
            case apiServer = "api_server"
        }
    }

    /// `gateway_running` des Dashboards.
    let gatewayRunning: Bool?
    let gatewayPlatforms: GatewayPlatforms?

    enum CodingKeys: String, CodingKey {
        case gatewayRunning = "gateway_running"
        case gatewayPlatforms = "gateway_platforms"
    }

    /// Zustand des API-Servers, falls das Dashboard ihn meldet.
    var apiServerState: String? {
        gatewayPlatforms?.apiServer?.state
    }

    /// Vom API-Server gemeldete Bindungsadresse, z. B. `http://127.0.0.1:8642`.
    var listenerBase: String? {
        gatewayPlatforms?.apiServer?.listenerBase
    }
}

/// Wie ein Listener gebunden ist.
///
/// Zweck: unterscheidet den ausschließlich lokal erreichbaren Loopback-Fall
/// von der Bindung an alle Interfaces (`0.0.0.0`/`::`) und von einer konkreten
/// Adresse (LAN-IP oder Hostname).
/// Grenze: reine Textauswertung der gemeldeten Adresse; sie prüft nicht, ob
/// der Listener tatsächlich läuft.
enum HermesListenerScope: Equatable, Sendable {
    /// Nur auf dem Server selbst erreichbar (`127.0.0.1`, `localhost`, `::1`).
    case loopback
    /// Auf allen Interfaces gebunden (`0.0.0.0`, `::`) — von außen erreichbar.
    case allInterfaces
    /// Eine konkrete Adresse (LAN-IP, Hostname) oder keine Angabe.
    case other
}

/// Befund des Hermes-Verbindungstests.
///
/// Zweck: macht aus dem HTTP-Status von `/v1/models` und der Dashboard-Antwort
/// von `/api/status` eine benennbare Oberfläche, damit die Einstellungen eine
/// konkrete Handlungsanweisung anzeigen können statt nur „404“.
/// Grenze: kein UI-Text und kein Netzwerk; die Meldungen formuliert der
/// Aufrufer.
enum HermesSurface: Equatable, Sendable {
    /// `/v1/models` antwortet 2xx: erreicht ist der API-Server.
    case apiServer
    /// `/api/status` antwortet: erreicht ist das Dashboard, nicht der API-Server.
    case dashboard(
        apiServerState: String?,
        listenerBase: String?,
        listenerIsLoopback: Bool,
        listenerIsAllInterfaces: Bool
    )
    /// Weder `/v1/models` noch `/api/status` liefern eine verwertbare Antwort.
    case unreachable
}

extension HermesSurface {
    /// `true`, wenn die Adresse ausschließlich an Loopback gebunden ist.
    ///
    /// Zweck: Der Hermes-Default `API_SERVER_HOST=127.0.0.1` macht den
    /// API-Server nur auf dem Server selbst erreichbar; das erklärt ein
    /// „Connection refused“ von außen, obwohl der Prozess läuft.
    /// Grenze: `0.0.0.0` ist **nicht** Loopback, sondern „alle Interfaces“
    /// (`HermesListenerScope.allInterfaces`).
    static func isLoopbackListener(_ raw: String?) -> Bool {
        listenerScope(raw) == .loopback
    }

    /// `true`, wenn die Adresse an alle Interfaces gebunden ist (`0.0.0.0`/`::`).
    static func isAllInterfacesListener(_ raw: String?) -> Bool {
        listenerScope(raw) == .allInterfaces
    }

    /// Ordnet eine gemeldete Adresse einem Bindungsbereich zu.
    ///
    /// Akzeptiert `host`, `host:port` und vollständige URLs mit Schema, Port und
    /// Pfad, auch IPv6 in Klammern (`http://[::1]:8642`).
    static func listenerScope(_ raw: String?) -> HermesListenerScope {
        guard let host = host(from: raw) else { return .other }
        switch host {
        case "127.0.0.1", "localhost", "::1":
            return .loopback
        case "0.0.0.0", "::":
            // 0.0.0.0/:: heißt „auf allen Interfaces“, nicht „nur lokal“.
            return .allInterfaces
        default:
            return .other
        }
    }

    /// Befund aus dem Status von `/v1/models` und der Dashboard-Antwort.
    ///
    /// Zweck: Eine 2xx-Antwort von `/v1/models` beweist den API-Server; ohne
    /// diese Antwort und mit einer dekodierten `/api/status`-Antwort ist die
    /// erreichte Oberfläche das Dashboard.
    /// Grenze: `v1ModelsStatus == nil` bedeutet „kein Status erhalten“ (etwa
    /// Verbindungsfehler); die Entscheidung über die Meldung trifft der
    /// Aufrufer.
    static func classify(
        v1ModelsStatus: Int?,
        dashboard: HermesDashboardStatus?
    ) -> HermesSurface {
        if let status = v1ModelsStatus, (200..<300).contains(status) {
            return .apiServer
        }
        guard let dashboard else { return .unreachable }
        return .dashboard(
            apiServerState: dashboard.apiServerState,
            listenerBase: dashboard.listenerBase,
            listenerIsLoopback: isLoopbackListener(dashboard.listenerBase),
            listenerIsAllInterfaces: isAllInterfacesListener(dashboard.listenerBase)
        )
    }

    /// Liest den Host aus einer gemeldeten Adresse.
    ///
    /// Grenze: nur Textauswertung; ein Wert ohne Host ergibt `nil`.
    private static func host(from raw: String?) -> String? {
        guard let value = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty
        else {
            return nil
        }
        var rest = value
        if let scheme = rest.range(of: "://") {
            rest = String(rest[scheme.upperBound...])
        }
        if let end = rest.firstIndex(where: { $0 == "/" || $0 == "?" || $0 == "#" }) {
            rest = String(rest[..<end])
        }
        // IPv6 in Klammern, optional mit Port: [::1] oder [::1]:8642.
        if rest.hasPrefix("[") {
            guard let close = rest.firstIndex(of: "]") else { return nil }
            return String(rest[rest.index(after: rest.startIndex)..<close]).lowercased()
        }
        // Ungeklammerte IPv6-Adresse (::1, ::) hat mehr als einen Doppelpunkt.
        if rest.filter({ $0 == ":" }).count > 1 {
            return rest.lowercased()
        }
        if let colon = rest.lastIndex(of: ":") {
            let port = rest[rest.index(after: colon)...]
            if !port.isEmpty, port.allSatisfy({ $0.isNumber }) {
                return String(rest[..<colon]).lowercased()
            }
        }
        return rest.lowercased()
    }
}
