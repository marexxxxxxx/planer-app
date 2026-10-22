//
//  ChatPreferences.swift
//  Planer
//
//  Die drei Nutzereinstellungen des Chat-Tabs (spec-chat Rev 6 §4.1, O1/O7/O10).
//

import Combine
import Foundation

/// Einzige Quelle der drei Chat-Nutzereinstellungen (O1, O7, O10).
///
/// Zweck: Stream-Timeout, REST-Timeout und Hermes-Profil an genau einer Stelle
/// lesen, klemmen und speichern; `ChatViewModel` baut seine Konfiguration nur
/// hieraus.
/// Grenze: keine Netzwerk-, UI- oder Chat-Zustandslogik; keine Geheimnisse.
@MainActor
final class ChatPreferences: ObservableObject {

    static let shared = ChatPreferences()

    static let streamIdleTimeoutKey = "chatStreamIdleTimeout"
    static let restTimeoutKey = "chatRestTimeout"
    static let profileKey = "chatHermesProfile"

    static let defaultStreamIdleTimeout = 900
    static let defaultRestTimeout = 30
    static let streamIdleTimeoutRange: ClosedRange<Int> = 60...3600
    static let restTimeoutRange: ClosedRange<Int> = 10...300

    /// Untätigkeitsgrenze des Antwortstroms in Sekunden.
    @Published private(set) var streamIdleTimeout: Int
    /// Grenze einer Serveranfrage (Liste, Nachrichten, Anlegen, Freigabe).
    @Published private(set) var restTimeout: Int
    /// "" = Default-Profil (kein Pfadpräfix).
    @Published private(set) var profile: String

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        // `object(forKey:) as? Int` statt `integer(forKey:)`: ein fehlender
        // Schlüssel liefert dort `0` und würde still auf die Untergrenze klemmen.
        let storedStream = defaults.object(forKey: Self.streamIdleTimeoutKey) as? Int
        self.streamIdleTimeout = Self.clampStreamIdleTimeout(
            storedStream ?? Self.defaultStreamIdleTimeout
        )
        let storedRest = defaults.object(forKey: Self.restTimeoutKey) as? Int
        self.restTimeout = Self.clampRestTimeout(storedRest ?? Self.defaultRestTimeout)
        self.profile = Self.normalizeProfile(defaults.string(forKey: Self.profileKey) ?? "") ?? ""
    }

    // MARK: Schreiben

    /// Klemmt auf `streamIdleTimeoutRange`; ein Wert außerhalb wird gezogen,
    /// nicht abgelehnt (Rev 6 §3.2.2).
    func setStreamIdleTimeout(_ seconds: Int) {
        let clamped = Self.clampStreamIdleTimeout(seconds)
        if clamped != streamIdleTimeout {
            defaults.set(clamped, forKey: Self.streamIdleTimeoutKey)
        }
        streamIdleTimeout = clamped
    }

    /// Klemmt auf `restTimeoutRange`.
    func setRestTimeout(_ seconds: Int) {
        let clamped = Self.clampRestTimeout(seconds)
        if clamped != restTimeout {
            defaults.set(clamped, forKey: Self.restTimeoutKey)
        }
        restTimeout = clamped
    }

    /// `false` = Name ungültig; es wird nichts gespeichert und nichts geändert.
    @discardableResult
    func setProfile(_ name: String) -> Bool {
        guard let normalized = Self.normalizeProfile(name) else { return false }
        if normalized != profile {
            defaults.set(normalized, forKey: Self.profileKey)
        }
        profile = normalized
        return true
    }

    /// Fertige Konfiguration für API/Provider; liest nur die drei Werte.
    var configuration: HermesChatConfiguration {
        var configuration = HermesChatConfiguration()
        configuration.profile = profile
        configuration.streamIdleTimeout = TimeInterval(streamIdleTimeout)
        configuration.restTimeout = TimeInterval(restTimeout)
        return configuration
    }

    // MARK: Grenzen

    static func clampStreamIdleTimeout(_ seconds: Int) -> Int {
        let range = streamIdleTimeoutRange
        return min(max(seconds, range.lowerBound), range.upperBound)
    }

    static func clampRestTimeout(_ seconds: Int) -> Int {
        let range = restTimeoutRange
        return min(max(seconds, range.lowerBound), range.upperBound)
    }

    /// `nil` = ungültig, `""` = Default, sonst normalisiert (klein, getrimmt).
    static func normalizeProfile(_ raw: String) -> String? {
        let normalized = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if normalized.isEmpty { return "" }
        guard normalized.count <= 64 else { return nil }
        guard normalized.range(
            of: "^[a-z0-9][a-z0-9_-]*$",
            options: .regularExpression
        ) != nil else { return nil }
        return normalized
    }
}
