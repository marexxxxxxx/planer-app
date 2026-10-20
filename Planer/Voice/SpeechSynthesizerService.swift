//
//  SpeechSynthesizerService.swift
//  Planer
//
//  Deutsche Sprachausgabe auf dem Gerät (spec-voice §2/V1, §11).
//

import AVFoundation
import Foundation

/// Der Vertrag der Sprachausgabe (spec-voice §11).
///
/// Zweck: der Koordinator kennt nur diese drei Elemente; die AVFoundation-
/// Typen bleiben hinter dieser Datei.
/// Grenze: kein Zustand und keine Warteschlange nach außen — die führt
/// `AVSpeechSynthesizer` selbst.
@MainActor
protocol SpeechSynthesizing: AnyObject {
    var isSpeaking: Bool { get }
    func speak(_ text: String) throws
    func stop()
}

/// Fehler der Sprachausgabe (spec-voice §11.1).
enum SpeechSynthesisError: Error, Equatable, LocalizedError {
    /// Auf dem Gerät ist keine deutsche Stimme verfügbar (R-V7).
    case keineDeutscheStimme

    var errorDescription: String? {
        switch self {
        case .keineDeutscheStimme:
            return "Deutsche Stimme nicht verfügbar — bitte in den iOS-Einstellungen laden."
        }
    }
}

/// Sprachausgabe mit `AVSpeechSynthesizer` und de-DE-Stimme, vollständig offline.
///
/// Zweck: reiht je Satz genau eine Äußerung ein; die Reihenfolge und das
/// Nacheinander führt die Warteschlange des Synthesizers (§6.3 Punkt 6).
/// Grenze: baut keine `AVAudioSession` auf und kennt keinen Zustandsautomaten —
/// beides gehört dem Koordinator (§8, AD-V4). Kein Netzwerk, keine Secrets.
@MainActor
final class SpeechSynthesizerService: NSObject, SpeechSynthesizing {

    /// Einstellwerte der Sprachausgabe (spec-voice §9).
    ///
    /// Injiziert statt als Zahlen im Code; die Vorgaben sind die der Spec.
    struct Configuration {
        /// Sprechgeschwindigkeit.
        var speechRate: Float = AVSpeechUtteranceDefaultSpeechRate
        /// Tonhöhe.
        var pitchMultiplier: Float = 1.0
        /// Lautstärke.
        var volume: Float = 1.0
    }

    /// Wird gerufen, wenn die Warteschlange leer ist (T5: `didFinish`).
    ///
    /// Ergänzung zum Protokoll aus §11: der Übergang `.sprechend → .stumm`
    /// braucht ein Ende-Signal, das nur der Delegate liefert.
    var onIdle: (() -> Void)?

    private let synthesizer = AVSpeechSynthesizer()
    private let configuration: Configuration

    init(configuration: Configuration = Configuration()) {
        self.configuration = configuration
        super.init()
        synthesizer.delegate = self
    }

    var isSpeaking: Bool {
        synthesizer.isSpeaking
    }

    /// Reiht genau eine Äußerung ein (spec-voice §11).
    ///
    /// Markdown wird vorher entfernt; bleibt danach kein Text übrig, ist das
    /// **kein** Fehler, sondern die Äußerung entfällt (§11).
    /// Wirft nur, wenn keine deutsche Stimme vorhanden ist.
    func speak(_ text: String) throws {
        let sentence = VoiceTextNormalizer.normalize(text)
        guard !sentence.isEmpty else { return }
        guard let voice = Self.germanVoice() else {
            throw SpeechSynthesisError.keineDeutscheStimme
        }

        let utterance = AVSpeechUtterance(string: sentence)
        utterance.voice = voice
        utterance.rate = configuration.speechRate
        utterance.pitchMultiplier = configuration.pitchMultiplier
        utterance.volume = configuration.volume
        synthesizer.speak(utterance)
    }

    /// Bricht die Ausgabe sofort ab; mehrfach aufrufbar (§11).
    func stop() {
        synthesizer.stopSpeaking(at: .immediate)
    }

    // MARK: Stimmenwahl

    /// Die verfügbare deutsche Stimme mit der höchsten Qualität, sonst die
    /// Standardstimme für `de-DE` (R-V7, offene Frage F-V-Stimme).
    ///
    /// Bei gleicher Qualität gewinnt die erste Stimme der Systemliste — die
    /// Wahl bleibt damit auch ohne Sortierung stabil.
    static func germanVoice() -> AVSpeechSynthesisVoice? {
        let german = AVSpeechSynthesisVoice.speechVoices().filter {
            $0.language.hasPrefix("de")
        }
        var best: AVSpeechSynthesisVoice?
        for voice in german {
            if let current = best, qualityRank(current.quality) >= qualityRank(voice.quality) {
                continue
            }
            best = voice
        }
        return best ?? AVSpeechSynthesisVoice(language: "de-DE")
    }

    private static func qualityRank(_ quality: AVSpeechSynthesisVoiceQuality) -> Int {
        switch quality {
        case .premium:
            return 2
        case .enhanced:
            return 1
        default:
            return 0
        }
    }
}

// MARK: - Ende der Äußerung

extension SpeechSynthesizerService: AVSpeechSynthesizerDelegate {

    nonisolated func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer,
        didFinish utterance: AVSpeechUtterance
    ) {
        Task { @MainActor [weak self] in
            self?.notifyIfIdle()
        }
    }

    /// Meldet erst, wenn wirklich keine Äußerung mehr läuft.
    private func notifyIfIdle() {
        guard !synthesizer.isSpeaking else { return }
        onIdle?()
    }
}
