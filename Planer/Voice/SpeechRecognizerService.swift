//
//  SpeechRecognizerService.swift
//  Planer
//
//  Deutsches Diktat auf dem Gerät (spec-voice §2/V2, §3, §4, §11).
//

import AVFoundation
import Foundation
import Speech

/// Der Vertrag des Diktats (spec-voice §11).
///
/// Zweck: der Koordinator kennt nur diese drei Elemente; die Speech- und
/// AVFoundation-Typen bleiben hinter dieser Datei.
/// Grenze: kein Zustandsautomat und keine Audio-Session — beides gehört dem
/// Koordinator (§8, AD-V4, R-V3).
@MainActor
protocol Dictating: AnyObject {
    /// Laufzeitprüfung der deutschen On-Device-Erkennung, pro Sitzung neu (§4).
    var supportsGermanOnDevice: Bool { get }
    func start(onPartial: @escaping (String) -> Void,
               onFinal: @escaping (String) -> Void) throws
    func stop()
}

/// Ergebnis der Fähigkeitsprüfung aus §4 Punkt 1 — der Fallback ist ein
/// eigener Zustand, kein stiller Sonderfall im Startpfad.
enum DictationAvailability: Equatable {
    /// Deutsche Erkennung ohne Netz ist auf diesem Gerät möglich (§4).
    case bereit
    /// Kein deutsches On-Device-Diktat; das Diktat startet nicht (§4 Punkt 2–4).
    case nichtMoeglich(hinweis: String)

    /// Ob diktiert werden darf.
    var istMoeglich: Bool {
        self == .bereit
    }

    /// Der dauerhafte Hinweis für die Oberfläche und das Barrierefreiheits-Label
    /// (§4 Punkt 2 und 3); `nil`, solange das Diktat möglich ist.
    var hinweis: String? {
        if case let .nichtMoeglich(hinweis) = self {
            return hinweis
        }
        return nil
    }
}

/// Fehler des Diktats (spec-voice §11, §11.1); die Werte entsprechen den
/// `VoiceFailure`-Fällen aus §8.
enum DictationError: Error, Equatable, LocalizedError {
    /// Mikrofon-Freigabe fehlt oder wurde entzogen (§11.1).
    case mikrofonVerweigert
    /// Freigabe der Spracherkennung fehlt oder wurde entzogen (§11.1).
    case erkennungVerweigert
    /// Kein deutsches On-Device-Diktat — es gibt keinen Netzpfad (§4).
    case erkennungNichtMoeglich
    /// Audio-Session, Engine oder Erkennung sind gescheitert (§11.1).
    case audio(String)

    var errorDescription: String? {
        switch self {
        case .mikrofonVerweigert:
            return "Mikrofon nicht freigegeben — in den Einstellungen erlauben."
        case .erkennungVerweigert:
            return "Spracherkennung nicht freigegeben — in den Einstellungen erlauben."
        case .erkennungNichtMoeglich:
            return VoicePrivacyTexts.diktatNichtMoeglich
        case let .audio(grund):
            return grund
        }
    }
}

/// Diktat mit `SFSpeechRecognizer` und `AVAudioEngine`-Tap, ausschließlich
/// on-device (spec-voice §2/V2, §4).
///
/// Zweck: nimmt Mikrofon-Puffer auf, setzt `requiresOnDeviceRecognition`
/// **immer** und liefert Teil- und Endergebnis. Ist die deutsche Erkennung
/// ohne Netz nicht verfügbar, startet die Erkennung gar nicht (§4 Punkt 2);
/// ein Netzpfad existiert in dieser Datei nicht (§4, §13).
/// Grenze: setzt keine `AVAudioSession`-Kategorie — die aktiviert der
/// Koordinator vor dem Start (T1, R-V3). Kein Netzwerk, keine Secrets.
@MainActor
final class SpeechRecognizerService: Dictating {

    /// Einstellwerte des Diktats (spec-voice §9).
    ///
    /// Injiziert statt als Zeichenkette im Code; die Vorgabe ist die der Spec.
    struct Configuration {
        /// Locale der Erkennung (App ist deutsch).
        var localeIdentifier: String = "de-DE"
    }

    /// Wird gerufen, wenn die Erkennung **nach** dem Start scheitert (T4).
    ///
    /// Ergänzung zum Protokoll aus §11: `start(onPartial:onFinal:)` hat keinen
    /// Fehlerkanal für Ereignisse während des Diktats; ohne dieses Signal
    /// bliebe ein Erkennungsfehler unbemerkt (§11.1).
    var onFailure: ((DictationError) -> Void)?

    private let configuration: Configuration
    private let engine = AVAudioEngine()

    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var tapInstalled = false
    private var isRunning = false
    private var lastTranscript = ""
    private var onPartial: ((String) -> Void)?
    private var onFinal: ((String) -> Void)?

    init(configuration: Configuration = Configuration()) {
        self.configuration = configuration
    }

    private var locale: Locale {
        Locale(identifier: configuration.localeIdentifier)
    }

    // MARK: Fähigkeit (§4)

    /// Prüft **vor jedem Diktat** neu, ob dieses Gerät `de-DE` ohne Netz
    /// erkennen kann (§4 Punkt 1).
    var availability: DictationAvailability {
        guard SFSpeechRecognizer.supportedLocales().contains(locale),
              let recognizer = SFSpeechRecognizer(locale: locale),
              recognizer.supportsOnDeviceRecognition
        else {
            return .nichtMoeglich(hinweis: VoicePrivacyTexts.diktatNichtMoeglich)
        }
        return .bereit
    }

    var supportsGermanOnDevice: Bool {
        availability.istMoeglich
    }

    // MARK: Diktat

    /// Startet Aufnahme und Erkennung (spec-voice §11).
    ///
    /// Wirft bei fehlender Freigabe (`mikrofonVerweigert`,
    /// `erkennungVerweigert`) oder fehlender On-Device-Fähigkeit
    /// (`erkennungNichtMoeglich`) — nie in einen Netzpfad (§11).
    func start(onPartial: @escaping (String) -> Void,
               onFinal: @escaping (String) -> Void) throws {
        teardown()

        guard VoicePermissions.microphoneStatus == .erlaubt else {
            throw DictationError.mikrofonVerweigert
        }
        guard SFSpeechRecognizer.authorizationStatus() == .authorized else {
            throw DictationError.erkennungVerweigert
        }
        if case .nichtMoeglich = availability {
            throw DictationError.erkennungNichtMoeglich
        }
        guard let recognizer = SFSpeechRecognizer(locale: locale) else {
            throw DictationError.erkennungNichtMoeglich
        }

        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0 else {
            throw DictationError.audio("Kein Mikrofon-Eingang verfügbar.")
        }

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = true

        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak request] buffer, _ in
            request?.append(buffer)
        }
        tapInstalled = true

        self.request = request
        self.onPartial = onPartial
        self.onFinal = onFinal
        lastTranscript = ""
        isRunning = true

        engine.prepare()
        do {
            try engine.start()
        } catch {
            teardown()
            throw DictationError.audio(error.localizedDescription)
        }

        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            Task { @MainActor in
                self?.receive(result: result, error: error)
            }
        }
    }

    /// Beendet das Diktat und übernimmt das letzte Teilverständnis als
    /// Endergebnis (T3); mehrfach aufrufbar (§11).
    func stop() {
        guard isRunning else { return }
        finish()
    }

    // MARK: Erkennungsergebnisse

    private func receive(result: SFSpeechRecognitionResult?, error: Error?) {
        guard isRunning else { return }

        if let result {
            lastTranscript = result.bestTranscription.formattedString
            if result.isFinal {
                finish()
                return
            }
            onPartial?(lastTranscript)
        }

        guard let error else { return }

        // Stille liefert kein Ergebnis: kein leerer Eintrag im Entwurf (§11.1).
        if lastTranscript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let failure = DictationError.audio(error.localizedDescription)
            teardown()
            onFailure?(failure)
        } else {
            finish()
        }
    }

    /// Übergibt das gesammelte Verständnis genau einmal als Endergebnis.
    private func finish() {
        let transcript = lastTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
        let deliver = onFinal
        teardown()
        guard !transcript.isEmpty else { return }
        deliver?(transcript)
    }

    /// Räumt die Sitzung ab (T3): `endAudio`, Tap entfernen, Engine stoppen.
    private func teardown() {
        isRunning = false
        request?.endAudio()
        if tapInstalled {
            engine.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }
        engine.stop()
        task?.cancel()
        request = nil
        task = nil
        onPartial = nil
        onFinal = nil
        lastTranscript = ""
    }
}
