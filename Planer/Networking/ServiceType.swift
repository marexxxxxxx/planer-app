//
//  ServiceType.swift
//  Planer
//
//  Die vier Fremdsysteme der App und ihre Keychain-Accounts (spec-ios §4).
//

import Foundation

/// Ein Keychain-Account eines Dienstes.
///
/// Zweck: benennt die in spec-ios §4 festgelegten Account-Namen als Typsicherheit.
/// Grenze: die Rohwerte sind Vertragsbestandteil und dürfen nicht umbenannt werden.
enum ServiceCredential: String, CaseIterable, Sendable {
    case baseURL = "base_url"
    case cloudflareClientID = "cf_client_id"
    case cloudflareClientSecret = "cf_client_secret"
    case apiToken = "api_token"
    case apiKey = "api_key"
    /// Hermes-Anmeldung: Benutzername des Password-Logins (MARAAA-146).
    case username = "username"
    /// Hermes-Anmeldung: Klartext-Passwort des Password-Logins (MARAAA-146).
    case password = "password"

    /// Anzeigename für die Einstellungen.
    var displayName: String {
        switch self {
        case .baseURL:
            return "Basis-URL"
        case .cloudflareClientID:
            return "CF-Access-Client-ID"
        case .cloudflareClientSecret:
            return "CF-Access-Client-Secret"
        case .apiToken:
            return "API-Token"
        case .apiKey:
            return "API-Key"
        case .username:
            return "Benutzername"
        case .password:
            return "Passwort"
        }
    }
}

/// Die vier Dienste, mit denen die App spricht.
///
/// Zweck: Schlüssel für Konfiguration, Keychain-Service und Einstellungs-Sektion.
/// Grenze: enthält keine Endpunkte und keine Header; beides gehört in
/// `NetworkClient` bzw. in die Feature-WPs.
enum ServiceType: String, CaseIterable, Identifiable, Sendable {
    case hermes
    case dashboard
    case grocy
    case mealie

    var id: String { rawValue }

    /// Anzeigename der Einstellungs-Sektion.
    var displayName: String {
        switch self {
        case .hermes:
            return "Hermes"
        case .dashboard:
            return "Dashboard"
        case .grocy:
            return "Grocy"
        case .mealie:
            return "Mealie"
        }
    }

    /// `kSecAttrService` aus spec-ios §4.
    var keychainService: String {
        switch self {
        case .hermes:
            return "com.marex.planer.hermes"
        case .dashboard:
            return "com.marex.planer.dashboard"
        case .grocy:
            return "com.marex.planer.grocy"
        case .mealie:
            return "com.marex.planer.mealie"
        }
    }

    /// Dienstspezifischer API-Account; das Dashboard hat keinen (spec-ios §2.2).
    ///
    /// Hermes hat seit MARAAA-146 keinen API-Token mehr: die Anmeldung läuft
    /// über Benutzername/Passwort (`.username`, `.password`) und danach über
    /// Session-Cookies.
    var apiCredential: ServiceCredential? {
        switch self {
        case .mealie:
            return .apiToken
        case .grocy:
            return .apiKey
        case .hermes, .dashboard:
            return nil
        }
    }
}
