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
    case incompleteCloudflareCredentials(ServiceType)

    var errorDescription: String? {
        switch self {
        case .missingBaseURL(let service):
            return "Für \(service.displayName) ist keine Basis-URL hinterlegt."
        case .invalidBaseURL(let value):
            return "Die Basis-URL muss eine gültige https-Adresse sein (http nur für localhost/127.0.0.1): \(value)"
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
        let baseURL = try validateBaseURL(rawBaseURL, for: service)

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
