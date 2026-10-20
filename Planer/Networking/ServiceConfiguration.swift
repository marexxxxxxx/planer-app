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
            return "Die Basis-URL ist ungültig: \(value)"
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
    ///   ungültig ist bzw. nur eine Hälfte des CF-Access-Paares gesetzt ist.
    static func load(
        _ service: ServiceType,
        keychain: KeychainManager = KeychainManager()
    ) throws -> ServiceConfiguration {
        let rawBaseURL = try keychain.value(for: service, account: .baseURL)
        guard let baseURLValue = normalized(rawBaseURL) else {
            throw ServiceConfigurationError.missingBaseURL(service)
        }
        guard let baseURL = URL(string: baseURLValue),
              let scheme = baseURL.scheme?.lowercased(),
              scheme == "https" || scheme == "http",
              baseURL.host != nil
        else {
            throw ServiceConfigurationError.invalidBaseURL(baseURLValue)
        }

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
