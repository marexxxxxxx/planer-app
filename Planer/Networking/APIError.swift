//
//  APIError.swift
//  Planer
//
//  Einheitlicher Fehlertyp des Networking-Kerns (spec-ios §2.2, §10).
//

import Foundation

/// Server-Fehlerform aus spec-ios §2.2: `{"error":{"code","message","retryable"}}`.
struct APIErrorPayload: Decodable, Equatable, Sendable {
    struct Detail: Decodable, Equatable, Sendable {
        let code: String
        let message: String
        let retryable: Bool?
    }

    let error: Detail
}

/// Fehler, die der `NetworkClient` an die Feature-Schicht weitergibt.
///
/// Zweck: Transport-, HTTP- und Serverfehler in einem Typ bündeln, damit jedes
/// Feature dieselben Fehlerpfade (Timeout, 4xx, 5xx, leer) behandelt.
/// Grenze: keine Fachlogik und keine UI-Zustände; nur die Banner-Texte aus §10.
enum APIError: Error, Equatable, Sendable {
    case invalidConfiguration(String)
    case invalidRequest(String)
    case invalidResponse
    case cancelled
    case timeout
    case offline
    case unauthorized
    case forbidden
    /// Der Password-Login von Hermes wurde abgelehnt (MARAAA-146).
    ///
    /// Grenze: trägt bewusst keinen Servertext und keine Zugangsdaten — die
    /// Meldung darf niemals Benutzername oder Passwort enthalten.
    case hermesLoginFailed
    /// Hermes hat den Request mit einem 3xx beantwortet (MARAAA-154).
    ///
    /// Grenze: `cloudflareAccess` unterscheidet nur die Ursache; die `Location`
    /// selbst wird nicht angezeigt.
    case hermesAuthenticationRequired(cloudflareAccess: Bool)
    case notFound
    case conflict(message: String)
    case rateLimited(retryAfter: TimeInterval?)
    /// Der Server kennt die Methode an dieser Route nicht (HTTP 405).
    ///
    /// Bei Hermes heißt das fast immer, dass die Basis-URL auf das Dashboard
    /// zeigt: dort gibt es `POST /api/sessions` und die `/v1/*`-Chat-Endpunkte
    /// nicht, sie liegen auf dem API-Server (Port 8642).
    case methodNotAllowed
    case validation(message: String)
    case server(status: Int, code: String, message: String, retryable: Bool)
    case emptyResponse
    case decoding(String)

    /// HTTP-Status, sofern der Fehler aus einer Server-Antwort stammt.
    /// `nil` bedeutet: keine Antwort erhalten (Transport, Konfiguration, Dekodierung).
    var httpStatus: Int? {
        switch self {
        case .validation:
            return 400
        case .unauthorized:
            return 401
        case .forbidden:
            return 403
        case .notFound:
            return 404
        case .methodNotAllowed:
            return 405
        case .conflict:
            return 409
        case .rateLimited:
            return 429
        case .server(let status, _, _, _):
            return status
        case .invalidConfiguration, .invalidRequest, .invalidResponse, .cancelled,
             .timeout, .offline, .emptyResponse, .decoding, .hermesLoginFailed,
             .hermesAuthenticationRequired:
            return nil
        }
    }

    /// `true`, wenn ein unveränderter Wiederholungsversuch sinnvoll ist.
    /// 400/401/403/409 sind ausdrücklich nicht wiederholbar (spec-ios §10:
    /// ein Versionskonflikt wird angezeigt, nicht erneut gesendet).
    var isRetryable: Bool {
        switch self {
        case .timeout, .offline, .rateLimited:
            return true
        case .server(_, _, _, let retryable):
            return retryable
        case .conflict, .invalidConfiguration, .invalidRequest, .invalidResponse, .cancelled,
             .unauthorized, .forbidden, .notFound, .methodNotAllowed, .validation,
             .emptyResponse, .decoding,
             .hermesLoginFailed, .hermesAuthenticationRequired:
            return false
        }
    }

    /// Vom Server angeforderte Wartezeit (`Retry-After`), falls vorhanden.
    var retryAfter: TimeInterval? {
        if case .rateLimited(let retryAfter) = self {
            return retryAfter
        }
        return nil
    }

    /// Übersetzt eine Nicht-2xx-Antwort in `APIError`.
    static func from(status: Int, body: Data, retryAfter: TimeInterval?) -> APIError {
        let payload = decodePayload(body)
        let message = payload?.error.message
        switch status {
        case 400:
            return .validation(message: message ?? "Ungültige Anfrage")
        case 401:
            return .unauthorized
        case 403:
            return .forbidden
        case 404:
            return .notFound
        case 405:
            return .methodNotAllowed
        case 409:
            return .conflict(message: message ?? "Version veraltet")
        case 429:
            return .rateLimited(retryAfter: retryAfter)
        default:
            let code = payload?.error.code ?? (status >= 500 ? "INTERNAL" : "HTTP_\(status)")
            let fallback = HTTPURLResponse.localizedString(forStatusCode: status)
            return .server(
                status: status,
                code: code,
                message: message ?? fallback,
                retryable: payload?.error.retryable ?? (status >= 500)
            )
        }
    }

    /// Liest die Fehlerform; ein fremdes oder leeres Body-Format ist kein Fehler,
    /// dann gelten die HTTP-Semantik und der Status-Text.
    private static func decodePayload(_ body: Data) -> APIErrorPayload? {
        guard !body.isEmpty else { return nil }
        do {
            return try JSONDecoder().decode(APIErrorPayload.self, from: body)
        } catch {
            return nil
        }
    }
}

extension APIError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .invalidConfiguration(let detail):
            return "Konfiguration ungültig: \(detail)"
        case .invalidRequest(let detail):
            return "Anfrage ungültig: \(detail)"
        case .invalidResponse:
            return "Ungültige Antwort des Dienstes."
        case .cancelled:
            return "Vorgang abgebrochen."
        case .timeout:
            return "Zeitüberschreitung — Dienst nicht erreichbar."
        case .offline:
            return "Keine Netzwerkverbindung."
        case .unauthorized:
            return "Zugriff verweigert — Anmeldung prüfen."
        case .forbidden:
            return "Zugriff verweigert — CF-Access prüfen."
        case .hermesLoginFailed:
            return "Hermes-Anmeldung fehlgeschlagen — Benutzername und Passwort prüfen."
        case .hermesAuthenticationRequired(let cloudflareAccess):
            if cloudflareAccess {
                return "Cloudflare Access: Service-Token fehlt oder ungültig."
            }
            return "Hermes-Anmeldung erforderlich — Benutzername/Passwort prüfen."
        case .notFound:
            return "Eintrag nicht gefunden."
        case .methodNotAllowed:
            return "Methode nicht erlaubt (405). Bei Hermes heißt das fast immer: Die Basis-URL zeigt auf das Dashboard statt auf den API-Server (Port 8642) — dort fehlen die Chat-Endpunkte."
        case .conflict(let message):
            return "Konflikt: \(message)"
        case .rateLimited:
            return "Zu viele Anfragen — bitte später erneut versuchen."
        case .validation(let message):
            return "Eingabe ungültig: \(message)"
        case .server(_, let code, let message, _):
            return "Serverfehler (\(code)): \(message)"
        case .emptyResponse:
            return "Der Dienst hat keine Daten geliefert."
        case .decoding(let detail):
            return "Antwort nicht lesbar: \(detail)"
        }
    }
}
