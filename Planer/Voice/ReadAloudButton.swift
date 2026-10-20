//
//  ReadAloudButton.swift
//  Planer
//
//  Wiederverwendbarer „Vorlesen“-Knopf (spec-voice Rev 2 §6).
//

import SwiftUI

/// Liest einen sichtbaren Text vor — heute die To-Dos-Liste (§6).
///
/// Zweck: genau ein Knopf für „diesen sichtbaren Text vorlesen“; der Text
/// wird erst beim Tippen gebaut, damit die View nicht bei jeder Änderung
/// formatiert.
/// Grenze: kein eigener Zustand — läuft das Vorlesen, bricht derselbe Knopf
/// es ab. Einkauf und Rezepte bekommen **keine** Vorlese-Taste (§0).
struct ReadAloudButton: View {

    @EnvironmentObject private var voice: VoiceCoordinator

    private let text: () -> String

    init(text: @escaping () -> String) {
        self.text = text
    }

    var body: some View {
        Button {
            if voice.state.isSpeaking {
                voice.stopSpeaking()
            } else {
                voice.speak(text())
            }
        } label: {
            Label(
                voice.state.isSpeaking ? "Vorlesen beenden" : "Vorlesen",
                systemImage: voice.state.isSpeaking ? "stop.circle" : "speaker.wave.2"
            )
        }
        .disabled(!voice.readAloudEnabled || (text().isEmpty && !voice.state.isSpeaking))
        .accessibilityLabel(Text(voice.state.isSpeaking ? "Vorlesen beenden" : "Liste vorlesen"))
    }
}

#Preview("ReadAloudButton") {
    ReadAloudButton(text: { "Zwei To-Dos: Milch kaufen. Steuer erklären." })
        .environmentObject(VoiceCoordinator())
}
