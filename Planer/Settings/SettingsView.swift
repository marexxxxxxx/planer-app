//
//  SettingsView.swift
//  Planer
//
//  Tab 5 „Einstellungen“: vier Dienst-Sektionen, Chat, Darstellung,
//  „Allgemein & Sicherheit“ und Sprache.
//

import SwiftUI

/// Einstellungs-Tab der App.
///
/// Zweck: einzige Oberfläche zum Hinterlegen von Basis-URL, CF-Access-Paar und
/// dienstspezifischem Token (Keychain) sowie der unkritischen Nutzerwerte des
/// Chats und des Erscheinungsbilds (`UserDefaults` über die Präferenz-Klassen).
/// Grenze: keine Fachkonfiguration der Feature-Tabs und keine Synchronisation
/// von Einstellungen zwischen Geräten.
///
/// Reihenfolge ist bindend (spec-chat Rev 6 §4.9): die vier Dienst-Sektionen
/// zuerst, danach Chat, Darstellung, Sperre, Sprache.
struct SettingsView: View {
    var body: some View {
        NavigationStack {
            Form {
                ServiceSettingsSection(service: .hermes)
                ServiceSettingsSection(service: .dashboard)
                ServiceSettingsSection(service: .grocy)
                ServiceSettingsSection(service: .mealie)
                ChatSettingsSection()
                AppearanceSettingsSection()
                AppLockSection()
                VoiceSettingsSection()
            }
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle("Einstellungen")
        }
    }
}
