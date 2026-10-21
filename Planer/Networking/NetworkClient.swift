//
//  NetworkClient.swift
//  Planer
//
//  HTTP-Kern für alle vier Dienste; einzige Stelle der Header-Injektion (spec-ios §8).
//

import Foundation

/// HTTP-Methode der von der App genutzten Endpunkte.
enum HTTPMethod: String, Sendable {
    case get = "GET"
    case post = "POST"
    case patch = "PATCH"
    case delete = "DELETE"
}

/// Ein Request relativ zur Basis-URL eines Dienstes.
///
/// Zweck: Methode, Pfad, Query, optionaler JSON-Body und Protokoll-Header als
/// Wertetyp.
/// Grenze: **keine Authentifizierungs-Header.** Die Cloudflare-Access-Header
/// und `Authorization` setzt ausschließlich `NetworkClient.injectHeaders`;
/// `headers` ist für Protokoll-Header wie `Mcp-Session-Id` oder `Content-Type`
/// gedacht und wird von `injectHeaders` bei Namensgleichheit überschrieben.
struct APIRequest {
    let method: HTTPMethod
    /// Pfad relativ zur Basis-URL, z. B. `/tasks` bei Basis-URL `https://host/api`.
    let path: String
    let query: [URLQueryItem]
    let body: Data?
    let accept: String
    /// Zusätzliche Protokoll-Header; niemals Secrets (siehe Typ-Doku).
    var headers: [String: String]

    init(
        method: HTTPMethod,
        path: String,
        query: [URLQueryItem] = [],
        body: Data? = nil,
        accept: String = "application/json",
        headers: [String: String] = [:]
    ) {
        self.method = method
        self.path = path
        self.query = query
        self.body = body
        self.accept = accept
        self.headers = headers
    }
}

/// Antwort eines Streaming-Requests: ungepufferter Byte-Strom plus HTTP-Kopf.
///
/// Zweck: `text/event-stream` (MCP, Chat) aus derselben Request-Kette lesen,
/// die auch `send` nutzt — inklusive der einen Header-Injektion.
/// Grenze: kein Retry und keine Statusprüfung; beides entscheidet der Aufrufer,
/// weil ein Fehlertext im Strom stehen kann.
struct StreamingResponse {
    let bytes: URLSession.AsyncBytes
    let response: HTTPURLResponse
}

/// Führt Requests gegen die vier Dienste aus.
///
/// Zweck: Basis-URL aus der Keychain auflösen, Header genau einmal injizieren,
/// Timeout/Retry nach `RetryPolicy` anwenden und Antworten in `APIError` bzw.
/// Decodable-Werte übersetzen. `stream` liefert denselben Request-Aufbau
/// ungepuffert, damit auch `text/event-stream` (MCP, Chat) durch diese eine
/// Header-Injektion läuft.
/// Grenze: keine Fachlogik und kein Cache.
struct NetworkClient {
    private let session: URLSession
    private let retryPolicy: RetryPolicy
    /// Request-Timeout in Sekunden (spec-ios §10: 10 s, konfiguriert).
    private let timeout: TimeInterval
    private let keychain: KeychainManager

    init(
        session: URLSession = .shared,
        retryPolicy: RetryPolicy = .default,
        timeout: TimeInterval = 10,
        keychain: KeychainManager = KeychainManager()
    ) {
        self.session = session
        self.retryPolicy = retryPolicy
        self.timeout = timeout
        self.keychain = keychain
    }

    /// Führt den Request aus und liefert die Rohdaten (auch leer bei `204`).
    func send(_ request: APIRequest, for service: ServiceType) async throws -> Data {
        let configuration = try loadConfiguration(for: service)
        let urlRequest = try makeURLRequest(request, configuration: configuration)
        return try await perform(urlRequest, attempt: 1)
    }

    /// Führt den Request aus und liefert Rohdaten plus HTTP-Kopf.
    ///
    /// Zweck: Der Verbindungstest der Einstellungen muss Status und Body sehen,
    /// um 401, 403, 404 und die HTML-Anmeldeseite von Cloudflare Access zu
    /// unterscheiden; `send` wirft Nicht-2xx und verliert dabei den Body.
    /// Grenze: wiederholt wie `send` nur GET bei Timeout/Offline/5xx. Einen
    /// Redirect verfolgt nur der übergebene Client — für den Verbindungstest
    /// ist das `NetworkClient.connectionTest`, der Redirects stehen lässt.
    func sendRaw(
        _ request: APIRequest,
        for service: ServiceType
    ) async throws -> (data: Data, response: HTTPURLResponse) {
        let configuration = try loadConfiguration(for: service)
        let urlRequest = try makeURLRequest(request, configuration: configuration)
        return try await performRaw(urlRequest, attempt: 1)
    }

    /// Führt den Request aus und decodiert die Antwort als `Response`.
    func send<Response: Decodable>(
        _ request: APIRequest,
        for service: ServiceType,
        as type: Response.Type
    ) async throws -> Response {
        let data = try await send(request, for: service)
        guard !data.isEmpty else {
            throw APIError.emptyResponse
        }
        do {
            return try Self.makeDecoder().decode(Response.self, from: data)
        } catch {
            throw APIError.decoding(error.localizedDescription)
        }
    }

    /// Führt den Request aus und liefert den ungepufferten Antwortstrom.
    ///
    /// Zweck: `text/event-stream` lesen zu können, ohne die sicherheitsrelevante
    /// Header-Injektion ein zweites Mal zu implementieren. Der Request wird über
    /// dieselbe `makeURLRequest`/`injectHeaders`-Kette gebaut wie bei `send`.
    /// Grenze: **kein automatischer Retry** — ein Strom wird nicht wiederholt;
    /// die aufrufende Schicht entscheidet. Nicht-2xx-Antworten werden nicht
    /// geworfen, weil der Fehlertext im Strom stehen kann: der Aufrufer prüft
    /// `response.statusCode` und liest den Body begrenzt.
    func stream(_ request: APIRequest, for service: ServiceType) async throws -> StreamingResponse {
        let configuration = try loadConfiguration(for: service)
        let urlRequest = try makeURLRequest(request, configuration: configuration)

        do {
            let (bytes, response) = try await session.bytes(for: urlRequest)
            guard let http = response as? HTTPURLResponse else {
                throw APIError.invalidResponse
            }
            return StreamingResponse(bytes: bytes, response: http)
        } catch let error as URLError {
            switch error.code {
            case .cancelled:
                throw APIError.cancelled
            case .timedOut:
                throw APIError.timeout
            default:
                throw APIError.offline
            }
        } catch is CancellationError {
            throw APIError.cancelled
        } catch let error as APIError {
            throw error
        } catch {
            // Kein `error.localizedDescription`: die kann die URL enthalten.
            throw APIError.invalidRequest("Verbindung zum Dienst nicht möglich.")
        }
    }

    // MARK: - Request-Aufbau

    private func makeURLRequest(
        _ request: APIRequest,
        configuration: ServiceConfiguration
    ) throws -> URLRequest {
        guard var components = URLComponents(
            url: configuration.baseURL,
            resolvingAgainstBaseURL: false
        ) else {
            throw APIError.invalidRequest("Basis-URL nicht zerlegbar.")
        }

        var basePath = components.path
        if basePath.hasSuffix("/") {
            basePath.removeLast()
        }
        if request.path.isEmpty {
            components.path = basePath.isEmpty ? "/" : basePath
        } else {
            let requestPath = request.path.hasPrefix("/") ? request.path : "/" + request.path
            // Eine Basis-URL, die den Endpunktpfad bereits enthält (z. B.
            // `https://host/mcp` + `/mcp`), wird nicht verdoppelt.
            components.path = basePath.hasSuffix(requestPath) ? basePath : basePath + requestPath
        }
        if !request.query.isEmpty {
            components.queryItems = (components.queryItems ?? []) + request.query
        }

        guard let url = components.url else {
            throw APIError.invalidRequest("URL nicht baubar für Pfad \(request.path).")
        }

        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = request.method.rawValue
        urlRequest.timeoutInterval = timeout
        if let body = request.body {
            urlRequest.httpBody = body
            urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        // Protokoll-Header zuerst; `injectHeaders` hat das letzte Wort über
        // `Accept`, `Authorization` und die Cloudflare-Header.
        for (field, value) in request.headers {
            urlRequest.setValue(value, forHTTPHeaderField: field)
        }
        injectHeaders(into: &urlRequest, accept: request.accept, configuration: configuration)
        return urlRequest
    }

    /// Einzige Stelle der Authentifizierungs-Header (spec-ios §8, Review-Check 1).
    ///
    /// Cloudflare Access gilt für alle Dienste; `Authorization: Bearer` nur für
    /// Hermes/Mealie, `GROCY-API-KEY` nur für Grocy, das Dashboard hat keinen
    /// API-Token (spec-ios §2.2).
    private func injectHeaders(
        into request: inout URLRequest,
        accept: String,
        configuration: ServiceConfiguration
    ) {
        request.setValue(accept, forHTTPHeaderField: "Accept")
        if let clientID = configuration.cloudflareClientID,
           let clientSecret = configuration.cloudflareClientSecret {
            request.setValue(clientID, forHTTPHeaderField: "CF-Access-Client-Id")
            request.setValue(clientSecret, forHTTPHeaderField: "CF-Access-Client-Secret")
        }
        switch configuration.service {
        case .hermes, .mealie:
            if let token = configuration.apiToken {
                request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            }
        case .grocy:
            if let key = configuration.apiKey {
                request.setValue(key, forHTTPHeaderField: "GROCY-API-KEY")
            }
        case .dashboard:
            break
        }
    }

    // MARK: - Ausführung und Retry

    private func loadConfiguration(for service: ServiceType) throws -> ServiceConfiguration {
        do {
            return try ServiceConfiguration.load(service, keychain: keychain)
        } catch {
            throw APIError.invalidConfiguration(error.localizedDescription)
        }
    }

    private func perform(_ request: URLRequest, attempt: Int) async throws -> Data {
        let result = try await performRaw(request, attempt: attempt)
        guard (200..<300).contains(result.response.statusCode) else {
            throw APIError.from(
                status: result.response.statusCode,
                body: result.data,
                retryAfter: Self.retryAfter(from: result.response)
            )
        }
        return result.data
    }

    /// Führt einen Versuch aus, wiederholt wiederholbare Fehler und liefert die
    /// Rohantwort — auch Nicht-2xx, damit `sendRaw` den Body auswerten kann.
    ///
    /// Wiederholt werden Transportfehler sowie 429 und retryable 5xx; die
    /// Methodenprüfung liegt in `waitBeforeRetry`.
    private func performRaw(
        _ request: URLRequest,
        attempt: Int
    ) async throws -> (data: Data, response: HTTPURLResponse) {
        // Der Netzwerkaufruf steht bewusst allein im do-Block: Fehler aus
        // `waitBeforeRetry` dürfen nicht erneut von diesem catch abgefangen
        // werden.
        let result: (data: Data, response: URLResponse)
        do {
            result = try await session.data(for: request)
        } catch let error as URLError {
            if error.code == .cancelled {
                throw APIError.cancelled
            }
            let mapped: APIError = error.code == .timedOut ? .timeout : .offline
            guard try await waitBeforeRetry(mapped, request: request, attempt: attempt) else {
                throw mapped
            }
            return try await performRaw(request, attempt: attempt + 1)
        } catch is CancellationError {
            throw APIError.cancelled
        } catch {
            // Kein `error.localizedDescription`: die kann die URL enthalten.
            throw APIError.invalidRequest("Verbindung zum Dienst nicht möglich.")
        }

        guard let http = result.response as? HTTPURLResponse else {
            throw APIError.invalidResponse
        }
        guard !(200..<300).contains(http.statusCode) else {
            return (result.data, http)
        }
        let error = APIError.from(
            status: http.statusCode,
            body: result.data,
            retryAfter: Self.retryAfter(from: http)
        )
        guard try await waitBeforeRetry(error, request: request, attempt: attempt) else {
            return (result.data, http)
        }
        return try await performRaw(request, attempt: attempt + 1)
    }

    /// Wartet, wenn der Fehler nach `attempt` wiederholt werden darf.
    ///
    /// Wiederholt wird ausschließlich GET: ein unbeaufsichtigtes `POST`,
    /// `PATCH` oder `DELETE` könnte eine zweite Sitzung oder einen zweiten
    /// Eintrag anlegen (F6 aus MARAAA-132). 400/401/403/404/409 sind ohnehin
    /// nicht wiederholbar (`APIError.isRetryable`).
    private func waitBeforeRetry(
        _ error: APIError,
        request: URLRequest,
        attempt: Int
    ) async throws -> Bool {
        guard request.httpMethod == HTTPMethod.get.rawValue,
              retryPolicy.shouldRetry(error, afterAttempt: attempt)
        else {
            return false
        }
        let policyDelay = retryPolicy.delay(beforeAttempt: attempt + 1)
        let delay = max(policyDelay, error.retryAfter ?? 0)
        if delay > 0 {
            do {
                try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            } catch {
                throw APIError.cancelled
            }
        }
        return true
    }

    /// Liest `Retry-After` als Sekunden oder als HTTP-Datum (spec-ios §10).
    ///
    /// Intern, aber bewusst nicht `private`: `MCPClient` und der Chat-Strom
    /// prüfen denselben Header auf Antworten, die sie über `stream` erhalten.
    static func retryAfter(from response: HTTPURLResponse) -> TimeInterval? {
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

    /// Decoder für die Verträge aus spec-ios §2: ISO-8601-Zeitstempel und
    /// reine `YYYY-MM-DD`-Daten (z. B. `due_at`).
    private static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let raw = try container.decode(String.self)

            let isoFormatter = ISO8601DateFormatter()
            if let date = isoFormatter.date(from: raw) {
                return date
            }

            let dayFormatter = DateFormatter()
            dayFormatter.locale = Locale(identifier: "en_US_POSIX")
            dayFormatter.timeZone = TimeZone(secondsFromGMT: 0)
            dayFormatter.dateFormat = "yyyy-MM-dd"
            if let date = dayFormatter.date(from: raw) {
                return date
            }

            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Unbekanntes Datumsformat: \(raw)"
            )
        }
        return decoder
    }
}

extension NetworkClient {
    /// Client für „Test Verbindung“, der HTTP-Redirects nicht folgt.
    ///
    /// Zweck: Cloudflare Access antwortet unauthentifiziert mit 302 auf
    /// `*.cloudflareaccess.com`; eine Session, die dem Redirect folgt, liefert
    /// danach 200-HTML und verdeckt damit die Ursache (MARAAA-132 §5 B2).
    static let connectionTest = NetworkClient(session: redirectBlockingSession)

    private static let redirectBlockingSession: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 10
        return URLSession(
            configuration: configuration,
            delegate: RedirectBlocker(),
            delegateQueue: nil
        )
    }()
}

/// Verwirft Weiterleitungen, damit der 302 mit seinem `Location`-Header
/// sichtbar bleibt; `completionHandler(nil)` liefert die Antwort unverändert
/// an den Aufrufer.
private final class RedirectBlocker: NSObject, URLSessionTaskDelegate {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}
