//
//  HermesSession.swift
//  Planer
//
//  Password-Login und Session-Cookies von Hermes (MARAAA-146).
//

import Foundation

/// Body von `POST /auth/password-login`.
///
/// Zweck: den vom Server belegten Vertrag als Wertetyp; `provider` ist immer
/// `basic`.
/// Grenze: trägt Benutzername und Passwort als Klartext — der Wert wird nur
/// an den Login-Request übergeben und niemals geloggt.
struct HermesLoginBody: Encodable, Sendable {
    let provider: String
    let username: String
    let password: String

    init(username: String, password: String) {
        self.provider = "basic"
        self.username = username
        self.password = password
    }
}

/// Der 401-Body von Hermes.
///
/// Vertrag (MARAAA-145): `{"error":"session_expired"|"unauthenticated",
/// "reason":"invalid_or_expired_session"|"no_cookie","login_url":"/login"}`.
/// Grenze: nur die beiden Felder, die über einen Re-Login entscheiden.
struct HermesAuthFailure: Decodable, Equatable, Sendable {
    let error: String?
    let reason: String?

    /// `reason`-Werte, die einen abgelaufenen Cookie-Stand bedeuten.
    static let expiredReasons: Set<String> = ["no_cookie", "invalid_or_expired_session"]
    /// `error`-Werte, die einen abgelaufenen Cookie-Stand bedeuten.
    static let expiredErrors: Set<String> = ["session_expired", "unauthenticated"]

    /// `true`, wenn der Body einen Re-Login verlangt.
    ///
    /// Ein 401 mit anderem Grund (z. B. fehlende Freigabe) bleibt ein Fehler
    /// und löst keinen Login aus.
    static func indicatesExpiredSession(_ body: Data) -> Bool {
        guard !body.isEmpty,
              let failure = try? JSONDecoder().decode(HermesAuthFailure.self, from: body)
        else {
            return false
        }
        return expiredReasons.contains(failure.reason ?? "")
            || expiredErrors.contains(failure.error ?? "")
    }
}

/// Prozessweiter Speicher der Hermes-Session-Cookies.
///
/// Zweck: die `Set-Cookie`-Werte des Logins für jeden folgenden Request als
/// `Cookie`-Header bereitstellen — auch für `NetworkClient.stream`.
/// Grenze: **nur im Prozessspeicher.** Kein `UserDefaults`, keine Datei, keine
/// Keychain: Cookies sind Sitzungszustand, keine dauerhaften Geheimnisse. Der
/// Zugriff ist über `NSLock` geschützt, weil `injectHeaders` synchron ist.
final class HermesCookieJar: @unchecked Sendable {
    static let shared = HermesCookieJar()

    private let lock = NSLock()
    private var cookies: [HTTPCookie] = []

    private init() {}

    /// `true`, sobald mindestens ein Cookie gespeichert ist.
    var hasCookies: Bool {
        lock.lock()
        defer { lock.unlock() }
        return !cookies.isEmpty
    }

    /// Die Header-Felder für einen Request (`["Cookie": "…"]`).
    ///
    /// Gebaut aus den gespeicherten Cookies über
    /// `HTTPCookie.requestHeaderFields(with:)`, nicht aus einem festen String.
    func requestHeaderFields() -> [String: String] {
        lock.lock()
        defer { lock.unlock() }
        return HTTPCookie.requestHeaderFields(with: cookies)
    }

    /// Ersetzt den gesamten Cookie-Stand durch die `Set-Cookie`-Werte eines
    /// neuen Logins.
    ///
    /// Ein alter Cookie darf nicht neben dem neuen weiter gesendet werden;
    /// Ersetzen und Lesen sind daher jeweils durch dasselbe `NSLock` geschützt.
    func replace(from response: HTTPURLResponse, url: URL) {
        let parsed = Self.parseCookies(from: response, url: url)
        lock.lock()
        defer { lock.unlock() }
        cookies = parsed
    }

    // MARK: Set-Cookie lesen

    /// Zerlegt die Antwort in `HTTPCookie`-Werte.
    private static func parseCookies(from response: HTTPURLResponse, url: URL) -> [HTTPCookie] {
        var result: [HTTPCookie] = []
        for value in setCookieValues(from: response) {
            result.append(
                contentsOf: HTTPCookie.cookies(
                    withResponseHeaderFields: ["Set-Cookie": value],
                    for: url
                )
            )
        }
        return result
    }

    /// Sammelt alle `Set-Cookie`-Zeilen einer Antwort.
    ///
    /// Foundation fasst gleichnamige Header je nach Plattform zu einem String
    /// oder zu einem Array zusammen; beides wird unterstützt.
    private static func setCookieValues(from response: HTTPURLResponse) -> [String] {
        var values: [String] = []
        for (key, value) in response.allHeaderFields {
            guard let name = key as? String,
                  name.caseInsensitiveCompare("Set-Cookie") == .orderedSame
            else {
                continue
            }
            if let list = value as? [String] {
                values.append(contentsOf: list)
            } else if let string = value as? String {
                values.append(contentsOf: splitSetCookieHeader(string))
            }
        }
        return values
    }

    /// Trennt mehrere, von Foundation zusammengefasste `Set-Cookie`-Werte.
    ///
    /// Ein Komma beginnt nur dann einen neuen Cookie, wenn danach direkt
    /// `name=` folgt. Das Komma in `Expires=Wed, 09 Jun 2026 10:00:00 GMT`
    /// bleibt dadurch Teil des Datums.
    private static func splitSetCookieHeader(_ raw: String) -> [String] {
        var result: [String] = []
        var start = raw.startIndex
        var index = raw.startIndex

        while index < raw.endIndex {
            if raw[index] == "," {
                var candidate = raw[raw.index(after: index)...]
                while candidate.first == " " || candidate.first == "\t" {
                    candidate = candidate.dropFirst()
                }
                if let equals = candidate.firstIndex(of: "=") {
                    let name = candidate[..<equals]
                    let isName = !name.isEmpty
                        && !name.contains(" ")
                        && !name.contains(";")
                        && !name.contains(",")
                    if isName {
                        result.append(String(raw[start..<index]))
                        start = raw.index(after: index)
                    }
                }
            }
            index = raw.index(after: index)
        }

        result.append(String(raw[start...]))
        return result
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }
}

/// Koalesziert gleichzeitige Logins zu genau einem Lauf.
///
/// Zweck: mehrere parallele 401-Antworten dürfen keinen Login-Sturm auslösen;
/// alle warten auf dieselbe `Task`.
/// Grenze: hält keinen Cookie-Stand — das ist `HermesCookieJar`.
actor HermesLoginCoordinator {
    static let shared = HermesLoginCoordinator()

    private var running: Task<Void, Error>?

    /// Führt `operation` aus oder wartet auf den bereits laufenden Login.
    func login(_ operation: @escaping @Sendable () async throws -> Void) async throws {
        if let running {
            return try await running.value
        }
        let task = Task { try await operation() }
        running = task
        defer { running = nil }
        try await task.value
    }
}
