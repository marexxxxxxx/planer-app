//
//  VoiceCoordinator.swift
//  Planer
//
//  Zustandsautomat, Audio-Session und Nahtstellen der Sprachschicht
//  (spec-voice Rev 2 §6, §8, §11).
//

import AVFoundation
import Speech
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

    /// Ob dieses Gerät deutsches Diktat ohne Netz kann — vor jedem Start neu
    /// geprüft und veröffentlicht, damit der Knopf nicht ins Leere läuft
    /// (spec-voice §4 Punkt 1–3).
    @Published private(set) var availability: DictationAvailability = .bereit

    /// Die beiden Freigaben, zuletzt gelesen beim Start oder Zurücksetzen
    /// (spec-voice §11.1).
    @Published private(set) var microphonePermission: VoicePermissionStatus = .nichtGefragt
    @Published private(set) var speechPermission: VoicePermissionStatus = .nichtGefragt

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

    /// Antwort-Deltas, die während des Zuhörens eintreffen (I-V1).
    ///
    /// Sprechen ist beim Zuhören verboten, Verwerfen aber auch: der Satzpuffer
    /// bleibt unberührt, die Deltas warten bis zum Ende des Diktats.
    private var deferredDelta = ""
    private var deferredStreamFinished = false

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

        // §4 Punkt 1: die Fähigkeit wird nicht zwischengespeichert, sondern
        // bei jedem Start und jedem Zurücksetzen neu gelesen.
        self.availability = dictating.availability
        self.microphonePermission = VoicePermissions.microphoneStatus
        self.speechPermission = VoiceCoordinator.speechPermissionStatus
    }

    // MARK: Abgeleiteter Zustand für die Oberfläche

    /// Ob der Mikrofon-Knopf überhaupt etwas bewirken kann (spec-voice §4
    /// Punkt 3, §11.1): Freigaben, Gerätefähigkeit und Einstellung zusammen.
    var canListen: Bool {
        listenBlockedHint == nil
    }

    /// Warum der Mikrofon-Knopf nichts bewirken kann; `nil` heißt bedienbar.
    ///
    /// Derselbe Text steht als Barrierefreiheits-Label am Knopf und als
    /// dauerhafter Hinweis in der Leiste (§4 Punkt 2 und 3).
    var listenBlockedHint: String? {
        if triggerMode == .readAloudOnly {
            return "Diktat ist ausgeschaltet — nur Vorlesen."
        }
        if !dictationEnabled {
            return "Diktat ist ausgeschaltet."
        }
        if let hinweis = availability.hinweis {
            return hinweis
        }
        if speechPermission == .verweigert {
            return VoiceFailure.erkennungVerweigert.errorDescription
        }
        if microphonePermission == .verweigert {
            return VoiceFailure.mikrofonVerweigert.errorDescription
        }
        return nil
    }

    /// Ob gerade freihändig zugehört wird (§8.3).
    var isHandsFreeActive: Bool {
        handsFreeActive
    }

    /// Liest die beiden Freigaben neu (§11.1).
    private func refreshPermissions() {
        microphonePermission = VoicePermissions.microphoneStatus
        speechPermission = Self.speechPermissionStatus
    }

    /// Prüft die Gerätefähigkeit neu — vor jedem Diktat (§4 Punkt 1).
    private func refreshAvailability() {
        availability = dictating.availability
    }

    /// Status der Spracherkennung ohne Systemdialog; das Diktat selbst bleibt
    /// hinter `Dictating`.
    private static var speechPermissionStatus: VoicePermissionStatus {
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized:
            return .erlaubt
        case .denied, .restricted:
            return .verweigert
        case .notDetermined:
            return .nichtGefragt
        @unknown default:
            return .verweigert
        }
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
            // §8.1/T4: ein Fehler beendet auch freihändig — Flag und
            // 30-Minuten-Deadline dürfen nicht weiterlaufen.
            if case .fehler = newState {
                teardownHandsFree()
            }
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
        teardownHandsFree()
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
            if handsFreeActive || state == .hoerend {
                stopHandsFree()
            } else {
                startHandsFree()
            }
        case .readAloudOnly:
            return
        }
    }

    /// Startet freihändiges Zuhören — nur im Vordergrund (§8.3).
    ///
    /// Das Flag gilt erst, wenn `beginListening` wirklich gestartet ist: sonst
    /// behauptet die Leiste „Freihändig hört zu“, während der Zustand
    /// `.fehler` ist, und die Deadline läuft ohne Aufnahme weiter.
    func startHandsFree() {
        guard triggerMode == .handsFree, canListen, isForeground else { return }
        guard !handsFreeActive else { return }
        notice = nil
        // Barging-in (T6): erst die Ausgabe beenden, dann aufnehmen.
        if state == .sprechend {
            stopSpeaking()
        }
        startTask?.cancel()
        startTask = Task { [weak self] in
            guard let self else { return }
            guard await self.beginListening() else { return }
            guard self.triggerMode == .handsFree,
                  self.isForeground,
                  self.state == .hoerend
            else {
                self.teardownHandsFree()
                self.endDictation(reason: .explicit)
                return
            }
            self.handsFreeActive = true
            self.scheduleHandsFreeDeadline()
            // Die Sitzungslänge hängt am Modus; nach dem Setzen neu planen.
            self.scheduleDictationTimer()
        }
    }

    /// Beendet freihändiges Zuhören (Nutzeraktion).
    func stopHandsFree() {
        teardownHandsFree()
        endDictation(reason: .explicit)
    }

    /// Räumt Flag **und** 30-Minuten-Deadline in einem Schritt ab (§8.3).
    private func teardownHandsFree() {
        handsFreeActive = false
        handsFreeDeadline?.cancel()
        handsFreeDeadline = nil
    }

    /// Ein Fehler beendet das Diktat samt freihändigem Zustand (T4, §8.3).
    private func fail(_ failure: VoiceFailure) {
        teardownHandsFree()
        transition(to: .fehler(failure))
    }

    @discardableResult
    private func beginListening() async -> Bool {
        guard isForeground, state != .hoerend else { return false }

        notice = nil
        refreshAvailability()
        refreshPermissions()

        // §4 Punkt 1 und 2: ohne deutsches On-Device-Diktat startet die
        // Erkennung nicht — und der Zustand bleibt `.stumm`. Ein `.fehler`
        // hier würde mit „Zurücksetzen“ wieder in den Start führen.
        guard availability.istMoeglich else {
            notice = availability.hinweis
            return false
        }

        guard await VoicePermissions.requestMicrophone() == .erlaubt else {
            refreshPermissions()
            fail(.mikrofonVerweigert)
            return false
        }
        guard !Task.isCancelled else { return false }
        guard await VoicePermissions.requestSpeechRecognition() == .erlaubt else {
            refreshPermissions()
            fail(.erkennungVerweigert)
            return false
        }
        guard !Task.isCancelled else { return false }
        // §8.3: kein Zuhören, wenn die App inzwischen im Hintergrund ist.
        guard isForeground else { return false }

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
            let mapped = failure(for: error)
            // Die Fähigkeit kann zwischen Prüfung und Start verschwinden; dann
            // gilt derselbe Fallback wie oben (§4 Punkt 2).
            guard mapped != .erkennungNichtMoeglich else {
                refreshAvailability()
                notice = availability.hinweis ?? VoiceFailure.erkennungNichtMoeglich.errorDescription
                return false
            }
            fail(mapped)
            return false
        }

        liveTranscript = ""
        transition(to: .hoerend)
        scheduleDictationTimer()
        return true
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
        } else if reason != .deadline {
            // §11.1: Stille liefert bewusst kein `onFinal` — der Hinweis ist
            // die einzige Rückmeldung („kein leerer Eintrag in draft“).
            notice = "Nichts verstanden."
        }
        // §8.3: freihändig läuft nach jedem Ergebnis weiter — aber nur, wenn
        // die App im Vordergrund ist, der Modus noch freihändig ist und der
        // Nutzer nicht selbst beendet hat.
        if handsFreeActive, isForeground, triggerMode == .handsFree, reason != .explicit {
            beginListeningSoon()
            return
        }
        // Erst wenn das Diktat wirklich endet, werden die während des Zuhörens
        // zurückgehaltenen Deltas gesprochen (I-V1, §6.3).
        speakDeferredDelta()
    }

    /// Übergibt das Diktat an den Entwurf — ohne automatisches Senden (§6).
    ///
    /// Leerer Text erreicht diese Stelle nicht: `finishSession` setzt für
    /// Stille den Hinweis (§11.1), und `appendDictation` verwirft Leeres.
    private func deliver(_ transcript: String) {
        guard let onTranscript else { return }
        let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.count > configuration.maxTranscriptCharacters {
            notice = "Diktat auf \(configuration.maxTranscriptCharacters) Zeichen gekürzt."
            onTranscript(String(trimmed.prefix(configuration.maxTranscriptCharacters)))
        } else {
            onTranscript(trimmed)
        }
    }

    private func handleDictationFailure(_ error: DictationError) {
        guard state == .hoerend else { return }
        fail(failure(for: error))
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
        teardownHandsFree()
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
    ///
    /// Während des Zuhörens darf nicht gesprochen werden (I-V1). Das Delta
    /// geht deshalb **nicht** in den Puffer — sonst entstehen fertige Sätze,
    /// die `enqueue` verwirft, und der Anfang der Antwort ist dauerhaft weg.
    /// Stattdessen wartet der Text bis zum Ende des Diktats.
    func ingestAssistantDelta(_ delta: String) {
        guard readAloudEnabled else { return }
        guard state != .hoerend else {
            deferredDelta += delta
            return
        }
        enqueue(sentenceBuffer.append(delta))
    }

    /// Restpuffer nach der Runde ausgeben (N3).
    func finishAssistantStream() {
        guard readAloudEnabled else { return }
        guard state != .hoerend else {
            deferredStreamFinished = true
            return
        }
        enqueue(sentenceBuffer.flush())
    }

    /// Holt die während des Zuhörens zurückgehaltenen Deltas nach (§6.3).
    private func speakDeferredDelta() {
        guard state != .hoerend else { return }
        let delta = deferredDelta
        let streamFinished = deferredStreamFinished
        deferredDelta = ""
        deferredStreamFinished = false
        guard readAloudEnabled, !delta.isEmpty else { return }

        var sentences = sentenceBuffer.append(delta)
        if streamFinished {
            sentences += sentenceBuffer.flush()
        }
        enqueue(sentences)
    }

    /// Bricht das Vorlesen sofort ab (T5, N4/N5); mehrfach aufrufbar.
    func stopSpeaking() {
        synthesizer.stop()
        sentenceBuffer.reset()
        deferredDelta = ""
        deferredStreamFinished = false
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
        deferredDelta = ""
        deferredStreamFinished = false
        refreshAvailability()
        refreshPermissions()
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
            teardownHandsFree()
            endDictation(reason: .explicit)
            stopSpeaking()
            return
        }
        // `.active` startet nichts von selbst (§8.3) — aber die Gerätefähigkeit
        // und die Freigaben werden neu gelesen, damit der Knopf nach einer
        // Änderung in den iOS-Einstellungen wieder stimmt (§4 Punkt 1).
        isForeground = true
        refreshAvailability()
        refreshPermissions()
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
