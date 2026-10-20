//
//  SettingsView.swift
//  Planer
//
//  Tab 5 „Einstellungen“: vier Dienst-Sektionen plus „Allgemein & Sicherheit“.
//

import SwiftUI

/// Einstellungs-Tab der App.
///
/// Zweck: einzige Oberfläche zum Hinterlegen von Basis-URL, CF-Access-Paar und
/// dienstspezifischem Token; alle Werte landen über `KeychainManager` in der Keychain.
/// Grenze: keine Fachkonfiguration der Feature-Tabs und keine Synchronisation
/// von Einstellungen zwischen Geräten.
struct SettingsView: View {
    var body: some View {
        NavigationStack {
            Form {
                ServiceSettingsSection(service: .hermes)
                ServiceSettingsSection(service: .dashboard)
                ServiceSettingsSection(service: .grocy)
                ServiceSettingsSection(service: .mealie)
                AppLockSection()
            }
            .navigationTitle("Einstellungen")
        }
    }
}
