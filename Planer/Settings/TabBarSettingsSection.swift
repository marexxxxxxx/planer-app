//
//  TabBarSettingsSection.swift
//  Planer
//
//  Einstellungs-Sektion „Tab-Bar“: Tabs aus der unteren Leiste nehmen
//  (MARAAA-190).
//

import SwiftUI

/// Sektion „Tab-Bar“ im Einstellungs-Tab.
///
/// Zweck: To-Dos, Einkauf und Rezepte ausblenden und jederzeit wieder
/// einblenden; der Wert liegt über `TabVisibilityPreferences` in `UserDefaults`
/// und überlebt den Neustart.
/// Grenze: Chat und Einstellungen erscheinen hier nicht — ohne sie wäre der
/// Rückweg in diese Sektion versperrt (`AppTab.isHideable`).
struct TabBarSettingsSection: View {

    @ObservedObject private var preferences = TabVisibilityPreferences.shared

    var body: some View {
        Section {
            ForEach(AppTab.hideableTabs, id: \.self) { tab in
                Toggle("\(tab.title) anzeigen", isOn: visibilityBinding(for: tab))
            }
        } header: {
            Text("Tab-Bar")
        } footer: {
            Text(
                "Ausgeblendete Tabs verschwinden aus der unteren Leiste und lassen sich "
                + "hier jederzeit wieder einblenden. Chat und Einstellungen bleiben immer sichtbar."
            )
        }
    }

    /// Ein Schalter = ein Tab; der Setter ist der einzige Schreibweg in den
    /// Speicher, ein zweiter Zustand neben `TabVisibilityPreferences` entsteht nicht.
    private func visibilityBinding(for tab: AppTab) -> Binding<Bool> {
        Binding(
            get: { preferences.isVisible(tab) },
            set: { preferences.setVisible($0, for: tab) }
        )
    }
}

#Preview("TabBarSettingsSection") {
    Form {
        TabBarSettingsSection()
    }
}
