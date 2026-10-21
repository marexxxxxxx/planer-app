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
/// Grenze: keine Statusprüfung; die entscheidet der Aufrufer, weil ein
/// Fehlertext im Strom stehen kann. Einzige Ausnahme ist der Hermes-401, den
/// `stream` für den Re-Login selbst liest.
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
    /// Obergrenze des 401-Bodys, aus dem der Re-Login-Grund gelesen wird.
    private static let maxAuthBodyBytes = 4_096
    /// HTTP-Status, die als Weiterleitung gelten (MARAAA-154).
    private static let redirectStatusCodes: Set<Int> = [301, 302, 303, 307, 308]

    init(
        session: URLSession = NetworkClient.cookieFreeSession,
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
        return try await perform(
            urlRequest,
            service: service,
            configuration: configuration,
            attempt: 1
        )
    }

    /// Führt den Request aus und liefert Rohdaten plus HTTP-Kopf.
    ///
    /// Zweck: Der Verbindungstest der Einstellungen muss Status und Body sehen,
    /// um 401, 403, 404 und die HTML-Anmeldeseite von Cloudflare Access zu
    /// unterscheiden; `send` wirft Nicht-2xx und verliert dabei den Body.
    /// Grenze: wiederholt wie `send` nur GET bei Timeout/Offline/5xx. Für
    /// Hermes werden Redirects nie verfolgt; der Verbindungstest nutzt für alle
    /// Dienste `NetworkClient.connectionTest`, der Redirects stehen lässt.
    func sendRaw(
        _ request: APIRequest,
        for service: ServiceType
    ) async throws -> (data: Data, response: HTTPURLResponse) {
        let configuration = try loadConfiguration(for: service)
        let urlRequest = try makeURLRequest(request, configuration: configuration)
        return try await performRaw(
            urlRequest,
            service: service,
            configuration: configuration,
            attempt: 1
        )
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
    /// Grenze: **kein automatischer Retry** im Sinne von `send` — ein Strom
    /// wird nicht wiederholt; die aufrufende Schicht entscheidet. Ausnahme ist
    /// die Hermes-Sitzung (MARAAA-146/154): ein 401 mit abgelaufenen Cookies
    /// oder ein 3xx löst genau einen Re-Login und eine Wiederholung aus. Andere
    /// Nicht-2xx-Antworten werden nicht geworfen, weil der Fehlertext im Strom
    /// stehen kann: der Aufrufer prüft `response.statusCode` und liest den Body
    /// begrenzt. Nur ein Hermes-401 muss dafür vorher gelesen werden.
    func stream(_ request: APIRequest, for service: ServiceType) async throws -> StreamingResponse {
        let configuration = try loadConfiguration(for: service)
        let urlRequest = try makeURLRequest(request, configuration: configuration)
        return try await performStream(
            urlRequest,
            service: service,
            configuration: configuration,
            didRelogin: false
        )
    }

    private func performStream(
        _ urlRequest: URLRequest,
        service: ServiceType,
        configuration: ServiceConfiguration,
        didRelogin: Bool
    ) async throws -> StreamingResponse {
        do {
            let (bytes, response) = try await urlSession(for: service).bytes(for: urlRequest)
            guard let http = response as? HTTPURLResponse else {
                throw APIError.invalidResponse
            }

            // Der 401-Body entscheidet über den Re-Login und muss dafür aus dem
            // Strom gelesen werden. Ein 3xx bleibt ohne Body sichtbar; beide
            // betreffen ausschließlich Hermes (MARAAA-146/154).
            let redirect = service == .hermes && Self.isRedirect(http.statusCode)
            if service == .hermes, http.statusCode == 401 || redirect {
                var body = Data()
                if http.statusCode == 401 {
                    body = (try? await Self.collect(bytes, limit: Self.maxAuthBodyBytes)) ?? Data()
                }
                let expired = HermesAuthFailure.indicatesExpiredSession(body)
                if !didRelogin, expired || redirect {
                    try await loginHermes(configuration: configuration)
                    var retried = urlRequest
                    injectHermesCookies(into: &retried)
                    return try await performStream(
                        retried,
                        service: service,
                        configuration: configuration,
                        didRelogin: true
                    )
                }
                if redirect {
                    throw Self.hermesRedirectError(http)
                }
                throw APIError.from(
                    status: http.statusCode,
                    body: body,
                    retryAfter: Self.retryAfter(from: http)
                )
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
    /// Cloudflare Access gilt für alle Dienste. Mealie nutzt seinen API-Token,
    /// Grocy seinen API-Key, das Dashboard keinen. Hermes setzt seit
    /// MARAAA-146 keinen `Authorization`-Header mehr: dort authentifizieren
    /// die Cloudflare-Header den Dienst und die Password-Login-Cookies die
    /// Sitzung. Auch der Login-Request läuft durch diese Injektion.
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
        case .mealie:
            if let token = configuration.apiToken {
                request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            }
        case .hermes:
            injectHermesCookies(into: &request)
        case .grocy:
            if let key = configuration.apiKey {
                request.setValue(key, forHTTPHeaderField: "GROCY-API-KEY")
            }
        case .dashboard:
            break
        }
    }

    /// Setzt den `Cookie`-Header aus dem Prozessspeicher der Hermes-Session.
    ///
    /// Der Header entsteht über `HTTPCookie.requestHeaderFields(with:)` aus den
    /// gespeicherten Cookies — kein fester String, kein alter Stand nach einem
    /// Re-Login. Ohne Cookies bleibt der Request cookiefrei.
    private func injectHermesCookies(into request: inout URLRequest) {
        let fields = HermesCookieJar.shared.requestHeaderFields()
        if let cookie = fields["Cookie"], !cookie.isEmpty {
            request.setValue(cookie, forHTTPHeaderField: "Cookie")
        } else {
            request.setValue(nil, forHTTPHeaderField: "Cookie")
        }
    }

    // MARK: - Ausführung und Retry

    /// Wählt die Session je Dienst.
    ///
    /// Hermes läuft ausschließlich über die redirect-blockierende Session: Ein
    /// 302 auf `/login` oder Cloudflare Access bleibt damit als Antwort sichtbar,
    /// statt als GET-Wiederholung an einem POST-only-Endpunkt zu landen
    /// (MARAAA-154). Mealie, Grocy und Dashboard behalten ihre bisherige Session.
    private func urlSession(for service: ServiceType) -> URLSession {
        if service == .hermes {
            return NetworkClient.redirectBlockingSession
        }
        return session
    }

    private func loadConfiguration(for service: ServiceType) throws -> ServiceConfiguration {
        do {
            return try ServiceConfiguration.load(service, keychain: keychain)
        } catch {
            throw APIError.invalidConfiguration(error.localizedDescription)
        }
    }

    private func perform(
        _ request: URLRequest,
        service: ServiceType,
        configuration: ServiceConfiguration,
        attempt: Int
    ) async throws -> Data {
        let result = try await performRaw(
            request,
            service: service,
            configuration: configuration,
            attempt: attempt
        )
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
    /// Methodenprüfung liegt in `waitBeforeRetry`. Zusätzlich behandelt genau
    /// der Hermes-Zweig einen 401 mit abgelaufenen Cookies: `didRelogin`
    /// begrenzt den Re-Login auf einen Versuch (MARAAA-146).
    private func performRaw(
        _ request: URLRequest,
        service: ServiceType,
        configuration: ServiceConfiguration,
        attempt: Int,
        didRelogin: Bool = false
    ) async throws -> (data: Data, response: HTTPURLResponse) {
        // Der Netzwerkaufruf steht bewusst allein im do-Block: Fehler aus
        // `waitBeforeRetry` dürfen nicht erneut von diesem catch abgefangen
        // werden.
        let result: (data: Data, response: URLResponse)
        do {
            result = try await urlSession(for: service).data(for: request)
        } catch let error as URLError {
            if error.code == .cancelled {
                throw APIError.cancelled
            }
            let mapped: APIError = error.code == .timedOut ? .timeout : .offline
            guard try await waitBeforeRetry(mapped, request: request, attempt: attempt) else {
                throw mapped
            }
            return try await performRaw(
                request,
                service: service,
                configuration: configuration,
                attempt: attempt + 1,
                didRelogin: didRelogin
            )
        } catch is CancellationError {
            throw APIError.cancelled
        } catch {
            // Kein `error.localizedDescription`: die kann die URL enthalten.
            throw APIError.invalidRequest("Verbindung zum Dienst nicht möglich.")
        }

        guard let http = result.response as? HTTPURLResponse else {
            throw APIError.invalidResponse
        }

        // MARAAA-146/154: Ein Hermes-401 mit abgelaufener Sitzung und jeder
        // Hermes-3xx werden genau einmal durch einen neuen Password-Login und
        // eine Wiederholung ersetzt. Der zweite 3xx ist ein Fehler, keine
        // Schleife; der zweite 401 bleibt ebenfalls ein Fehler.
        let expired = service == .hermes
            && http.statusCode == 401
            && HermesAuthFailure.indicatesExpiredSession(result.data)
        let redirect = service == .hermes && Self.isRedirect(http.statusCode)
        if !didRelogin, expired || redirect {
            try await loginHermes(configuration: configuration)
            var retried = request
            injectHermesCookies(into: &retried)
            return try await performRaw(
                retried,
                service: service,
                configuration: configuration,
                attempt: attempt,
                didRelogin: true
            )
        }
        if redirect {
            throw Self.hermesRedirectError(http)
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
        return try await performRaw(
            request,
            service: service,
            configuration: configuration,
            attempt: attempt + 1,
            didRelogin: didRelogin
        )
    }

    // MARK: - Redirects

    /// `true` für die HTTP-Status, die eine Weiterleitung sind.
    private static func isRedirect(_ statusCode: Int) -> Bool {
        redirectStatusCodes.contains(statusCode)
    }

    /// Übersetzt einen Hermes-3xx in einen Fehler mit Ursache.
    ///
    /// Ein `Location` auf `cloudflareaccess.com` heißt: das Service-Token fehlt;
    /// jede andere Weiterleitung heißt: die Hermes-Sitzung fehlt.
    private static func hermesRedirectError(_ response: HTTPURLResponse) -> APIError {
        let location = response.value(forHTTPHeaderField: "Location")?.lowercased() ?? ""
        return .hermesAuthenticationRequired(
            cloudflareAccess: location.contains("cloudflareaccess.com")
        )
    }

    // MARK: - Hermes-Anmeldung

    /// Loggt sich mit Benutzername/Passwort ein und übernimmt die Cookies.
    ///
    /// Der Login-Request wird über `makeURLRequest`/`injectHeaders` gebaut und
    /// trägt damit dieselben Cloudflare-Header wie jeder andere Request. Die
    /// Koaleszierung liegt in `HermesLoginCoordinator`: parallele 401s warten
    /// auf denselben Login statt einen Sturm auszulösen.
    private func loginHermes(configuration: ServiceConfiguration) async throws {
        guard configuration.service == .hermes else { return }
        guard let username = configuration.username,
              let password = configuration.password
        else {
            throw APIError.invalidConfiguration(
                "Für Hermes sind Benutzername und Passwort nicht hinterlegt."
            )
        }

        var loginRequest = try makeURLRequest(
            APIRequest(
                method: .post,
                path: "/auth/password-login",
                body: try Self.makeLoginBody(username: username, password: password),
                headers: ["Content-Type": "application/json"]
            ),
            configuration: configuration
        )
        // Eine abgelaufene Session-Cookie gehört nicht an den Login.
        loginRequest.setValue(nil, forHTTPHeaderField: "Cookie")

        let session = urlSession(for: .hermes)
        try await HermesLoginCoordinator.shared.login {
            try await Self.performLogin(loginRequest, session: session)
        }
    }

    private static func makeLoginBody(username: String, password: String) throws -> Data {
        do {
            return try JSONEncoder().encode(
                HermesLoginBody(username: username, password: password)
            )
        } catch {
            throw APIError.invalidRequest("Hermes-Anmeldung nicht serialisierbar.")
        }
    }

    /// Führt genau einen Login aus und speichert die `Set-Cookie`-Werte.
    ///
    /// Grenze: kein Retry — ein abgelehnter Login wird als
    /// `APIError.hermesLoginFailed` gemeldet; 403 bleibt der CF-Hinweis. Der
    /// Fehlertext enthält weder Benutzername noch Passwort.
    private static func performLogin(_ request: URLRequest, session: URLSession) async throws {
        let result: (data: Data, response: URLResponse)
        do {
            result = try await session.data(for: request)
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
        }

        guard let http = result.response as? HTTPURLResponse else {
            throw APIError.invalidResponse
        }
        // Auch der Login darf nicht in eine HTML-Anmeldeseite laufen; der 3xx
        // bleibt durch die redirect-blockierende Session sichtbar.
        if Self.isRedirect(http.statusCode) {
            throw Self.hermesRedirectError(http)
        }
        guard (200..<300).contains(http.statusCode) else {
            if http.statusCode == 401 {
                throw APIError.hermesLoginFailed
            }
            throw APIError.from(
                status: http.statusCode,
                body: result.data,
                retryAfter: Self.retryAfter(from: http)
            )
        }

        guard let url = http.url ?? request.url else {
            throw APIError.invalidResponse
        }
        // Der Login ersetzt den Sitzungsstand vollständig; ein alter Cookie
        // darf nicht neben dem neuen weiter gesendet werden.
        HermesCookieJar.shared.replace(from: http, url: url)
        // Ein Login ohne Cookie wäre für jeden Folgerequest wertlos; lieber
        // sichtbar scheitern als still weiterlaufen.
        guard HermesCookieJar.shared.hasCookies else {
            throw APIError.hermesLoginFailed
        }
    }

    /// Liest höchstens `limit` Bytes aus einem Antwortstrom.
    ///
    /// Zweck: nur der kleine JSON-Body eines Hermes-401 wird vor der Entscheidung
    /// über den Re-Login gebraucht; Erfolgsströme bleiben unangetastet.
    private static func collect(_ bytes: URLSession.AsyncBytes, limit: Int) async throws -> Data {
        var data = Data()
        for try await byte in bytes {
            data.append(byte)
            if data.count >= limit {
                break
            }
        }
        return data
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
    /// Standardsitzung ohne automatische Cookie-Ablage.
    ///
    /// Hermes-Cookies liegen ausschließlich in `HermesCookieJar` (Prozess-
    /// speicher); `URLSession` darf sie weder selbst speichern noch einem
    /// Request ungefragt hinzufügen. Für die übrigen Dienste ändert das nichts.
    static let cookieFreeSession: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        return URLSession(configuration: configuration)
    }()

    /// Client für „Test Verbindung“, der HTTP-Redirects nicht folgt.
    ///
    /// Zweck: Cloudflare Access antwortet unauthentifiziert mit 302 auf
    /// `*.cloudflareaccess.com`; eine Session, die dem Redirect folgt, liefert
    /// danach 200-HTML und verdeckt damit die Ursache (MARAAA-132 §5 B2).
    static let connectionTest = NetworkClient(session: redirectBlockingSession)

    /// Session, die HTTP-Redirects nicht folgt.
    ///
    /// Hermes nutzt sie für `send`, `sendRaw`, `stream` und den Login; die
    /// übrigen Dienste behalten ihre Session. `connectionTest` nutzt sie für
    /// alle Dienste.
    private static let redirectBlockingSession: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 10
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
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
