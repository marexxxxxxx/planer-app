//
//  ServiceConfiguration.swift
//  Planer
//
//  Konfiguration eines Dienstes, ausschließlich aus der Keychain gelesen (spec-ios §4).
//

import Foundation

/// Fehler beim Laden einer Dienst-Konfiguration.
enum ServiceConfigurationError: Error, Equatable, LocalizedError {
    case missingBaseURL(ServiceType)
    case invalidBaseURL(String)
    case unexpectedPath(ServiceType, String)
    case incompleteCloudflareCredentials(ServiceType)

    var errorDescription: String? {
        switch self {
        case .missingBaseURL(let service):
            return "Für \(service.displayName) ist keine Basis-URL hinterlegt."
        case .invalidBaseURL(let value):
            return "Die Basis-URL muss eine gültige https-Adresse sein (http nur für localhost/127.0.0.1): \(value)"
        case .unexpectedPath(let service, let path):
            // Nur das abschließende `/api` wird still entfernt; jeder andere
            // Pfad ist ein Eingabefehler und bleibt sichtbar (MARAAA-142).
            return "\(service.displayName) erwartet den Origin ohne Pfad — bitte nur Schema und Host eintragen, nicht „\(path)“."
        case .incompleteCloudflareCredentials(let service):
            return "Für \(service.displayName) sind CF-Access-Client-ID und -Secret nur unvollständig hinterlegt."
        }
    }
}

/// Die für einen Request benötigten Werte eines Dienstes.
///
/// Zweck: bündelt Basis-URL, Cloudflare-Access-Paar und den dienstspezifischen
/// API-Account, damit der `NetworkClient` keine Keychain-Abfragen streut.
/// Grenze: wird ausschließlich über `KeychainManager` befüllt; es gibt keinen
/// zweiten Speicherort und keine Defaults aus einer Datei.
struct ServiceConfiguration: Equatable, Sendable {
    let service: ServiceType
    let baseURL: URL
    let cloudflareClientID: String?
    let cloudflareClientSecret: String?
    let apiKey: String?
    let apiToken: String?

    /// Liest die Konfiguration des Dienstes aus der Keychain (spec-ios §4).
    ///
    /// - Throws: `ServiceConfigurationError`, wenn die Basis-URL fehlt oder
    ///   keine gültige `https`-Adresse ist (Ausnahme: `http` auf
    ///   `localhost`/`127.0.0.1`) bzw. nur eine Hälfte des
    ///   CF-Access-Paares gesetzt ist.
    static func load(
        _ service: ServiceType,
        keychain: KeychainManager = KeychainManager()
    ) throws -> ServiceConfiguration {
        let rawBaseURL = try keychain.value(for: service, account: .baseURL)
        let baseURL = try normalizeBaseURL(rawBaseURL, for: service)

        let clientID = normalized(try keychain.value(for: service, account: .cloudflareClientID))
        let clientSecret = normalized(try keychain.value(for: service, account: .cloudflareClientSecret))
        guard (clientID == nil) == (clientSecret == nil) else {
            throw ServiceConfigurationError.incompleteCloudflareCredentials(service)
        }

        let apiKey: String?
        let apiToken: String?
        switch service {
        case .grocy:
            apiKey = normalized(try keychain.value(for: service, account: .apiKey))
            apiToken = nil
        case .hermes, .mealie:
            apiKey = nil
            apiToken = normalized(try keychain.value(for: service, account: .apiToken))
        case .dashboard:
            apiKey = nil
            apiToken = nil
        }

        return ServiceConfiguration(
            service: service,
            baseURL: baseURL,
            cloudflareClientID: clientID,
            cloudflareClientSecret: clientSecret,
            apiKey: apiKey,
            apiToken: apiToken
        )
    }

    /// Prüft einen Basis-URL-Wert gegen die Transport-Regel der App.
    ///
    /// Zweck: dieselbe Prüfung für das Laden aus der Keychain und für die
    /// Eingabe in den Einstellungen; zulässig ist ausschließlich `https`.
    /// Ausnahme: `http` auf `localhost`/`127.0.0.1` für lokale Tests.
    /// Grenze: prüft nur Schema und Host, nicht die Erreichbarkeit.
    static func validateBaseURL(_ rawValue: String?, for service: ServiceType) throws -> URL {
        guard let value = normalized(rawValue) else {
            throw ServiceConfigurationError.missingBaseURL(service)
        }
        // Die generierte Info.plist enthält bewusst keine ATS-Ausnahme; eine
        // http-Fremd-URL würde deshalb erst zur Laufzeit als „offline“
        // scheitern. Sie wird darum schon bei der Eingabe abgelehnt
        // (MARAAA-98, Review-Befund 9).
        guard let url = URL(string: value),
              let scheme = url.scheme?.lowercased(),
              let host = url.host?.lowercased()
        else {
            throw ServiceConfigurationError.invalidBaseURL(value)
        }

        switch scheme {
        case "https":
            return url
        case "http" where host == "localhost" || host == "127.0.0.1":
            return url
        default:
            throw ServiceConfigurationError.invalidBaseURL(value)
        }
    }

    /// Ergänzt bzw. entfernt den `/api`-Teil, den ein Dienst in seiner Basis-URL
    /// erwartet (MARAAA-133).
    ///
    /// Mealie, Grocy und Dashboard hängen ihre Endpunkte ohne `/api` an, weil
    /// die Feature-Repositories `/recipes`, `/objects/products` und `/tasks`
    /// senden; die Basis-URL muss deshalb auf `/api` enden. Hermes erwartet
    /// dagegen den nackten Origin, sonst würde `/api/sessions` zu
    /// `/api/api/sessions` (Chat-Guard F22); dort entfällt ausschließlich ein
    /// abschließendes `/api`, jeder andere Pfad wird abgelehnt (MARAAA-142).
    /// Grenze: normalisiert nur Schema, Host, Pfad und entfernt Query/Fragment;
    /// sie prüft nicht die Erreichbarkeit.
    static func normalizeBaseURL(_ rawValue: String?, for service: ServiceType) throws -> URL {
        let url = try validateBaseURL(rawValue, for: service)
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            throw ServiceConfigurationError.invalidBaseURL(url.absoluteString)
        }

        var path = components.path
        while path.count > 1 && path.hasSuffix("/") {
            path.removeLast()
        }
        if path == "/" {
            path = ""
        }

        switch service {
        case .mealie, .grocy, .dashboard:
            if !path.hasSuffix("/api") {
                path += "/api"
            }
        case .hermes:
            if path == "/api" {
                // Altbestand: ein gespeichertes `/api` entfällt, damit
                // `/api/sessions` nicht zu `/api/api/sessions` wird.
                path = ""
            } else if !path.isEmpty {
                // Ein fremder Pfad wird nicht still verworfen, sondern sichtbar
                // abgelehnt; sonst liefe der Request gegen einen Host-Pfad, den
                // der Nutzer nie eingegeben hat.
                throw ServiceConfigurationError.unexpectedPath(service, path)
            }
        }

        components.path = path
        components.query = nil
        components.fragment = nil
        guard let normalizedURL = components.url else {
            throw ServiceConfigurationError.invalidBaseURL(url.absoluteString)
        }
        return normalizedURL
    }

    /// Trimmt Werte und behandelt leere Strings wie „nicht gesetzt“.
    private static func normalized(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty
        else {
            return nil
        }
        return trimmed
    }
}
