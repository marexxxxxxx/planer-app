//
//  VoiceState.swift
//  Planer
//
//  Der explizite Zustand der Sprachschicht (spec-voice Rev 2 §8).
//

import Foundation

/// Warum die Sprachschicht im Zustand `.fehler` steht (spec-voice §8).
///
/// Zweck: jeder Fehler hat genau einen Wert, den die Oberfläche als Satz
/// anzeigen und der Nutzer durch `reset()` quittieren kann.
/// Grenze: kein Rohtext aus AVFoundation außer im Fall `.audio`; dort steht
/// die technische Ursache, weil sie sonst nirgends sichtbar wäre.
enum VoiceFailure: Equatable, LocalizedError {
    /// Mikrofon-Freigabe fehlt oder wurde entzogen (§11.1).
    case mikrofonVerweigert
    /// Freigabe der Spracherkennung fehlt oder wurde entzogen (§11.1).
    case erkennungVerweigert
    /// Kein deutsches On-Device-Diktat auf diesem Gerät (§4).
    case erkennungNichtMoeglich
    /// Keine deutsche Stimme installiert (§11.1).
    case keineDeutscheStimme
    /// Audio-Session, Engine oder Synthese sind gescheitert (§11.1).
    case audio(String)

    var errorDescription: String? {
        switch self {
        case .mikrofonVerweigert:
            return "Mikrofon nicht freigegeben — in den Einstellungen erlauben."
        case .erkennungVerweigert:
            return "Spracherkennung nicht freigegeben — in den Einstellungen erlauben."
        case .erkennungNichtMoeglich:
            return VoicePrivacyTexts.diktatNichtMoeglich
        case .keineDeutscheStimme:
            return "Keine deutsche Stimme installiert — bitte in den iOS-Einstellungen laden."
        case let .audio(grund):
            return "Audio nicht verfügbar: \(grund)"
        }
    }
}

/// Die vier Zustände der Sprachschicht (spec-voice §8).
///
/// Zweck: der Zustand ist explizit und wird ausschließlich vom
/// `VoiceCoordinator` über `transition(to:)` gesetzt — nie implizit aus einer
/// View abgeleitet.
/// Grenze: kennt weder Dienste noch Audio-Session; er beschreibt nur, was
/// gerade gilt.
enum VoiceState: Equatable {
    /// Ruhezustand: kein Mikrofon, keine Ausgabe.
    case stumm
    /// Mikrofon aktiv, Erkennung läuft — auch freihändig, dann nur im
    /// Vordergrund (§8.3).
    case hoerend
    /// Sprachausgabe läuft.
    case sprechend
    /// Ein Fehler wartet auf `reset()` oder einen erneuten, erlaubten Start.
    case fehler(VoiceFailure)

    /// Ob das Mikrofon gerade aufnimmt.
    var isListening: Bool {
        self == .hoerend
    }

    /// Ob gerade Sprache ausgegeben wird.
    var isSpeaking: Bool {
        self == .sprechend
    }

    /// Der anzuzeigende Fehler, sonst `nil`.
    var failure: VoiceFailure? {
        if case let .fehler(failure) = self {
            return failure
        }
        return nil
    }
}
