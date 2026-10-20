//
//  VoiceSettingsSection.swift
//  Planer
//
//  Einstellungen der Sprachschicht (spec-voice Rev 2 §8.3, §9).
//

import SwiftUI

/// Die Sektion „Sprache“ im Einstellungs-Tab.
///
/// Zweck: Vorlesen, Diktat und Auslöse-Modus an genau einer Stelle schaltbar;
/// die Werte liegen als `@AppStorage`-taugliche `UserDefaults`-Schlüssel im
/// `VoiceCoordinator` (§9).
/// Grenze: keine Modell-Umschaltung — der Router und das lokale Modell sind
/// WP V5 und ausdrücklich Phase 2 (§2/V5, §10). Die Zeile „Modellort“ nennt
/// deshalb den heutigen Stand, statt einen Schalter ohne Wirkung zu zeigen.
struct VoiceSettingsSection: View {

    @EnvironmentObject private var voice: VoiceCoordinator

    var body: some View {
        Section {
            Toggle(isOn: $voice.readAloudEnabled) {
                Text("Agent-Antworten und To-Dos vorlesen")
            }

            Toggle(isOn: $voice.dictationEnabled) {
                Text("Diktat erlauben")
            }
            .disabled(voice.triggerMode == .readAloudOnly)

            Picker("Auslösung", selection: $voice.triggerMode) {
                ForEach(VoiceTriggerMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }

            LabeledContent("Modellort", value: "Hermes")
        } header: {
            Text("Sprache")
        } footer: {
            Text(
                "Freihändig hört nur zu, solange die App offen ist; das kostet Akku. "
                + "Ein Weckwort im Hintergrund gibt es auf iOS für Dritt-Apps nicht."
            )
        }
    }
}

#Preview("VoiceSettingsSection") {
    Form {
        VoiceSettingsSection()
    }
    .environmentObject(VoiceCoordinator())
}
