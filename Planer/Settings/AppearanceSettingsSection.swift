//
//  AppearanceSettingsSection.swift
//  Planer
//
//  Einstellungs-Sektion „Darstellung“ (spec-chat Rev 6 §4.9, O6).
//

import SwiftUI

/// Sektion „Darstellung“ im Einstellungs-Tab.
///
/// Zweck: System/Hell/Dunkel an genau einer Stelle wählen; der Wert geht über
/// `AppearancePreferences` in `UserDefaults` und wird ausschließlich von
/// `PlanerApp` angewendet.
/// Grenze: keine Anwendung des Schemas — diese Sektion schreibt nur den Wert.
struct AppearanceSettingsSection: View {

    @ObservedObject private var preferences = AppearancePreferences.shared

    /// Der Setter ist der einzige Schreibweg; ein `@AppStorage`-Bypass würde
    /// eine zweite Wahrheit neben `AppearancePreferences` erzeugen.
    private var selection: Binding<AppAppearance> {
        Binding(
            get: { preferences.appearance },
            set: { preferences.setAppearance($0) }
        )
    }

    var body: some View {
        Section {
            Picker("Erscheinungsbild", selection: selection) {
                ForEach(AppAppearance.allCases) { appearance in
                    Text(appearance.title).tag(appearance)
                }
            }
        } header: {
            Text("Darstellung")
        } footer: {
            Text(
                "„System“ folgt der Geräteeinstellung und ist die Voreinstellung. "
                + "Die Wahl gilt für die ganze App, einschließlich des Sperrbildschirms."
            )
        }
    }
}

#Preview("AppearanceSettingsSection") {
    Form {
        AppearanceSettingsSection()
    }
}
