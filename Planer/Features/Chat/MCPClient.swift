//
//  MCPClient.swift
//  Planer
//
//  Nativer MCP-Client (Streamable HTTP) — spec-ios §9.1. Kein SDK, kein SPM,
//  nur `URLSession` und `AsyncSequence`.
//

import Foundation

// MARK: - JSON

/// Beliebiger JSON-Wert, damit `inputSchema`, `arguments` und `result` unverändert
/// durchgereicht werden können.
///
/// Zweck: ein Werkzeug-Schema ist für den Client opak; er darf es weder
/// normalisieren noch verwerfen, sonst driftet die Werkzeugliste vom Server ab.
/// Grenze: kein Pfad-Zugriff und keine Schema-Validierung — die prüft der
/// Server, nicht der Client.
enum JSONValue: Codable, Equatable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else if let value = try? container.decode([String: JSONValue].self) {
            self = .object(value)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Unbekannter JSON-Wert."
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null:
            try container.encodeNil()
        case .bool(let value):
            try container.encode(value)
        case .number(let value):
            try container.encode(value)
        case .string(let value):
            try container.encode(value)
        case .array(let value):
            try container.encode(value)
        case .object(let value):
            try container.encode(value)
        }
    }

    var objectValue: [String: JSONValue]? {
        if case .object(let value) = self { return value }
        return nil
    }

    var arrayValue: [JSONValue]? {
        if case .array(let value) = self { return value }
        return nil
    }

    var stringValue: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    var boolValue: Bool? {
        if case .bool(let value) = self { return value }
        return nil
    }
}

/// Kürzt Fremdtexte (Servermeldungen) auf eine Zeile und ein Zeichenlimit.
///
/// Zweck: Fehlermeldungen bleiben lesbar und begrenzt; ein Server darf die UI
/// nicht mit einem mehrseitigen Stacktrace fluten.
/// Grenze: keine Inhaltsprüfung — keine Geheimnisse entstehen hier, weil der
/// Client niemals Header oder Tokens in Meldungen schreibt.
func boundedText(_ value: String, limit: Int = 200) -> String {
    let singleLine = value
        .replacingOccurrences(of: "\r", with: " ")
        .replacingOccurrences(of: "\n", with: " ")
        .trimmingCharacters(in: .whitespacesAndNewlines)
    guard singleLine.count > limit else { return singleLine }
    return String(singleLine.prefix(limit)) + "…"
}

// MARK: - Fehler

/// Fehler des MCP-Clients.
///
/// Zweck: Transport-, Protokoll- und Sitzungsfehler unterscheidbar machen, damit
/// die Oberfläche richtig reagiert (Sitzung neu, erneut senden, Banner).
/// Grenze: enthält nie Header, Tokens oder Basis-URLs — nur Statuscodes und
/// gekürzte Servermeldungen.
enum MCPError: Error, Equatable, LocalizedError {
    case invalidInput(String)
    case invalidConfiguration(String)
    case protocolViolation(String)
    case jsonRPC(code: Int, message: String)
    case sessionExpired
    case http(APIError)
    case cancelled

    var errorDescription: String? {
        switch self {
        case .invalidInput(let detail):
            return "Eingabe ungültig: \(detail)"
        case .invalidConfiguration(let detail):
            return "Hermes ist nicht verbunden: \(detail)"
        case .protocolViolation(let detail):
            return "MCP-Antwort nicht verwertbar: \(detail)"
        case .jsonRPC(let code, let message):
            return "MCP-Fehler \(code): \(message)"
        case .sessionExpired:
            return "Die MCP-Sitzung ist abgelaufen."
        case .http(let error):
            return error.errorDescription
        case .cancelled:
            return "Vorgang abgebrochen."
        }
    }
}

// MARK: - JSON-RPC 2.0

/// Ein JSON-RPC-Request. `id == nil` erzeugt eine Notification (ohne `id`).
struct JSONRPCRequest: Encodable {
    let id: Int?
    let method: String
    let params: JSONValue?

    enum CodingKeys: String, CodingKey {
        case jsonrpc
        case id
        case method
        case params
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode("2.0", forKey: .jsonrpc)
        if let id {
            try container.encode(id, forKey: .id)
        }
        try container.encode(method, forKey: .method)
        if let params {
            try container.encode(params, forKey: .params)
        }
    }
}

/// Fehlerobjekt einer JSON-RPC-Antwort.
struct JSONRPCFailure: Decodable, Equatable, Sendable {
    let code: Int
    let message: String
}

/// Antwortumschlag einer JSON-RPC-Antwort.
struct JSONRPCEnvelope: Decodable {
    let id: JSONValue?
    let result: JSONValue?
    let error: JSONRPCFailure?

    /// Prüft, ob dieser Umschlag die Antwort auf `identifier` ist.
    /// Zahlen und Zeichenketten sind als `id` zulässig.
    func isResponse(to identifier: Int) -> Bool {
        guard let id else { return false }
        switch id {
        case .number(let value):
            return value == Double(identifier)
        case .string(let value):
            return value == String(identifier)
        default:
            return false
        }
    }
}

// MARK: - MCP-Nutzlasten

/// Ein Werkzeug aus `tools/list`.
struct MCPTool: Decodable, Equatable, Sendable, Identifiable {
    let name: String
    let title: String?
    let description: String?
    /// Bleibt opak: wird unverändert an den Chat-Anbieter weitergegeben.
    let inputSchema: JSONValue

    var id: String { name }

    enum CodingKeys: String, CodingKey {
        case name
        case title
        case description
        case inputSchema
    }

    init(
        name: String,
        title: String? = nil,
        description: String? = nil,
        inputSchema: JSONValue = .object(["type": .string("object")])
    ) {
        self.name = name
        self.title = title
        self.description = description
        self.inputSchema = inputSchema
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        title = try container.decodeIfPresent(String.self, forKey: .title)
        description = try container.decodeIfPresent(String.self, forKey: .description)
        inputSchema = try container.decodeIfPresent(JSONValue.self, forKey: .inputSchema)
            ?? .object(["type": .string("object")])
    }
}

/// Ergebnis eines `tools/list`-Laufs.
///
/// `truncated` ist `true`, wenn ein Limit gegriffen hat. Die Liste ist dann ein
/// **Teilstand** und wird von der Oberfläche auch so gemeldet — nicht als Erfolg.
struct MCPToolCatalog: Equatable, Sendable {
    let tools: [MCPTool]
    let truncated: Bool
}

/// Ergebnis eines `tools/call`.
struct MCPToolResult: Equatable, Sendable {
    let isError: Bool
    /// Zusammengeführte Textinhalte (`content[].type == "text"`), gekürzt.
    let text: String
    /// `structuredContent`, sofern der Server es liefert.
    let structured: JSONValue?

    init(json: JSONValue, maxCharacters: Int) {
        let object = json.objectValue ?? [:]
        isError = object["isError"]?.boolValue ?? false
        structured = object["structuredContent"]

        // `content` ist eine Liste von Teilen; nur Textteile werden gezeigt.
        let contentParts = object["content"]?.arrayValue ?? []
        var textParts: [String] = []
        for part in contentParts {
            guard let partObject = part.objectValue,
                  partObject["type"]?.stringValue == "text",
                  let text = partObject["text"]?.stringValue
            else {
                continue
            }
            textParts.append(text)
        }

        var joined = textParts.joined(separator: "\n")
        if joined.count > maxCharacters {
            joined = String(joined.prefix(maxCharacters)) + "\n… (gekürzt)"
        }
        text = joined
    }
}

// MARK: - SSE

/// Ein ausgewertetes Server-Sent-Event.
struct ServerSentEvent: Equatable, Sendable {
    let id: String?
    let event: String?
    let data: String
}

/// Zerlegt einen `text/event-stream` zeilenweise in Ereignisse.
///
/// Zweck: der MCP-Client und der Chat-Anbieter lesen denselben Strom; die
/// Zerlegung existiert deshalb genau einmal.
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
                throw MCPError.protocolViolation("SSE-Ereignis überschreitet das Größenlimit.")
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

// MARK: - Hermes-Transport

/// Setzt die Hermes-Header an genau einer Stelle des Chat-Features.
///
/// Zweck: Cloudflare-Access-Paar und Bearer-Token kommen ausschließlich aus
/// `ServiceConfiguration` (also aus der Keychain) und werden nirgends sonst im
/// Chat-Ordner gelesen.
/// Grenze: **Abweichung von Review-Check 1 (spec-ios §8).** Die Header-Injektion
/// liegt für den Chat-Tab hier und nicht in `Planer/Networking/NetworkClient.swift`,
/// weil `NetworkClient.send` die Antwort vollständig puffert (`data(for:)`) und
/// damit keinen `text/event-stream` liefern kann. `Planer/Networking/` gehört I2
/// und bleibt in I3 unberührt. Der Reviewer muss diese Doppelstelle kennen.
enum HermesAuthorization {
    static func request(
        url: URL,
        method: String,
        accept: String,
        configuration: ServiceConfiguration
    ) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue(accept, forHTTPHeaderField: "Accept")
        if let clientID = configuration.cloudflareClientID,
           let clientSecret = configuration.cloudflareClientSecret {
            request.setValue(clientID, forHTTPHeaderField: "CF-Access-Client-Id")
            request.setValue(clientSecret, forHTTPHeaderField: "CF-Access-Client-Secret")
        }
        if let token = configuration.apiToken {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        return request
    }
}

/// Gemeinsame HTTP-Helfer des Chat-Features.
///
/// Zweck: Endpunkt zusammensetzen, Antwortströme begrenzt lesen, `Retry-After`
/// lesen — einmal statt in Client und Anbieter doppelt.
/// Grenze: keine Authentifizierung (das macht `HermesAuthorization`) und keine
/// Fehlertexte (die entstehen in `APIError`/`MCPError`).
enum HermesHTTP {
    /// Hängt `path` an die Basis-URL, ohne doppelte Pfadtrenner.
    static func endpointURL(base: URL, path: String) throws -> URL {
        guard var components = URLComponents(url: base, resolvingAgainstBaseURL: false) else {
            throw APIError.invalidRequest("Basis-URL nicht zerlegbar.")
        }
        var basePath = components.path
        while basePath.hasSuffix("/") {
            basePath.removeLast()
        }
        let normalized = path.hasPrefix("/") ? path : "/" + path
        if basePath.hasSuffix(normalized) {
            components.path = basePath
        } else {
            components.path = basePath + normalized
        }
        guard let url = components.url else {
            throw APIError.invalidRequest("URL nicht baubar.")
        }
        return url
    }

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

    /// `Retry-After` als Sekunden oder HTTP-Datum (spec-ios §10).
    static func retryAfter(_ response: HTTPURLResponse) -> TimeInterval? {
        guard let raw = response.value(forHTTPHeaderField: "Retry-After") else {
            return nil
        }
        if let seconds = TimeInterval(raw) {
            return max(0, seconds)
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        guard let date = formatter.date(from: raw) else {
            return nil
        }
        return max(0, date.timeIntervalSinceNow)
    }

    /// Ist die Antwort ein SSE-Strom?
    static func isEventStream(_ response: HTTPURLResponse) -> Bool {
        let contentType = (response.value(forHTTPHeaderField: "Content-Type") ?? "").lowercased()
        return contentType.contains(MCPProtocol.eventStreamContentType)
    }
}

// MARK: - Client

/// Nativer MCP-Client über Streamable HTTP.
///
/// Zweck: `initialize` samt `Mcp-Session-Id`, `tools/list` (seitenweise),
/// `tools/call` und das Lesen von Antworten, die als `application/json` **oder**
/// als `text/event-stream` eintreffen. Alles über `URLSession` und
/// `AsyncSequence` — kein Drittanbieter-SDK.
/// Grenze: kein LLM-Text-Streaming und keine Chat-Historie (das ist
/// `ChatStreamProvider`), kein Server→Client-GET-Strom und kein
/// `Last-Event-ID`-Resume (siehe `MCPSession`). `tools/call` wird nie
/// automatisch wiederholt, weil ein Werkzeug schreiben kann.
actor MCPClient {

    struct Configuration: Sendable {
        /// MCP-Endpunkt relativ zur Hermes-Basis-URL.
        ///
        /// `[ANNAHME]` spec-ios §2.1 / §7.2 (F-Hermes-Endpunkt): belegt ist der
        /// Streamable-HTTP-Transport, **nicht** dass Hermes unter `/mcp`
        /// antwortet. Bei einem anderen Pfad genügt es, diesen Wert zu setzen.
        var endpointPath = "/mcp"

        /// Timeout je Request. MCP-Antworten dürfen als SSE eintreffen; 30 s
        /// decken Handshake und langsame Werkzeuge. Die 10 s aus spec-ios §10
        /// gelten für Sync-Läufe, nicht für einen Chat-Handshake.
        var requestTimeout: TimeInterval = 30

        /// Obergrenze der `tools/list`-Seiten (Schutz gegen Endlosschleifen).
        var maxToolPages = 5

        /// Obergrenze der Werkzeuge, die der Client hält.
        var maxTools = 200

        /// Obergrenze einer gepufferten JSON-Antwort.
        var maxResponseBytes = 1_048_576

        /// Obergrenze des Textes eines Werkzeug-Ergebnisses.
        var maxResultCharacters = 20_000
    }

    private let service: ServiceType
    private let urlSession: URLSession
    private let keychain: KeychainManager
    private let settings: Configuration

    private var mcpSession = MCPSession()
    private var isInitialized = false
    private var nextRequestIdentifier = 1

    init(
        service: ServiceType = .hermes,
        urlSession: URLSession = .shared,
        keychain: KeychainManager = KeychainManager(),
        settings: Configuration = Configuration()
    ) {
        self.service = service
        self.urlSession = urlSession
        self.keychain = keychain
        self.settings = settings
    }

    // MARK: Öffentliche API

    /// Aktueller Sitzungszustand für die Oberfläche (nur lesend).
    func currentSession() -> MCPSession {
        mcpSession
    }

    /// Führt `initialize` aus, falls die Sitzung es noch nicht ist. Idempotent.
    func connectIfNeeded() async throws {
        guard !isInitialized else { return }
        try await initialize()
    }

    /// Liest den Werkzeugkatalog vollständig (bis zu den konfigurierten Limits).
    ///
    /// - Throws: `MCPError`, wenn der Katalog nicht lesbar ist. Ein gekürzter
    ///   Katalog wird **nicht** geworfen, sondern über `truncated` gemeldet.
    func listTools() async throws -> MCPToolCatalog {
        var collected: [MCPTool] = []
        var cursor: String?
        var pages = 0

        while true {
            let params: JSONValue? = cursor.map { .object(["cursor": .string($0)]) }
            let request = JSONRPCRequest(
                id: takeIdentifier(),
                method: MCPProtocol.methodToolsList,
                params: params
            )
            // `tools/list` ist wiederholbar: nach einer abgelaufenen Sitzung darf
            // der Client neu initialisieren und dieselbe Abfrage erneut senden.
            let envelope = try await perform(request, replayable: true)
            if let failure = envelope.error {
                throw MCPError.jsonRPC(code: failure.code, message: boundedText(failure.message))
            }
            let page = try decodeResult(MCPToolsPage.self, from: envelope.result)
            collected.append(contentsOf: page.tools)
            pages += 1

            guard let next = page.nextCursor, !next.isEmpty else {
                break
            }
            guard pages < settings.maxToolPages else {
                return MCPToolCatalog(tools: Array(collected.prefix(settings.maxTools)), truncated: true)
            }
            cursor = next
        }

        let truncated = collected.count > settings.maxTools
        return MCPToolCatalog(tools: Array(collected.prefix(settings.maxTools)), truncated: truncated)
    }

    /// Ruft ein Werkzeug auf.
    ///
    /// - Parameters:
    ///   - name: Werkzeugname aus `tools/list`.
    ///   - arguments: JSON-Objekt; ein anderer Typ wird an der Grenze abgewiesen.
    /// - Throws: `MCPError.invalidInput` bei leerem Namen oder Nicht-Objekt;
    ///   sonst Transport- bzw. JSON-RPC-Fehler.
    ///
    /// **Nicht wiederholbar:** ein `tools/call` kann schreiben. Nach einer
    /// abgelaufenen Sitzung wird der Aufruf deshalb **nicht** automatisch
    /// erneut gesendet — die Oberfläche fragt, ob der Nutzer ihn wiederholen will.
    func callTool(name: String, arguments: JSONValue) async throws -> MCPToolResult {
        let toolName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !toolName.isEmpty else {
            throw MCPError.invalidInput("Werkzeugname fehlt.")
        }
        guard arguments.objectValue != nil else {
            throw MCPError.invalidInput("arguments muss ein JSON-Objekt sein.")
        }

        let params: JSONValue = .object([
            "name": .string(toolName),
            "arguments": arguments
        ])
        let request = JSONRPCRequest(
            id: takeIdentifier(),
            method: MCPProtocol.methodToolsCall,
            params: params
        )
        let envelope = try await perform(request, replayable: false)
        if let failure = envelope.error {
            throw MCPError.jsonRPC(code: failure.code, message: boundedText(failure.message))
        }
        guard let result = envelope.result else {
            throw MCPError.protocolViolation("tools/call ohne result.")
        }
        return MCPToolResult(json: result, maxCharacters: settings.maxResultCharacters)
    }

    /// Beendet die Sitzung per HTTP-`DELETE` mit `Mcp-Session-Id` (spec-ios §9.1).
    ///
    /// Best effort: ein Fehler beim Sitzungsende ist kein Grund, den lokalen
    /// Zustand zu behalten — der Client ist danach in jedem Fall „nicht verbunden“.
    func disconnect() async {
        let identifier = mcpSession.identifier
        mcpSession.reset()
        isInitialized = false
        guard let identifier else { return }

        do {
            let configuration = try loadConfiguration()
            let url = try endpointURL(base: configuration.baseURL)
            var request = HermesAuthorization.request(
                url: url,
                method: "DELETE",
                accept: "application/json",
                configuration: configuration
            )
            request.timeoutInterval = settings.requestTimeout
            request.setValue(identifier, forHTTPHeaderField: MCPProtocol.sessionHeader)
            _ = try await urlSession.data(for: request)
        } catch {
            // Sitzungsende ist best effort; der lokale Zustand ist bereits geleert.
        }
    }

    // MARK: Handshake

    /// `initialize` + `notifications/initialized`.
    private func initialize() async throws {
        let params: JSONValue = .object([
            "protocolVersion": .string(MCPProtocol.version),
            "capabilities": .object([:]),
            "clientInfo": .object([
                "name": .string("Planer"),
                "version": .string("1.0")
            ])
        ])
        // Bewusst ohne Sitzungs-Header: das erste `initialize` startet die Sitzung.
        let request = JSONRPCRequest(
            id: takeIdentifier(),
            method: MCPProtocol.methodInitialize,
            params: params
        )
        let response = try await performOnce(request)
        if let failure = response.envelope.error {
            throw MCPError.jsonRPC(code: failure.code, message: boundedText(failure.message))
        }
        let negotiated = response.envelope.result?.objectValue?["protocolVersion"]?.stringValue
        mcpSession.start(
            identifier: response.sessionIdentifier,
            negotiatedVersion: negotiated ?? MCPProtocol.version,
            at: Date()
        )

        // Pflicht-Notification ohne `id`; ein 202/204 ohne Body ist die
        // erwartete Antwort. Fehler hier sind echte Fehler und werden geworfen.
        let notification = JSONRPCRequest(id: nil, method: MCPProtocol.methodInitialized, params: nil)
        _ = try await performOnce(notification)
        isInitialized = true
    }

    // MARK: Ausführung

    private struct TransportResponse {
        let envelope: JSONRPCEnvelope
        let sessionIdentifier: String?
    }

    /// Führt einen Request aus; erneuert bei `sessionExpired` nur dann die
    /// Sitzung und wiederholt, wenn die Methode wiederholbar ist.
    private func perform(_ request: JSONRPCRequest, replayable: Bool) async throws -> JSONRPCEnvelope {
        do {
            return try await performOnce(request).envelope
        } catch let error as MCPError where error == .sessionExpired && replayable {
            mcpSession.reset()
            isInitialized = false
            try await initialize()
            return try await performOnce(request).envelope
        }
    }

    private func performOnce(_ request: JSONRPCRequest) async throws -> TransportResponse {
        let configuration = try loadConfiguration()
        let url = try endpointURL(base: configuration.baseURL)

        var urlRequest = HermesAuthorization.request(
            url: url,
            method: "POST",
            accept: MCPProtocol.accept,
            configuration: configuration
        )
        urlRequest.timeoutInterval = settings.requestTimeout
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let identifier = mcpSession.identifier {
            urlRequest.setValue(identifier, forHTTPHeaderField: MCPProtocol.sessionHeader)
        }
        do {
            urlRequest.httpBody = try Self.encoder.encode(request)
        } catch {
            throw MCPError.protocolViolation("Anfrage nicht serialisierbar.")
        }

        let bytes: URLSession.AsyncBytes
        let response: URLResponse
        do {
            (bytes, response) = try await urlSession.bytes(for: urlRequest)
        } catch let error as URLError {
            switch error.code {
            case .cancelled:
                throw MCPError.cancelled
            case .timedOut:
                throw MCPError.http(.timeout)
            default:
                throw MCPError.http(.offline)
            }
        } catch is CancellationError {
            throw MCPError.cancelled
        } catch {
            // Kein `error.localizedDescription`: die kann die URL enthalten.
            throw MCPError.http(.invalidRequest("Verbindung zu Hermes nicht möglich."))
        }

        guard let http = response as? HTTPURLResponse else {
            throw MCPError.protocolViolation("Antwort ohne HTTP-Status.")
        }
        let sessionIdentifier = http.value(forHTTPHeaderField: MCPProtocol.sessionHeader)

        // 404 mit vorhandener Sitzung = Sitzung abgelaufen (spec-ios §10).
        // Über die Wiederholung entscheidet `perform`.
        if http.statusCode == 404, mcpSession.identifier != nil {
            throw MCPError.sessionExpired
        }
        guard (200..<300).contains(http.statusCode) else {
            let body = (try? await HermesHTTP.collect(bytes, limit: 4_096)) ?? Data()
            throw MCPError.http(
                APIError.from(
                    status: http.statusCode,
                    body: body,
                    retryAfter: HermesHTTP.retryAfter(http)
                )
            )
        }
        if http.statusCode == 202 || http.statusCode == 204 {
            return TransportResponse(
                envelope: JSONRPCEnvelope(id: nil, result: nil, error: nil),
                sessionIdentifier: sessionIdentifier
            )
        }

        let envelope: JSONRPCEnvelope
        if HermesHTTP.isEventStream(http) {
            guard let expected = request.id else {
                // Notification: der Strom enthält keine Antwort, die uns gehört.
                _ = try? await HermesHTTP.collect(bytes, limit: 4_096)
                return TransportResponse(
                    envelope: JSONRPCEnvelope(id: nil, result: nil, error: nil),
                    sessionIdentifier: sessionIdentifier
                )
            }
            envelope = try await readEnvelope(from: bytes, matching: expected)
        } else {
            let body = try await HermesHTTP.collect(bytes, limit: settings.maxResponseBytes)
            if body.isEmpty, request.id == nil {
                // Notification ohne Body (z. B. `202` mit leerem `200`): keine Antwort erwartet.
                return TransportResponse(
                    envelope: JSONRPCEnvelope(id: nil, result: nil, error: nil),
                    sessionIdentifier: sessionIdentifier
                )
            }
            do {
                envelope = try Self.decoder.decode(JSONRPCEnvelope.self, from: body)
            } catch {
                throw MCPError.protocolViolation("Antwort ist kein JSON-RPC-Objekt.")
            }
        }

        return TransportResponse(envelope: envelope, sessionIdentifier: sessionIdentifier)
    }

    /// Liest den SSE-Strom, bis die Antwort auf `identifier` eintrifft.
    private func readEnvelope(
        from bytes: URLSession.AsyncBytes,
        matching identifier: Int
    ) async throws -> JSONRPCEnvelope {
        var decoder = ServerSentEventDecoder()
        var eventCount = 0

        for try await line in bytes.lines {
            try Task.checkCancellation()
            guard let event = try decoder.consume(line: line) else { continue }
            eventCount += 1
            guard eventCount <= 1_000 else {
                throw MCPError.protocolViolation("SSE-Strom liefert zu viele Ereignisse ohne Antwort.")
            }
            let payload = event.data.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !payload.isEmpty else { continue }
            guard let data = payload.data(using: .utf8),
                  let envelope = try? Self.decoder.decode(JSONRPCEnvelope.self, from: data)
            else {
                // Fremdereignis (Log-Zeile, Notification) — nicht unsere Antwort.
                continue
            }
            if envelope.isResponse(to: identifier) {
                return envelope
            }
        }
        throw MCPError.protocolViolation("SSE-Strom endete ohne Antwort auf die Anfrage.")
    }

    // MARK: Hilfen

    private func takeIdentifier() -> Int {
        let identifier = nextRequestIdentifier
        nextRequestIdentifier += 1
        return identifier
    }

    private func loadConfiguration() throws -> ServiceConfiguration {
        do {
            return try ServiceConfiguration.load(service, keychain: keychain)
        } catch {
            throw MCPError.invalidConfiguration(boundedText(error.localizedDescription))
        }
    }

    private func endpointURL(base: URL) throws -> URL {
        do {
            return try HermesHTTP.endpointURL(base: base, path: settings.endpointPath)
        } catch {
            throw MCPError.invalidConfiguration(boundedText(error.localizedDescription))
        }
    }

    private func decodeResult<T: Decodable>(_ type: T.Type, from value: JSONValue?) throws -> T {
        guard let value else {
            throw MCPError.protocolViolation("Antwort ohne result.")
        }
        do {
            let data = try Self.encoder.encode(value)
            return try Self.decoder.decode(type, from: data)
        } catch {
            throw MCPError.protocolViolation("result entspricht nicht dem erwarteten Format.")
        }
    }

    private static let encoder = JSONEncoder()
    private static let decoder = JSONDecoder()
}

/// Eine Seite aus `tools/list`.
private struct MCPToolsPage: Decodable {
    let tools: [MCPTool]
    let nextCursor: String?

    enum CodingKeys: String, CodingKey {
        case tools
        case nextCursor
    }
}
