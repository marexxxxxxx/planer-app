import SwiftUI

/// Tab-Provider für Einstellungen. Die View gehört I2
/// (`Planer/Settings/SettingsView.swift`); dieser Provider ist die Naht, an der
/// `TabRegistry` den Tab einhängt, ohne I2-Dateien zu kennen.
enum SettingsTabDefinition: TabDefinition {
    static func makeRootView() -> some View {
        SettingsView()
    }
}
