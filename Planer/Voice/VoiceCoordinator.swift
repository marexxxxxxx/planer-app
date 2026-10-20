//
//  VoiceCoordinator.swift
//  Planer
//
//  Zustandsautomat, Audio-Session und Nahtstellen der Sprachschicht
//  (spec-voice Rev 2 §6, §8, §11).
//

import AVFoundation
import SwiftUI

/// Der Vertrag, den der Chat für die Sprachschicht braucht (spec-voice §11).
///
/// Zweck: `ChatViewModel` kennt nur diese drei Elemente; der Zustandsautomat
/// und die Dienste bleiben hinter dem Koordinator.
/// Grenze: kein Zugriff auf Zustand oder Oberfläche — die View liest den
/// Koordinator direkt.
@MainActor
protocol VoiceAssistant: AnyObject {
    /// Füttert den Satzpuffer mit einem Text-Delta der Antwort (N2).
    func ingestAssistantDelta(_ delta: String)
    /// Gibt den Restpuffer als letzte Äußerung aus (N3).
    func finishAssistantStream()
    /// Bricht das Vorlesen sofort ab (N4/N5).
    func stopSpeaking()
}

/// Wie ein Diktat ausgelöst wird (spec-voice §8.3, §9).
enum VoiceTriggerMode: String, CaseIterable, Identifiable, Sendable {
    /// Taste drücken und halten bzw. erneut drücken zum Beenden (Default).
    case pushToTalk
    /// Zuhören ohne Taste — nur solange die App im Vordergrund ist (§8.3).
    case handsFree
    /// Nur Vorlesen, kein Mikrofon.
    case readAloudOnly

    var id: String { rawValue }

    var title: String {
        switch self {
        case .pushToTalk:
            return "Push-to-Talk"
        case .handsFree:
            return "Freihändig (nur im Vordergrund)"
        case .readAloudOnly:
            return "Nur vorlesen"
        }
    }
}

/// Einstellwerte der Sprachschicht (spec-voice §9).
///
/// Zweck: keine Zahlen im Ablauf; die Vorgaben sind die der Spec.
/// Grenze: reine Werte — die Persistenz der Nutzerwahl liegt im Koordinator.
struct VoiceConfiguration: Sendable {
    /// Obergrenze einer Äußerung im Satzpuffer (§6.3).
    var maxSentenceCharacters = 240
    /// Harter Stopp eines Diktats (T3).
    var maxDictationSeconds: TimeInterval = 60
    /// Obergrenze diktierten Textes (= `ChatViewModel`-Grenze, §9).
    var maxTranscriptCharacters = 4_000
    /// Laufzeit einer freihändigen Erkennung bis zum Neustart (§8.3).
    var handsFreeSessionSeconds: TimeInterval = 60
    /// Obergrenze einer freihändigen Sitzung (Akku/Thermik, §8.3).
    var handsFreeMaxMinutes: TimeInterval = 30
}

/// Führt die Sprachschicht: Zustandsautomat, Audio-Session, Diktat und
/// Vorlesen (spec-voice §8).
///
/// Zweck: **jeder** Zustandswechsel läuft über `transition(to:)`; die
/// Absichten `startListening()`, `speak(_:)`, `stopListening()`,
/// `stopSpeaking()` und `reset()` prüfen ihre Vorbedingungen und verwerfen
/// einen unerlaubten Übergang, statt ihn trotzdem auszuführen (§8.1).
/// Grenze: kein Netzwerk und keine Secrets (§13). Der Koordinator liest
/// `scenePhase` **nicht** selbst — `PlanerApp` reicht sie über
/// `handleScenePhase(_:)` herein (§8.3). Mikrofon und Ausgabe sind nie
/// gleichzeitig aktiv (Invariante I-V1).
@MainActor
final class VoiceCoordinator: ObservableObject, VoiceAssistant {

    // MARK: Veröffentlichter Zustand

    /// Der aktuelle Zustand; geschrieben nur in `transition(to:)`.
    @Published private(set) var state: VoiceState = .stumm
    /// Live-Teiltext während `.hoerend` (nicht der Entwurf, §6).
    @Published private(set) var liveTranscript = ""
    /// Einmaliger Hinweis (Zeitlimit, Kürzung, „Nichts verstanden“).
    @Published private(set) var notice: String?

    /// Vorlesen von Agent-Antworten und To-Dos (persistiert).
    @Published var readAloudEnabled: Bool {
        didSet {
            defaults.set(readAloudEnabled, forKey: DefaultsKey.readAloud)
            if !readAloudEnabled {
                stopSpeaking()
            }
        }
    }

    /// Diktat erlauben — zusätzlich zur Systemfreigabe (persistiert).
    @Published var dictationEnabled: Bool {
        didSet {
            defaults.set(dictationEnabled, forKey: DefaultsKey.dictation)
            if !dictationEnabled {
                stopListening()
            }
        }
    }

    /// Auslöse-Modus (persistiert, §8.3).
    @Published var triggerMode: VoiceTriggerMode {
        didSet {
            defaults.set(triggerMode.rawValue, forKey: DefaultsKey.triggerMode)
            if triggerMode != .handsFree, handsFreeActive {
                stopHandsFree()
            }
        }
    }

    /// Ziel für das Endergebnis eines Diktats; `ChatView` setzt hier
    /// `viewModel.appendDictation(_:)` ein (§6). Der Aufruf passiert auf dem
    /// Main-Actor, deshalb ist der Typ entsprechend markiert.
    var onTranscript: (@MainActor (String) -> Void)?

    // MARK: Abhängigkeiten

    /// Schlüssel der Nutzerwahl in `UserDefaults` (spec-voice §9).
    private enum DefaultsKey {
        static let readAloud = "voiceReadAloudEnabled"
        static let dictation = "voiceDictationEnabled"
        static let triggerMode = "voiceTriggerMode"
    }

    /// Grund, warum ein laufendes Diktat endet — entscheidet, ob freihändig
    /// neu gestartet wird (§8.3).
    private enum DictationEnd: Equatable {
        /// Die Erkennung hat selbst ein Endergebnis geliefert.
        case natural
        /// Zeitlimit der Sitzung erreicht; freihändig startet neu.
        case deadline
        /// Der Nutzer hat beendet; es wird nicht neu gestartet.
        case explicit
    }

    private let synthesizer: SpeechSynthesizerService
    private let dictating: SpeechRecognizerService
    private let configuration: VoiceConfiguration
    private let defaults: UserDefaults

    private var sentenceBuffer: SentenceBuffer
    private var startTask: Task<Void, Never>?
    private var dictationTimer: Task<Void, Never>?
    private var handsFreeDeadline: Task<Void, Never>?
    private var pendingEnd = DictationEnd.natural
    private var handsFreeActive = false
    private var isForeground = true

    /// Dienste sind injizierbar; die Vorgaben sind die echten Dienste aus
    /// V1 und V2. Beide werden direkt angesprochen, weil nur sie die
    /// Ergänzungssignale `onIdle` (V1) und `onFailure` (V2) anbieten.
    init(
        synthesizer: SpeechSynthesizerService = SpeechSynthesizerService(),
        dictating: SpeechRecognizerService = SpeechRecognizerService(),
        configuration: VoiceConfiguration = VoiceConfiguration(),
        defaults: UserDefaults = .standard
    ) {
        self.synthesizer = synthesizer
        self.dictating = dictating
        self.configuration = configuration
        self.defaults = defaults
        self.sentenceBuffer = SentenceBuffer(maxSentenceCharacters: configuration.maxSentenceCharacters)
        self.readAloudEnabled = defaults.object(forKey: DefaultsKey.readAloud) as? Bool ?? true
        self.dictationEnabled = defaults.object(forKey: DefaultsKey.dictation) as? Bool ?? true
        self.triggerMode = VoiceTriggerMode(
            rawValue: defaults.string(forKey: DefaultsKey.triggerMode) ?? ""
        ) ?? .pushToTalk

        // V1 und V2 melden ihre Ergänzungssignale ohne Actor-Angabe im Typ;
        // beide rufen auf dem Main-Actor, deshalb die ausdrückliche Zusicherung.
        synthesizer.onIdle = { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.handleSynthesizerIdle()
            }
        }
        dictating.onFailure = { [weak self] error in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.handleDictationFailure(error)
            }
        }
    }

    // MARK: Abgeleiteter Zustand für die Oberfläche

    /// Ob der Mikrofon-Knopf überhaupt etwas bewirken kann.
    var canListen: Bool {
        dictationEnabled && triggerMode != .readAloudOnly
    }

    /// Ob gerade freihändig zugehört wird (§8.3).
    var isHandsFreeActive: Bool {
        handsFreeActive
    }

    /// Statuszeile der Sprachleiste.
    var statusText: String {
        switch state {
        case .stumm:
            return "Sprache: stumm"
        case .hoerend:
            return handsFreeActive
                ? "Höre freihändig zu — nur im Vordergrund"
                : "Höre zu …"
        case .sprechend:
            return "Spricht …"
        case let .fehler(failure):
            return failure.errorDescription ?? "Sprachfehler."
        }
    }

    // MARK: Zustandsautomat (§8.1)

    /// Der **einzige** Schreibpfad auf `state` (spec-voice §8).
    ///
    /// Erlaubt sind genau die Übergänge T1–T9 aus §8.1. Ein nicht erlaubter
    /// oder ein identischer Übergang wird verworfen — kein Absturz, keine
    /// stille Ausführung. Beim Verlassen von `.hoerend` endet die Aufnahme,
    /// beim Verlassen von `.sprechend` die Ausgabe; damit gilt die Invariante
    /// I-V1 auch bei einem Fehler.
    func transition(to: VoiceState) {
        let newState = to
        guard newState != state else { return }
        guard Self.isAllowed(from: state, to: newState) else { return }

        let previous = state
        state = newState

        switch previous {
        case .hoerend:
            dictationTimer?.cancel()
            dictationTimer = nil
            dictating.stop()
            liveTranscript = ""
        case .sprechend:
            synthesizer.stop()
            sentenceBuffer.reset()
        case .stumm, .fehler:
            break
        }

        if newState == .stumm {
            deactivateSession()
            liveTranscript = ""
        }
    }

    /// Die Übergangstabelle aus §8.1.
    ///
    /// `.stumm → .fehler` ergänzt die Tabelle um den Fall, dass schon der
    /// Start scheitert (Freigabe fehlt, §11.1); §8.1 verlangt für einen
    /// gescheiterten Guard ausdrücklich den Weg in `.fehler`.
    private static func isAllowed(from: VoiceState, to: VoiceState) -> Bool {
        switch (from, to) {
        case (.stumm, .hoerend), (.stumm, .sprechend), (.stumm, .fehler):
            return true
        case (.hoerend, .stumm), (.hoerend, .fehler):
            return true
        case (.sprechend, .stumm), (.sprechend, .hoerend), (.sprechend, .fehler):
            return true
        case (.fehler, .stumm), (.fehler, .hoerend):
            return true
        default:
            return false
        }
    }

    // MARK: Diktat (§8.1, §8.3)

    /// Startet das Diktat (T1). Aus `.sprechend` heraus wird zuerst die
    /// Ausgabe beendet (T6, Barging-in).
    func startListening() {
        guard canListen else { return }
        guard state != .hoerend else { return }
        // §8.3: freihändig — und damit jedes Zuhören — nur im Vordergrund.
        guard isForeground else { return }

        notice = nil
        if state == .sprechend {
            stopSpeaking()
        }
        beginListeningSoon()
    }

    /// Beendet das Diktat (T3) und übernimmt das letzte Ergebnis.
    func stopListening() {
        handsFreeActive = false
        handsFreeDeadline?.cancel()
        handsFreeDeadline = nil
        endDictation(reason: .explicit)
    }

    /// Der Mikrofon-Knopf: je nach Modus Push-to-Talk oder freihändig
    /// (spec-voice §8.3).
    func toggleListening() {
        switch triggerMode {
        case .pushToTalk:
            if state == .hoerend {
                stopListening()
            } else {
                startListening()
            }
        case .handsFree:
            if handsFreeActive {
                stopHandsFree()
            } else {
                startHandsFree()
            }
        case .readAloudOnly:
            return
        }
    }

    /// Startet freihändiges Zuhören — nur im Vordergrund (§8.3).
    func startHandsFree() {
        guard triggerMode == .handsFree, canListen, isForeground else { return }
        guard !handsFreeActive else { return }
        handsFreeActive = true
        scheduleHandsFreeDeadline()
        startListening()
    }

    /// Beendet freihändiges Zuhören (Nutzeraktion).
    func stopHandsFree() {
        handsFreeActive = false
        handsFreeDeadline?.cancel()
        handsFreeDeadline = nil
        endDictation(reason: .explicit)
    }

    private func beginListening() async {
        guard isForeground, state != .hoerend else { return }

        guard await VoicePermissions.requestMicrophone() == .erlaubt else {
            transition(to: .fehler(.mikrofonVerweigert))
            return
        }
        guard !Task.isCancelled else { return }
        guard await VoicePermissions.requestSpeechRecognition() == .erlaubt else {
            transition(to: .fehler(.erkennungVerweigert))
            return
        }
        guard !Task.isCancelled else { return }
        // §4: ohne deutsches On-Device-Diktat startet die Erkennung nicht —
        // es gibt keinen Netzrückfall.
        guard dictating.supportsGermanOnDevice else {
            transition(to: .fehler(.erkennungNichtMoeglich))
            return
        }
        // §8.3: kein Zuhören, wenn die App inzwischen im Hintergrund ist.
        guard isForeground else { return }

        do {
            try activateSession(forRecording: true)
            // Die Dienste melden auf dem Main-Actor; `assumeIsolated` hält die
            // Reihenfolge von Teil- und Endergebnis synchron zum Aufruf.
            try dictating.start(
                onPartial: { [weak self] text in
                    MainActor.assumeIsolated {
                        guard let self else { return }
                        self.handlePartial(text)
                    }
                },
                onFinal: { [weak self] text in
                    MainActor.assumeIsolated {
                        guard let self else { return }
                        self.handleFinal(text)
                    }
                }
            )
        } catch {
            transition(to: .fehler(failure(for: error)))
            return
        }

        liveTranscript = ""
        transition(to: .hoerend)
        scheduleDictationTimer()
    }

    /// Startet das Diktat in einer Aufgabe; ein noch laufender Start wird
    /// verworfen, damit nicht zwei Sitzungen gleichzeitig entstehen.
    private func beginListeningSoon() {
        startTask?.cancel()
        startTask = Task { [weak self] in
            await self?.beginListening()
        }
    }

    private func endDictation(reason: DictationEnd) {
        guard state == .hoerend else { return }
        pendingEnd = reason
        // Liefert ein Ergebnis, ruft der Dienst `handleFinal` noch in diesem
        // Aufruf; danach ist der Zustand bereits `.stumm`.
        dictating.stop()
        if state == .hoerend {
            finishSession(reason: reason, transcript: nil)
        }
        pendingEnd = .natural
    }

    private func handlePartial(_ text: String) {
        guard state == .hoerend else { return }
        liveTranscript = String(text.prefix(configuration.maxTranscriptCharacters))
    }

    private func handleFinal(_ text: String) {
        guard state == .hoerend else { return }
        finishSession(reason: pendingEnd, transcript: text)
    }

    private func finishSession(reason: DictationEnd, transcript: String?) {
        dictationTimer?.cancel()
        dictationTimer = nil
        transition(to: .stumm)
        if let transcript {
            deliver(transcript)
        }
        // §8.3: freihändig läuft nach jedem Ergebnis weiter — aber nur, wenn
        // die App im Vordergrund ist, der Modus noch freihändig ist und der
        // Nutzer nicht selbst beendet hat.
        guard handsFreeActive, isForeground, triggerMode == .handsFree, reason != .explicit else {
            return
        }
        beginListeningSoon()
    }

    /// Übergibt das Diktat an den Entwurf — ohne automatisches Senden (§6).
    private func deliver(_ transcript: String) {
        let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            notice = "Nichts verstanden."
            return
        }
        guard let onTranscript else { return }

        if trimmed.count > configuration.maxTranscriptCharacters {
            notice = "Diktat auf \(configuration.maxTranscriptCharacters) Zeichen gekürzt."
            onTranscript(String(trimmed.prefix(configuration.maxTranscriptCharacters)))
        } else {
            onTranscript(trimmed)
        }
    }

    private func handleDictationFailure(_ error: DictationError) {
        guard state == .hoerend else { return }
        handsFreeActive = false
        transition(to: .fehler(failure(for: error)))
    }

    private func scheduleDictationTimer() {
        dictationTimer?.cancel()
        let seconds = handsFreeActive
            ? configuration.handsFreeSessionSeconds
            : configuration.maxDictationSeconds
        dictationTimer = Task { [weak self] in
            guard (try? await Task.sleep(for: .seconds(seconds))) != nil else { return }
            self?.dictationTimeLimitReached()
        }
    }

    private func dictationTimeLimitReached() {
        guard state == .hoerend else { return }
        if !handsFreeActive {
            notice = "Zeitlimit erreicht — Diktat beendet."
        }
        endDictation(reason: .deadline)
    }

    /// Gesamtgrenze einer freihändigen Sitzung (Akku/Thermik, §8.3).
    private func scheduleHandsFreeDeadline() {
        handsFreeDeadline?.cancel()
        let seconds = configuration.handsFreeMaxMinutes * 60
        handsFreeDeadline = Task { [weak self] in
            guard (try? await Task.sleep(for: .seconds(seconds))) != nil else { return }
            self?.handsFreeLimitReached()
        }
    }

    private func handsFreeLimitReached() {
        guard handsFreeActive else { return }
        let minutes = Int(configuration.handsFreeMaxMinutes)
        handsFreeActive = false
        handsFreeDeadline = nil
        notice = "Freihändig beendet nach \(minutes) Minuten — das kostet Akku."
        endDictation(reason: .explicit)
    }

    // MARK: Vorlesen (§6.3, §8.1)

    /// Vorlesen eines sichtbaren Textes, etwa der To-Dos-Liste (§6).
    func speak(_ text: String) {
        guard readAloudEnabled else { return }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        enqueue(sentences(of: trimmed))
    }

    /// Satzpuffer aus dem Antwortstrom füllen (N2).
    func ingestAssistantDelta(_ delta: String) {
        guard readAloudEnabled else { return }
        enqueue(sentenceBuffer.append(delta))
    }

    /// Restpuffer nach der Runde ausgeben (N3).
    func finishAssistantStream() {
        guard readAloudEnabled else { return }
        enqueue(sentenceBuffer.flush())
    }

    /// Bricht das Vorlesen sofort ab (T5, N4/N5); mehrfach aufrufbar.
    func stopSpeaking() {
        synthesizer.stop()
        sentenceBuffer.reset()
        if state == .sprechend {
            transition(to: .stumm)
        }
    }

    /// Quittiert einen Fehler (T8) und räumt den Hinweis ab.
    func reset() {
        transition(to: .stumm)
        notice = nil
        synthesizer.stop()
        sentenceBuffer.reset()
    }

    private func enqueue(_ sentences: [String]) {
        guard !sentences.isEmpty else { return }
        // Invariante I-V1: nie Mikrofon und Ausgabe gleichzeitig. Aus
        // `.hoerend` heraus wird deshalb nicht gesprochen (§8.1, verboten).
        guard state != .hoerend else { return }
        if case .fehler = state {
            // Vorlesen bleibt nach einem Diktat-Fehler möglich (§11.1); der
            // Weg führt über `.stumm` (T8), damit die Tabelle aus §8.1 gilt.
            transition(to: .stumm)
        }

        let wasSpeaking = state == .sprechend
        if !wasSpeaking {
            do {
                try activateSession(forRecording: false)
            } catch {
                transition(to: .fehler(failure(for: error)))
                return
            }
            transition(to: .sprechend)
        }

        do {
            for sentence in sentences {
                try synthesizer.speak(sentence)
            }
        } catch {
            transition(to: .fehler(failure(for: error)))
            return
        }
        // Nur der Beginn einer Ausgabe wird geprüft: bleibt nach dem Entfernen
        // von Markdown nichts Sprechbares übrig, endet der Zustand sofort
        // wieder. Beim Nachreichen weiterer Sätze läuft die Ausgabe bereits.
        guard !wasSpeaking else { return }
        guard synthesizer.isSpeaking else {
            transition(to: .stumm)
            return
        }
    }

    private func handleSynthesizerIdle() {
        guard state == .sprechend, !synthesizer.isSpeaking else { return }
        transition(to: .stumm)
    }

    private func sentences(of text: String) -> [String] {
        var buffer = SentenceBuffer(maxSentenceCharacters: configuration.maxSentenceCharacters)
        return buffer.append(text) + buffer.flush()
    }

    // MARK: Vordergrund (§8.3)

    /// `PlanerApp` reicht den Lebenszyklus herein; der Koordinator liest
    /// `scenePhase` nicht selbst.
    ///
    /// Hintergrund oder inaktiv beendet Aufnahme **und** Ausgabe; `.active`
    /// startet **nichts** von selbst. Ein Hintergrund-Weckwort gibt es auf
    /// iOS für Dritt-Apps nicht (§8.3).
    func handleScenePhase(_ phase: ScenePhase) {
        guard phase == .active else {
            isForeground = false
            handsFreeActive = false
            handsFreeDeadline?.cancel()
            handsFreeDeadline = nil
            endDictation(reason: .explicit)
            stopSpeaking()
            return
        }
        // `.active` startet nichts von selbst (§8.3).
        isForeground = true
    }

    // MARK: Audio-Session (§8.1)

    /// Setzt die Kategorie und aktiviert die Session.
    ///
    /// Wirft den AVFoundation-Fehler weiter; der Aufrufer macht daraus
    /// `.fehler(.audio(…))` (§11.1).
    private func activateSession(forRecording: Bool) throws {
        let session = AVAudioSession.sharedInstance()
        if forRecording {
            try session.setCategory(.record, mode: .measurement, options: [.duckOthers])
        } else {
            try session.setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
        }
        try session.setActive(true)
    }

    /// Gibt die Session frei. Ein Fehler dabei ist folgenlos für den
    /// App-Zustand (eine andere App kann sie übernommen haben) und wird
    /// deshalb bewusst nicht als Fehler gemeldet.
    private func deactivateSession() {
        do {
            try AVAudioSession.sharedInstance()
                .setActive(false, options: .notifyOthersOnDeactivation)
        } catch {
            return
        }
    }

    // MARK: Fehlerabbildung

    private func failure(for error: Error) -> VoiceFailure {
        guard let dictationError = error as? DictationError else {
            if error is SpeechSynthesisError {
                return .keineDeutscheStimme
            }
            return .audio(error.localizedDescription)
        }
        switch dictationError {
        case .mikrofonVerweigert:
            return .mikrofonVerweigert
        case .erkennungVerweigert:
            return .erkennungVerweigert
        case .erkennungNichtMoeglich:
            return .erkennungNichtMoeglich
        case let .audio(reason):
            return .audio(reason)
        }
    }
}
