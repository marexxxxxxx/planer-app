//
//  AppearancePreferences.swift
//  Planer
//
//  Wählbares Erscheinungsbild System/Hell/Dunkel (spec-chat Rev 6 §4.8, O6).
//

import SwiftUI

/// Die drei wählbaren Erscheinungsbilder.
///
/// Zweck: „Hell“ ist eine **Wahl**, kein Farbdefekt — die Palette besteht aus
/// iOS-Systemfarben und folgt dem erzwungenen Schema von selbst.
/// Grenze: keine Farbwerte; `colorScheme` ist der einzige Übergang in SwiftUI.
enum AppAppearance: String, CaseIterable, Identifiable, Sendable {
    case system
    case light
    case dark

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: return "System"
        case .light: return "Hell"
        case .dark: return "Dunkel"
        }
    }

    /// `nil` = der Systemeinstellung folgen.
    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
}

/// Einzige Quelle des Erscheinungsbilds (O6).
///
/// Zweck: den Wert lesen, speichern und an **einer** Stelle an die Wurzel
/// geben (`PlanerApp`). Kein Feature setzt `preferredColorScheme` selbst.
/// Grenze: ein unkritischer Wert in `UserDefaults`; keine Secrets.
@MainActor
final class AppearancePreferences: ObservableObject {

    static let shared = AppearancePreferences()

    static let key = "appAppearance"

    @Published private(set) var appearance: AppAppearance

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        // Unbekannter oder fehlender Raw-Wert fällt auf die Systemeinstellung
        // zurück (F-R6-10); der Store bleibt dabei unangetastet.
        let stored = defaults.string(forKey: Self.key) ?? ""
        self.appearance = AppAppearance(rawValue: stored) ?? .system
    }

    func setAppearance(_ value: AppAppearance) {
        if value != appearance {
            defaults.set(value.rawValue, forKey: Self.key)
        }
        appearance = value
    }

    /// Für die Wurzel; identisch zu `appearance.colorScheme`.
    var colorScheme: ColorScheme? { appearance.colorScheme }
}
