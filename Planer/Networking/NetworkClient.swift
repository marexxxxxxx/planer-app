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
/// Zweck: Methode, Pfad, Query und optionaler JSON-Body als Wertetyp.
/// Grenze: enthält bewusst keine Header; Authentifizierungs-Header setzt
/// ausschließlich `NetworkClient.injectHeaders`.
struct APIRequest {
    let method: HTTPMethod
    /// Pfad relativ zur Basis-URL, z. B. `/tasks` bei Basis-URL `https://host/api`.
    let path: String
    let query: [URLQueryItem]
    let body: Data?
    let accept: String

    init(
        method: HTTPMethod,
        path: String,
        query: [URLQueryItem] = [],
        body: Data? = nil,
        accept: String = "application/json"
    ) {
        self.method = method
        self.path = path
        self.query = query
        self.body = body
        self.accept = accept
    }
}

/// Führt Requests gegen die vier Dienste aus.
///
/// Zweck: Basis-URL aus der Keychain auflösen, Header genau einmal injizieren,
/// Timeout/Retry nach `RetryPolicy` anwenden und Antworten in `APIError` bzw.
/// Decodable-Werte übersetzen.
/// Grenze: keine Fachlogik, kein Cache und kein MCP-Streaming (das ist I3).
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
        let configuration: ServiceConfiguration
        do {
            configuration = try ServiceConfiguration.load(service, keychain: keychain)
        } catch {
            throw APIError.invalidConfiguration(error.localizedDescription)
        }
        let urlRequest = try makeURLRequest(request, configuration: configuration)
        return try await perform(urlRequest, attempt: 1)
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
            components.path = basePath + requestPath
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

    private func perform(_ request: URLRequest, attempt: Int) async throws -> Data {
        // Der Netzwerkaufruf steht bewusst allein im do-Block: Fehler aus
        // `retry` dürfen nicht erneut von diesem catch abgefangen werden.
        let result: (data: Data, response: URLResponse)
        do {
            result = try await session.data(for: request)
        } catch let error as URLError {
            if error.code == .cancelled {
                throw APIError.cancelled
            }
            let mapped: APIError = error.code == .timedOut ? .timeout : .offline
            return try await retry(mapped, request: request, attempt: attempt)
        } catch is CancellationError {
            throw APIError.cancelled
        } catch {
            throw APIError.invalidRequest(error.localizedDescription)
        }

        guard let http = result.response as? HTTPURLResponse else {
            throw APIError.invalidResponse
        }
        if (200..<300).contains(http.statusCode) {
            return result.data
        }
        let error = APIError.from(
            status: http.statusCode,
            body: result.data,
            retryAfter: Self.retryAfter(from: http)
        )
        return try await retry(error, request: request, attempt: attempt)
    }

    private func retry(_ error: APIError, request: URLRequest, attempt: Int) async throws -> Data {
        guard retryPolicy.shouldRetry(error, afterAttempt: attempt) else {
            throw error
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
        return try await perform(request, attempt: attempt + 1)
    }

    /// Liest `Retry-After` als Sekunden oder als HTTP-Datum (spec-ios §10).
    private static func retryAfter(from response: HTTPURLResponse) -> TimeInterval? {
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
