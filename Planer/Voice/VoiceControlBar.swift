//
//  VoiceControlBar.swift
//  Planer
//
//  Sprachleiste im Chat: Mikrofon-Knopf, Live-Teiltext, Zustand
//  (spec-voice Rev 2 §6, §8).
//

import SwiftUI

/// Die sichtbare Bedienung der Sprachschicht.
///
/// Zweck: ein Ort für Mikrofon-Knopf, Zustandsanzeige, Live-Teiltext und
/// Stopp — der Chat bindet sie **einmal** über der Eingabe ein (§6).
/// Grenze: keine eigene Zustandslogik; jeder Tipp geht als Absicht an den
/// `VoiceCoordinator`, der allein über `transition(to:)` entscheidet.
/// Freihändig hört nur im Vordergrund zu — das steht als Hinweis in der
/// Leiste, nicht als Behauptung eines Weckworts (§8.3).
struct VoiceControlBar: View {

    @EnvironmentObject private var voice: VoiceCoordinator

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
            HStack(spacing: DesignTokens.Spacing.s) {
                microphoneButton

                Text(voice.statusText)
                    .font(DesignTokens.Typography.footnote)
                    .foregroundStyle(DesignTokens.Palette.secondaryLabel)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel(Text("Sprachzustand: \(voice.statusText)"))

                Spacer(minLength: DesignTokens.Spacing.xs)

                if voice.state.isSpeaking {
                    Button {
                        voice.stopSpeaking()
                    } label: {
                        Image(systemName: "stop.circle")
                            .font(.title3)
                    }
                    .accessibilityLabel("Vorlesen beenden")
                }

                if voice.state.failure != nil {
                    Button("Zurücksetzen") {
                        voice.reset()
                    }
                    .font(DesignTokens.Typography.footnote)
                    .accessibilityLabel("Sprachfehler zurücksetzen")
                }
            }

            if voice.state.isListening, !voice.liveTranscript.isEmpty {
                Text(voice.liveTranscript)
                    .font(DesignTokens.Typography.callout)
                    .foregroundStyle(DesignTokens.Palette.label)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel(Text("Erkannt: \(voice.liveTranscript)"))
            }

            if let notice = voice.notice {
                Text(notice)
                    .font(DesignTokens.Typography.footnote)
                    .foregroundStyle(DesignTokens.Palette.secondaryLabel)
                    .fixedSize(horizontal: false, vertical: true)
            }

            // §4 Punkt 2: solange der Knopf nicht bedienbar ist, bleibt der
            // Grund sichtbar — auch ohne Fehlerzustand und ohne „Zurücksetzen“.
            if let hint = voice.listenBlockedHint, voice.notice != hint {
                Text(hint)
                    .font(DesignTokens.Typography.footnote)
                    .foregroundStyle(DesignTokens.Palette.secondaryLabel)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel(Text(hint))
            }

            if voice.triggerMode == .handsFree, voice.isHandsFreeActive {
                Text("Freihändig hört nur zu, solange die App offen ist.")
                    .font(DesignTokens.Typography.footnote)
                    .foregroundStyle(DesignTokens.Palette.secondaryLabel)
            }
        }
        .padding(.horizontal, DesignTokens.Spacing.l)
        .padding(.vertical, DesignTokens.Spacing.xs)
        .background(DesignTokens.Palette.groupedBackground)
    }

    private var microphoneButton: some View {
        Button {
            voice.toggleListening()
        } label: {
            Image(systemName: microphoneSymbol)
                .font(.title3)
                .foregroundStyle(voice.state.isListening
                    ? DesignTokens.Palette.danger
                    : DesignTokens.Palette.label)
                .frame(width: 32, height: 32)
        }
        .disabled(!voice.canListen)
        .accessibilityLabel(Text(microphoneLabel))
        .accessibilityHint(Text("Diktat beginnt beziehungsweise endet; der Text landet im Eingabefeld."))
    }

    private var microphoneSymbol: String {
        if voice.state.isListening {
            return "mic.circle.fill"
        }
        return voice.canListen ? "mic.circle" : "mic.slash.circle"
    }

    private var microphoneLabel: String {
        if voice.state.isListening {
            return "Diktat beenden"
        }
        // §4 Punkt 3, §11.1: derselbe Text wie der dauerhafte Hinweis.
        if let hint = voice.listenBlockedHint {
            return hint
        }
        return voice.triggerMode == .handsFree
            ? "Freihändig zuhören starten"
            : "Diktat starten"
    }
}

#Preview("VoiceControlBar") {
    VoiceControlBar()
        .environmentObject(VoiceCoordinator())
}
