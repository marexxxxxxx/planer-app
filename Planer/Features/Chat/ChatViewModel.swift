//
//  ChatViewModel.swift
//  Planer
//
//  Zustand und Ablauf des Chat-Tabs: Sitzungen, Verlauf, Antwortstrom,
//  Denken, Werkzeugkarten und Freigabe (spec-chat Rev 4 §4, §5.3, §5.5).
//

import Combine
import Foundation
import UIKit

/// Führt den Chat: listet und lädt Sitzungen, sendet genau einen User-Turn,
/// führt Denken und Werkzeug-Lebenszeichen als Daten und beantwortet
/// Server-Freigaben.
///
/// Zweck: die Oberfläche bleibt dumm (`ChatView` rendert nur `entries`); alle
/// Zustandsübergänge — Laden, Senden, Abbruch, Freigabe, Fehler — passieren
/// hier.
/// Grenze: kein HTTP und keine Header (das macht `HermesChatAPI` bzw. der
/// Anbieter) und **keine** Werkzeugausführung: Werkzeuge laufen serverseitig.
/// Die Klasse ist `@MainActor`, weil sie direkt SwiftUI-Zustand hält.
@MainActor
final class ChatViewModel: ObservableObject {

    /// Die eine Instanz je Prozess (§3.5.4).
    ///
    /// Sie überlebt das Entfernen des View-Baums durch die App-Sperre. Nicht
    /// die View hält den Turn, sondern dieses Modell; die Sperre selbst bleibt
    /// unangetastet.
    static let shared = ChatViewModel()

    /// Hinweis nach der Rückkehr aus dem Hintergrund; wörtlich (§3.5.5).
    /// Er behauptet weder, der Turn habe weiterlief, noch dass er abbrach.
    static let backgroundResumeNotice = "Der Chat war im Hintergrund. Der Verlauf wurde vom Server neu geladen."

    /// Hinweis, wenn der Watchdog den lokalen Strom als tot verworfen hat
    /// (Rev 9, MARAAA-188).
    ///
    /// Zweck: Ein stiller und ein toter Strom sind nach der Rückkehr nicht
    /// unterscheidbar — der Ausgang muss deshalb ehrlich sein: die Verbindung
    /// ist **möglicherweise** abgerissen (Verlust), der Turn kann auf dem
    /// Server weiterlaufen, und „Verlauf neu laden“ ist der Weg dorthin.
    /// Grenze: kein Erfolgs-Hinweis; der Text wird als Warnung dargestellt
    /// (`noticeIsInformational == false`), weil er einen Verlust benennt. Er
    /// behauptet keine Ursache, die der Client nicht sehen kann (V5).
    static let backgroundStreamLostNotice = "Die Verbindung ist im Hintergrund möglicherweise abgerissen. Der Turn kann auf dem Server weiterlaufen — „Verlauf neu laden“ holt ihn."

    /// Hinweis, wenn der Watchdog wegen einer **abgelaufenen** Freigabe
    /// abgebrochen hat (V1, MARAAA-188).
    ///
    /// Zweck: Der Nutzer kann nicht mehr entscheiden (`ToolConfirmationChips`
    /// rendert für `.expired` nichts); der Turn wird beendet und der
    /// Serverstand nachgeladen. Grenze: nennt den Grund und den Wiederholweg,
    /// behauptet keinen Erfolg und keine Ursache auf dem Server.
    static let backgroundApprovalExpiredNotice = "Die Freigabe ist abgelaufen. Der Turn wurde beendet und der Verlauf nachgeladen — „Verlauf neu laden“ holt den Serverstand."

    /// Eine Zeile im Verlauf.
    struct Entry: Identifiable, Equatable {
        enum Kind: Equatable {
            case user
            case agent
            case tool
            case approval
        }

        /// Sichtbarkeit einer Detailfläche. Default ist immer `.collapsed`.
        enum Disclosure: Equatable {
            case collapsed
            case expanded
        }

        let id: UUID
        var kind: Kind
        var text: String

        // Agent
        /// `nil` heißt: kein Denken geliefert (A3) — keine Zeile, kein Platzhalter.
        var reasoning: String?
        var reasoningDisclosure: Disclosure = .collapsed
        /// `true`, sobald die Klappe für diesen Eintrag automatisch geöffnet
        /// wurde (Rev 6 O4). Danach öffnet/schließt die Automatik diesen
        /// Eintrag nie wieder.
        var reasoningAutoExpanded: Bool = false
        var engine: ChatEngine?
        /// Dauer der Erzeugung in Sekunden (roh, ungerundet). `nil` = unbekannt.
        ///
        /// Quelle ist der Server-Zeitstempel (`generationDurations`) oder, nur
        /// für den laufenden Turn, die lokale Messung (Rev 8 §3.3.2).
        var generationDuration: TimeInterval?

        // Werkzeug
        var toolCallID: String?
        var toolName: String?
        /// E4: `emoji` aus `hermes.tool.progress` (nur bei `running` gesetzt).
        /// `nil` = kein Emoji geliefert (gespeicherte Nachrichten) → generisches Symbol.
        var toolEmoji: String?
        /// JSON-Text, roh aus `tool_calls[].function.arguments`.
        var toolArgs: String?
        /// Text aus der `tool`-Nachricht.
        var toolResult: String?
        var toolStatus: ToolCallStatus?
        var toolDetailDisclosure: Disclosure = .collapsed

        // Freigabe
        var approval: ChatApproval?
        /// Gespeicherter Zustand des Freigabe-POSTs; `.expired` entsteht nur
        /// über `ApprovalPhase.derive` (§5.1).
        var approvalPhase: ApprovalPhase = .open
        /// Empfangszeit des `approval.request`; `nil` = keine Frist bekannt.
        var approvalReceivedAt: Date?
        /// Name der letzten Werkzeugkarte dieses Turns zum Empfangszeitpunkt
        /// (`approval.request` trägt kein Werkzeugfeld, §0.4).
        var approvalToolName: String?
        /// `true`, wenn der Befehl die Obergrenze überschreitet — dann gibt es
        /// keinen „Ausführen“-Knopf (FF-4).
        var approvalCommandTooLong: Bool = false

        /// `true`, sobald der POST beantwortet wurde. Berechnet aus dem
        /// gespeicherten Zustand: die Frist ist kein POST-Ergebnis (§4.2).
        var approvalResolved: Bool { !approvalPhase.waitsForUser }

        init(
            id: UUID = UUID(),
            kind: Kind,
            text: String,
            reasoning: String? = nil,
            reasoningDisclosure: Disclosure = .collapsed,
            engine: ChatEngine? = nil,
            generationDuration: TimeInterval? = nil,
            toolCallID: String? = nil,
            toolName: String? = nil,
            toolEmoji: String? = nil,
            toolArgs: String? = nil,
            toolResult: String? = nil,
            toolStatus: ToolCallStatus? = nil,
            toolDetailDisclosure: Disclosure = .collapsed,
            approval: ChatApproval? = nil,
            reasoningAutoExpanded: Bool = false
        ) {
            self.id = id
            self.kind = kind
            self.text = text
            self.reasoning = reasoning
            self.reasoningDisclosure = reasoningDisclosure
            self.reasoningAutoExpanded = reasoningAutoExpanded
            self.engine = engine
            self.generationDuration = generationDuration
            self.toolCallID = toolCallID
            self.toolName = toolName
            self.toolEmoji = toolEmoji
            self.toolArgs = toolArgs
            self.toolResult = toolResult
            self.toolStatus = toolStatus
            self.toolDetailDisclosure = toolDetailDisclosure
            self.approval = approval
        }
    }

    // MARK: Zustand

    @Published private(set) var sessions: [SessionSummary] = []
    @Published private(set) var currentSession: SessionSummary?
    @Published private(set) var entries: [Entry] = []
    @Published private(set) var isLoadingSessions = false
    @Published private(set) var isLoadingHistory = false
    @Published private(set) var isStreaming = false
    /// Die sichtbare Meldung über dem Verlauf.
    ///
    /// Rev 9 (MARAAA-188): jede Zuweisung fällt über `didSet` auf die
    /// Fehler-Optik zurück. Nur der Hintergrund-Hinweis setzt danach
    /// `noticeIsInformational` — ein späterer Fehler kann dessen Optik also
    /// nicht erben.
    @Published private(set) var notice: String? {
        didSet { noticeIsInformational = false }
    }
    /// `true` = `notice` ist ein Hinweis und kein Fehler.
    ///
    /// Zweck: Der Text „Der Chat war im Hintergrund …“ ist eine Auskunft; er
    /// darf nicht wie ein Abbruch aussehen. Grenze: eigene, explizite
    /// Unterscheidung — **kein** Vergleich auf den Meldungstext.
    @Published private(set) var noticeIsInformational = false
    @Published private(set) var statusNote: ChatStatusNote?
    @Published var draft = ""
    @Published private(set) var hasMoreOlder = false
    /// Befund 14: „Mehr laden“ ist erlaubt, solange noch keine leere Seite kam.
    @Published private(set) var loadedAllSessions = false
    /// Der Freigabe-Eintrag, dessen POST gerade läuft (Chips sind dann inaktiv).
    @Published private(set) var decidingApprovalEntryID: UUID?
    /// Startzeit des laufenden Turns; `nil` = keine Arbeits-Animation.
    @Published private(set) var turnStartedAt: Date?
    /// Ein Timeout mitten im Strom lässt den Teiltext stehen und bietet den
    /// Weg über den Verlauf an (Rev 6 O3).
    @Published private(set) var offersHistoryReload = false

    /// Die Sprachschicht (V3, §9.6). `ChatView` setzt sie nach dem Erzeugen des
    /// Modells — ein `@StateObject` erlaubt keinen Environment-Zugriff im
    /// Initializer.
    ///
    /// `nil` heißt: kein Vorlesen und kein Diktat — der Chat funktioniert
    /// unverändert.
    var voice: (any VoiceAssistant)?

    private let preferences: ChatPreferences
    private let apiFactory: (HermesChatConfiguration) -> HermesChatAPI
    /// Baut den Anbieter; der zweite Wert ist der gemeinsame Zeilenzähler des
    /// Stroms (Rev 9, MARAAA-188). Ein Testanbieter darf ihn ignorieren.
    private let providerFactory: (HermesChatConfiguration, ChatStreamLiveness) -> any ChatStreamProvider
    private var api: HermesChatAPI
    private var provider: any ChatStreamProvider
    /// Wird ausschließlich aus `preferences.configuration` gesetzt; ein neuer
    /// Nutzerwert gilt ab dem nächsten Turn (Rev 6 §3.2.3).
    private var configuration: HermesChatConfiguration

    private var streamTask: Task<Void, Never>?
    /// Der Verlaufsabgleich eines Turns (spec-chat-live-activity §5.1/2).
    ///
    /// Grenze: genau **eine** Schleife je Turn. Sie startet mit dem ersten
    /// Werkzeug-Frame, endet im `defer` von `streamTurn` und läuft nie über
    /// den Turn hinaus. `non-nil` nach dem Ende heißt „in diesem Turn schon
    /// gelaufen“ — ein weiterer Werkzeug-Frame startet sie nicht neu.
    private var liveActivityTask: Task<Void, Never>?
    /// A1 (Rev 9, MARAAA-188): Schonfrist-Task nach der Rückkehr aus dem
    /// Hintergrund; `nil` = kein laufender Watchdog.
    ///
    /// Grenze: genau **ein** Task. Er läuft als Schleife (je Runde
    /// `sleep(grace)`, danach Lebenszeichen vergleichen) und wird bei
    /// Turn-Ende, beim Wechsel in den Hintergrund, beim Senden und im `deinit`
    /// abgebrochen.
    private var resumeWatchdogTask: Task<Void, Never>?
    /// Zahl der im laufenden Turn empfangenen Ereignisse — **ein** Teil des
    /// Lebenszeichens, an dem der Watchdog „lebt noch“ von „ist tot“
    /// unterscheidet.
    private var streamEventCount = 0
    /// Der zweite Teil des Lebenszeichens: jede aus dem Strom gelesene Zeile,
    /// auch Kommentare/Keepalives und verworfene Ereignisse (Rev 9). Die
    /// Referenz gehört dem Anbieter, gelesen wird sie hier.
    private let liveness = ChatStreamLiveness()
    /// E3 (Rev 9, MARAAA-188): Generation, deren Strom der Watchdog hart
    /// geschlossen hat; `nil` = keine. `run` darf für **genau diese** Generation
    /// weder melden noch mergen — sonst überschriebe der Abbruch-Fehler die
    /// ehrliche Meldung.
    ///
    /// V2: turn-gebunden statt modellweit. Ein neuer Turn setzt den Riegel in
    /// `send()` zurück und kann von einem Zombie-Task des alten nicht getroffen
    /// werden.
    private var abandonedGeneration: Int?
    /// Monoton steigende Nummer des zuletzt in `send()` begonnenen Turns.
    ///
    /// Zweck (V2): `run` und der Watchdog führen ihre Nummer als Konstante mit.
    /// Jede Turn-Zustandsänderung prüft `generation == turnGeneration`; ein
    /// alter Task, der das harte Schließen überlebt, kann so weder den
    /// `defer`-Zustand des neuen Turns zurücksetzen noch dessen Watchdog
    /// abbrechen oder in dessen Merge schreiben.
    private var turnGeneration = 0
    /// Höchste bereits dargestellte Nachrichten-ID; `0` ist die Baseline einer
    /// geladenen, aber leeren Session (E5) — nie eine echte Server-ID.
    private var watermark: Int?
    private var optimisticUserEntryID: UUID?
    /// Während des Stroms angelegte Agent-/Werkzeug-/Freigabe-Einträge.
    private var turnEntryIDs: Set<UUID> = []
    /// R1: `true`, sobald der Antwortstrom angefordert wurde. Steuert keine
    /// sichtbare Affordance und ist deshalb nicht `@Published` (Rev 8 §3.2.1).
    private var streamRequested = false
    /// R2, Rang 2: die lokale Messung des laufenden Turns für den Merge.
    /// `nil` außerhalb eines Turns (Rev 8 §4.5).
    private var mergeFallbackDuration: TimeInterval?
    /// `true`, sobald der Strom tatsächlich ein Ereignis geliefert hat. Davor
    /// gilt ein Fehler als „nichts gesendet“ (§4.8/F10).
    ///
    /// F2: beobachtbar, damit der Wechsel „verbindet“ → „denkt“ die
    /// Phasen-Zeile sofort neu rendert; die Ableitung in `turnPhase` bleibt
    /// unverändert.
    @Published private(set) var streamStarted = false
    /// E5: Verlauf wirklich geladen — auch eine leere Seite zählt. Privat; die
    /// View liest den Zustand ausschließlich über `canSend` (§9.3).
    private var historyLoaded = false
    /// Die Session wurde in genau diesem Turn per `POST /api/sessions` angelegt;
    /// nur dann ist `watermark == nil` für den Merge zulässig (§5.5).
    private var createdSessionThisTurn = false
    /// Der Verlauf war beim Senden leer (F15: Header fehlt ⇒ Warnung).
    private var turnHistoryWasEmpty = false
    /// H1: Der Server hat den Session-Header in der Antwort mitgeschickt.
    private var receivedSessionHeader = false
    private var sessionOffset = 0
    private var historyPagesLoaded = 0
    private var didWarnReasoningTruncated = false
    /// Beobachter des App-Lebenszyklus; einmal je Instanz registriert (§3.5.2).
    private var lifecycleObservers: [NSObjectProtocol] = []
    /// `true`, wenn seit dem letzten Hintergrundwechsel ein Turn lief.
    private var resumeAfterBackground = false
    /// Die laufende Hintergrund-Aufgabe; `.invalid` = keine (§5.1).
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid

    init(
        preferences: ChatPreferences = .shared,
        apiFactory: @escaping (HermesChatConfiguration) -> HermesChatAPI = {
            HermesChatAPI(configuration: $0)
        },
        providerFactory: @escaping (HermesChatConfiguration, ChatStreamLiveness) -> any ChatStreamProvider = {
            HermesChatStreamProvider(configuration: $0, liveness: $1)
        }
    ) {
        self.preferences = preferences
        self.apiFactory = apiFactory
        self.providerFactory = providerFactory
        self.configuration = preferences.configuration
        self.api = apiFactory(self.configuration)
        self.provider = providerFactory(self.configuration, self.liveness)
        registerLifecycleObservers()
    }

    deinit {
        // A1: der Watchdog wird hier abgebrochen. Grenze (V6): solange eine
        // Runde in `Task.sleep` liegt, hält die Schleife `self` **nicht** —
        // sie arbeitet mit einem Schnappschuss (siehe
        // `scheduleResumeWatchdog`); nur die laufende Runde selbst kann den
        // Abbruch noch um einen Schritt verzögern.
        resumeWatchdogTask?.cancel()
        for observer in lifecycleObservers {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    // MARK: Konfiguration

    /// Baut API und Provider neu, wenn ein Nutzerwert sich geändert hat. Ein
    /// laufender Strom wird nicht angefasst (Rev 6 §3.2.3).
    ///
    /// Grenze (N1.2/F6): während `isStreaming` wird nichts ersetzt. Ein Turn
    /// behält `configuration`, `api` und `provider`, mit denen er gestartet
    /// ist — sonst liefen Freigabe-POST, Merge und Timeout-Meldung nach einem
    /// Profilwechsel über ein anderes Profil als der Strom. Geänderte
    /// Nutzerwerte gelten ab dem nächsten Turn.
    private func refreshConfiguration() {
        guard !isStreaming else { return }
        let wanted = preferences.configuration
        guard wanted != configuration else { return }
        configuration = wanted
        api = apiFactory(wanted)
        provider = providerFactory(wanted, liveness)
    }

    // MARK: Abgeleiteter Zustand

    var canSend: Bool {
        !isStreaming
            && !isLoadingHistory
            && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            // E5: eine bestehende Session darf erst senden, wenn ihr Verlauf
            // (auch eine leere Seite) geladen ist. `nil` = neue Session.
            && (currentSession == nil || historyLoaded)
    }

    // MARK: Live-Status

    /// Die Phase des laufenden Turns; `nil` außerhalb eines Turns (§4.3).
    ///
    /// Berechnet aus `isStreaming`, `streamStarted`, `turnEntryIDs` und
    /// `entries` — kein gespeicherter Zustand, kein Setter und damit auch
    /// nichts, das nach einem Abbruch hängen bliebe.
    var turnPhase: ChatTurnPhase? {
        guard isStreaming else { return nil }

        let hasWaitingApproval = entries.contains { entry in
            entry.kind == .approval
                && turnEntryIDs.contains(entry.id)
                && ApprovalPhase.derive(
                    stored: entry.approvalPhase,
                    receivedAt: entry.approvalReceivedAt,
                    timeout: configuration.approvalTimeout,
                    now: Date()
                ).waitsForUser
        }
        if hasWaitingApproval { return .awaitingApproval }

        if let runningTool = entries.last(where: {
            turnEntryIDs.contains($0.id) && $0.kind == .tool && $0.toolStatus == .running
        }), let name = runningTool.toolName, !name.isEmpty {
            return .tool(name: name)
        }

        if let lastAgent = entries.last(where: {
            $0.kind == .agent && turnEntryIDs.contains($0.id)
        }), !lastAgent.text.isEmpty {
            return .writing
        }

        // spec-chat-live-activity §5.1/4: „Denkt nach“ ist erst wahr, wenn
        // Denken ankommt. Davor — verbunden, aber ohne Inhalt — steht die
        // ehrliche Wartezeile. Die Reihenfolge ist verbindlich: Freigabe →
        // Werkzeug → Text → Warten → Denken.
        if let lastAgent = entries.last(where: {
            $0.kind == .agent && turnEntryIDs.contains($0.id)
        }), let reasoning = lastAgent.reasoning, !reasoning.isEmpty {
            return .thinking
        }

        if !streamStarted { return .connecting }
        return .waitingForModel
    }

    // MARK: Arbeitsanzeige

    /// `true`, solange der Turn läuft und noch kein Antworttext dieses Turns
    /// vorliegt — oder eine Werkzeugkarte gerade ausgeführt wird (Rev 6 O5).
    var showsWorkingIndicator: Bool {
        guard isStreaming else { return false }
        if entries.contains(where: { $0.kind == .tool && $0.toolStatus == .running }) {
            return true
        }
        guard let lastAgent = entries.last(where: {
            $0.kind == .agent && turnEntryIDs.contains($0.id)
        }) else {
            return true
        }
        return lastAgent.text.isEmpty
    }

    // MARK: Verlauf neu laden

    /// Setzt das Angebot „Verlauf neu laden“ — derselbe Zustand für den
    /// Strom-Timeout (O3) und die gescheiterte Turn-Rettung (Rev 8 §4.3).
    ///
    /// Grenze: ein Setter; die View liest `offersHistoryReload` nur.
    private func offerHistoryReload() {
        offersHistoryReload = true
    }

    /// Anschluss nach einem Strom-Timeout: lädt den serverseitig
    /// persistierten Turn neu, statt einen zweiten Strom zu öffnen (O3).
    func reloadHistory() async {
        offersHistoryReload = false
        if let session = currentSession {
            await openSession(session)
        } else {
            await loadSessions()
        }
        // E6 (Rev 9, MARAAA-188): scheitert auch das erneute Laden, bleibt der
        // Wiederholweg sichtbar — sonst bliebe der Composer ohne Weg gesperrt.
        if !historyLoaded, currentSession != nil { offerHistoryReload() }
    }

    // MARK: Verlauf

    /// Lädt die erste Seite der Sitzungsliste. Der Server liefert alle Quellen;
    /// die App blendet ausschließlich interne Quellen aus (MARAAA-155).
    func loadSessions() async {
        refreshConfiguration()
        guard !isLoadingSessions else { return }
        isLoadingSessions = true
        defer { isLoadingSessions = false }

        do {
            let page = try await api.listSessions(
                limit: configuration.sessionPageSize,
                offset: 0
            )
            sessions = page.sessions.filter { configuration.showsSessionSource($0.source) }
            sessionOffset = page.sessions.count
            loadedAllSessions = page.sessions.isEmpty
            syncCurrentSessionWithList()
        } catch {
            // Kein Cache: eine nicht erreichbare Liste wird nicht als leerer
            // Verlauf ausgegeben.
            sessions = []
            loadedAllSessions = false
            notice = isUnreachable(error)
                ? "Offline — der Verlauf ist nicht erreichbar."
                : displayText(for: error)
        }
    }

    /// Nächste Seite. Abgebrochen wird erst bei einer **leeren** Seite, nicht
    /// bei `has_more` (bei Pins unzuverlässig).
    func loadMoreSessions() async {
        refreshConfiguration()
        guard !isLoadingSessions, !loadedAllSessions else { return }
        isLoadingSessions = true
        defer { isLoadingSessions = false }

        do {
            let page = try await api.listSessions(
                limit: configuration.sessionPageSize,
                offset: sessionOffset
            )
            let known = Set(sessions.map(\.id))
            let fresh = page.sessions.filter {
                configuration.showsSessionSource($0.source) && !known.contains($0.id)
            }
            sessions.append(contentsOf: fresh)
            sessionOffset += page.sessions.count
            loadedAllSessions = page.sessions.isEmpty
        } catch {
            notice = displayText(for: error)
        }
    }

    /// Öffnet eine Unterhaltung und lädt die neuesten Nachrichten.
    func openSession(_ summary: SessionSummary) async {
        refreshConfiguration()
        guard !isStreaming, !isLoadingHistory else { return }
        isLoadingHistory = true
        notice = nil
        statusNote = nil
        currentSession = summary
        entries = []
        watermark = nil
        historyLoaded = false
        hasMoreOlder = false
        historyPagesLoaded = 0
        didWarnReasoningTruncated = false
        // F3/N1.4: „Verlauf neu laden“ gehört ausschließlich zur
        // Timeout-Meldung des Turns, in dem der Timeout auftrat.
        offersHistoryReload = false
        defer { isLoadingHistory = false }

        do {
            let page = try await api.messages(
                sessionID: summary.id,
                limit: configuration.messagePageSize,
                offset: 0,
                order: .latest
            )
            entries = Self.map(messages: page.messages, engine: .hermes)
            // E5: auch eine leere, gültige Seite gibt den Composer frei. Die
            // Baseline `0` verhindert, dass alte Historie als neuer Turn gilt.
            watermark = page.messages.map(\.id).max() ?? 0
            historyLoaded = true
            historyPagesLoaded = 1
            hasMoreOlder = page.returned == configuration.messagePageSize
        } catch {
            if isNotFound(error) {
                currentSession = nil
                entries = []
                watermark = nil
                historyLoaded = false
                hasMoreOlder = false
                await loadSessions()
                notice = "Die Unterhaltung existiert nicht mehr."
            } else if isUnreachable(error) {
                notice = "Offline — der Verlauf ist nicht erreichbar."
            } else {
                notice = displayText(for: error)
            }
        }
    }

    /// Ältere Nachrichten voranstellen. Der Anker für die Scrollposition ist
    /// die stabile `Entry.id` des bisher ersten Eintrags.
    func loadOlderMessages() async {
        refreshConfiguration()
        guard let session = currentSession,
              !isLoadingHistory,
              !isStreaming,
              hasMoreOlder
        else { return }
        guard historyPagesLoaded < configuration.maxMessagePages else {
            hasMoreOlder = false
            return
        }
        isLoadingHistory = true
        defer { isLoadingHistory = false }

        do {
            let page = try await api.messages(
                sessionID: session.id,
                limit: configuration.messagePageSize,
                offset: historyPagesLoaded * configuration.messagePageSize,
                order: .latest
            )
            let older = Self.map(messages: page.messages, engine: .hermes)
            entries.insert(contentsOf: older, at: 0)
            historyPagesLoaded += 1
            hasMoreOlder = page.returned == configuration.messagePageSize
                && historyPagesLoaded < configuration.maxMessagePages
            if historyPagesLoaded >= configuration.maxMessagePages {
                let total = configuration.maxMessagePages * configuration.messagePageSize
                notice = "Verlauf zeigt die letzten \(total) Nachrichten."
            }
        } catch {
            notice = "Der Verlauf konnte nicht geladen werden."
        }
    }

    // MARK: Neuer Chat

    /// Setzt nur den lokalen Zustand zurück — es wird **keine** Sitzung
    /// angelegt (sonst entstünden leere Geister-Sitzungen).
    func newChat() {
        guard !isStreaming else { return }
        voice?.stopSpeaking()
        entries = []
        currentSession = nil
        watermark = nil
        historyLoaded = false
        hasMoreOlder = false
        historyPagesLoaded = 0
        notice = nil
        statusNote = nil
        // F3/N1.4: ein neuer Chat trägt kein Timeout-Angebot des alten Turns.
        offersHistoryReload = false
    }

    // MARK: Senden

    /// Startet das Senden der aktuellen Eingabe.
    ///
    /// Grenze: leere Eingaben, laufende Turns und ein halb geladener Verlauf
    /// werden ignoriert; zu lange Eingaben werden mit Hinweis abgelehnt, nicht
    /// abgeschnitten.
    func send() {
        refreshConfiguration()
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isStreaming, !isLoadingHistory else { return }
        guard text.count <= configuration.maxDraftCharacters else {
            notice = "Die Nachricht ist länger als \(configuration.maxDraftCharacters) Zeichen."
            return
        }

        draft = ""
        notice = nil
        statusNote = nil
        // N4: der Nutzer sendet — laufendes Vorlesen endet sofort.
        voice?.stopSpeaking()

        // E5/M4: Der Verlauf muss geladen sein, sonst ist kein Merge erlaubt.
        // `canSend` prüft das bereits; hier steht der zweite, billige Riegel.
        guard currentSession == nil || historyLoaded else {
            draft = text
            notice = "Der Verlauf ist noch nicht geladen."
            return
        }

        let entry = Entry(kind: .user, text: text)
        entries.append(entry)
        optimisticUserEntryID = entry.id
        turnEntryIDs = []
        streamStarted = false
        streamRequested = false
        // A1: ein neuer Turn beginnt ohne Lebenszeichen und ohne alte Frist.
        cancelResumeWatchdog()
        streamEventCount = 0
        // Rev 9: auch der Zeilenzähler und der Abbruch-Riegel gehören zu genau
        // diesem Turn. V2: die Nummer steigt **vor** dem Task; `run` führt sie
        // als Konstante mit, damit ein alter Task den neuen nicht trifft.
        turnGeneration += 1
        let generation = turnGeneration
        liveness.reset()
        abandonedGeneration = nil
        mergeFallbackDuration = nil
        createdSessionThisTurn = false
        receivedSessionHeader = false
        turnHistoryWasEmpty = watermark == nil || watermark == 0
        // Ein Hinweis „Denken wurde gekürzt.“ gilt je Turn, nicht je Chat.
        didWarnReasoningTruncated = false

        isStreaming = true
        turnStartedAt = Date()
        offersHistoryReload = false
        streamTask = Task { await run(text: text, generation: generation) }
    }

    /// Bricht die laufende Antwort ab. Ein Abbruch ist kein Fehler und kein
    /// Erfolg: kein Merge, kein Server-Aufruf.
    func cancel() {
        voice?.stopSpeaking()
        streamTask?.cancel()
        streamTask = nil
        turnStartedAt = nil
        offersHistoryReload = false
        notice = "Antwort abgebrochen."
        statusNote = nil
    }

    /// Verlässt der Nutzer den Tab, läuft der Turn weiter (der Server speichert
    /// ihn); nur das Vorlesen endet.
    func detach() {
        voice?.stopSpeaking()
    }

    /// Übernimmt ein diktiertes Ergebnis in den Entwurf — gesendet wird nicht.
    func appendDictation(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        let combined = draft.isEmpty ? trimmed : draft + " " + trimmed
        if combined.count > configuration.maxDraftCharacters {
            draft = String(combined.prefix(configuration.maxDraftCharacters))
            notice = "Der Entwurf wurde auf \(configuration.maxDraftCharacters) Zeichen gekürzt."
        } else {
            draft = combined
        }
    }

    func dismissNotice() {
        notice = nil
        offersHistoryReload = false
    }

    // MARK: App-Lebenszyklus

    /// Registriert die beiden Lebenszyklus-Beobachter (§3.5.2).
    ///
    /// Benachrichtigungen statt `scenePhase`: `PlanerApp` setzt beim Wechsel in
    /// den Hintergrund sofort `isUnlocked = false` und entfernt den View-Baum.
    /// Ein `@Environment(\.scenePhase)` in `ChatView` käme zu spät; das
    /// ViewModel überlebt den Baum und empfängt die Benachrichtigung.
    private func registerLifecycleObservers() {
        let center = NotificationCenter.default
        lifecycleObservers = [
            center.addObserver(
                forName: UIApplication.didEnterBackgroundNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in
                    self?.handleDidEnterBackground()
                }
            },
            center.addObserver(
                forName: UIApplication.willEnterForegroundNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in
                    self?.handleWillEnterForeground()
                }
            }
        ]
    }

    /// Ohne laufenden Turn passiert nichts — kein Hintergrund-Task, kein
    /// Merker. Sonst merkt sich das Modell den Turn und bittet iOS um Zeit.
    func handleDidEnterBackground() {
        // A1: im Hintergrund entscheidet kein Watchdog; die Rückkehr stellt
        // ihn neu (Rev 9, MARAAA-188).
        cancelResumeWatchdog()
        guard isStreaming else { return }
        resumeAfterBackground = true
        beginBackgroundTaskIfNeeded()
    }

    /// Beendet die Hintergrund-Aufgabe **immer**; lädt nur nach, wenn ein Turn
    /// lief und der Strom nicht mehr lebt (E15: der Strom gewinnt).
    func handleWillEnterForeground() {
        endBackgroundTaskIfNeeded()
        guard resumeAfterBackground else { return }
        resumeAfterBackground = false
        guard !isStreaming else {
            // A1 (Rev 9, MARAAA-188): Ein Strom, der die Suspension überlebt
            // hat, gewinnt weiterhin (E15/B14) — aber nur, solange er lebt.
            // Der Watchdog bricht ihn nach der Schonfrist ab, wenn seit der
            // Rückkehr kein einziges Ereignis mehr ankam.
            scheduleResumeWatchdog()
            return
        }
        Task { await reconcileAfterBackground() }
    }

    /// Lädt den Serverstand über den vorhandenen, getesteten Verlaufspfad
    /// (`openSession` → `GET /api/sessions/{id}/messages`).
    ///
    /// Grenze: keine zweite Merge-Logik und keine eigene Fehlerbehandlung —
    /// `openSession` setzt seine Meldung selbst; nur wenn keine da ist, kommt
    /// der Hintergrund-Hinweis (§3.5.3). `announcesResume == false` unterdrückt
    /// genau diesen Erfolgs-Hinweis: nach einem verworfenen Turn behauptet
    /// niemand, das Nachladen sei der ganze Ausgang (Rev 9, E1).
    func reconcileAfterBackground(announcesResume: Bool = true) async {
        guard !isStreaming else { return }
        guard let session = currentSession else { return }
        await openSession(session)
        // A2 (Rev 9, MARAAA-188): Ein gescheitertes Nachladen darf den
        // Composer nicht ohne Weg sperren (`canSend` verlangt `historyLoaded`).
        // Der vorhandene Knopf „Verlauf neu laden“ bleibt deshalb sichtbar.
        if !historyLoaded { offerHistoryReload() }
        if announcesResume, notice == nil {
            notice = Self.backgroundResumeNotice
            // Der Hinweis ist eine Auskunft, kein Fehler (A5). Nach einem
            // verworfenen Turn steht hier stattdessen der ehrliche Verlust-Text
            // (E1) — dann bleibt diese Zeile aus.
            noticeIsInformational = true
        }
        resumeAfterBackground = false
    }

    // MARK: Rückkehr aus dem Hintergrund (Rev 9)

    /// Das Lebenszeichen des laufenden Turns (Rev 9, MARAAA-188).
    ///
    /// Es besteht aus **beiden** Quellen: ausgelieferte Ereignisse
    /// (`streamEventCount`) **und** gelesene Zeilen (`liveness.lineCount` —
    /// Kommentare, Keepalives, verworfene Ereignisse). Nur die Ereignisse zu
    /// zählen hielte einen gesunden Strom, der gerade nur Keepalives schickt,
    /// für tot.
    private var resumeLiveness: ResumeLiveness {
        ResumeLiveness(events: streamEventCount, lines: liveness.lineCount)
    }

    /// Wertvergleich zweier Lebenszeichen. `Equatable` genügt: der Watchdog
    /// fragt „hat sich seit dem letzten Blick etwas geändert?“, nicht „wie
    /// viel kam dazu?“.
    private struct ResumeLiveness: Equatable {
        let events: Int
        let lines: Int
    }

    /// A1: Schonfrist nach der Rückkehr, solange der Strom noch als laufend
    /// gilt.
    ///
    /// Zweck: Eine im Hintergrund abgerissene Anfrage liefert nie einen
    /// Fehler; ihr Request lebt bis `streamIdleTimeout` (Default 900 s)
    /// weiter. Ohne Frist bliebe `isStreaming` true und der Composer gesperrt.
    /// Grenze: greift nur, solange sich das Lebenszeichen nicht ändert; ein
    /// lebender Strom bleibt unangetastet (E15/B14). Solange eine Freigabe
    /// dieses Turns **entscheidbar** ist, läuft die Frist weiter statt
    /// abzubrechen; eine nur noch abgelaufene Freigabe ist kein Grund zu
    /// warten (V1) und endet im Abbruch-Pfad mit eigenem Wortlaut.
    ///
    /// Aufbau: **eine** Task mit Schleife — je Runde `sleep(grace)`, danach
    /// Lebenszeichen vergleichen; hat es sich geändert, beginnt die nächste
    /// Runde, sonst ist der Strom tot. Kein Task je Ereignis, genau ein
    /// gespeicherter Task (`resumeWatchdogTask`). V2: die Generation wird vor
    /// der Schleife festgehalten; V6: über den `sleep` hält der Rumpf nur
    /// einen Schnappschuss, nicht `self`.
    private func scheduleResumeWatchdog() {
        cancelResumeWatchdog()
        let generation = turnGeneration
        resumeWatchdogTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let snapshot = self?.resumeWatchdogSnapshot() else { return }
                do {
                    try await Task.sleep(
                        nanoseconds: UInt64(snapshot.gracePeriod * 1_000_000_000)
                    )
                } catch {
                    // Abgebrochen: der Turn ist zu Ende (run-Defer) oder der
                    // Nutzer ist wieder im Hintergrund.
                    return
                }
                guard !Task.isCancelled, let self, generation == self.turnGeneration else { return }
                guard self.isStreaming else { return }
                // V1: Nur eine **entscheidbare** Freigabe dieses Turns ist
                // legitime Stille. `.expired` wartet zwar serverseitig weiter
                // (`waitsForUser`), ist für den Nutzer aber nicht mehr zu
                // beantworten — die Ausnahme darf ihn nicht bis
                // `streamIdleTimeout` (900 s) sperren.
                if self.hasDecidableApproval { continue }
                // Neues Lebenszeichen in dieser Runde ⇒ der Strom lebt, die
                // nächste Frist beginnt. Sonst: seit einer vollen Frist still.
                let marker = snapshot.marker
                if self.resumeLiveness != marker { continue }
                await self.abandonDeadStreamIfNeeded(
                    generation: generation,
                    approvalExpired: self.hasExpiredApproval
                )
                return
            }
        }
    }

    /// Was eine Watchdog-Runde über den `sleep` hinweg braucht (V2/V6).
    private struct ResumeWatchdogSnapshot {
        let marker: ResumeLiveness
        let gracePeriod: TimeInterval
    }

    /// `nil` = kein laufender Turn; die Runde endet dann ohne Abbruch.
    private func resumeWatchdogSnapshot() -> ResumeWatchdogSnapshot? {
        guard isStreaming else { return nil }
        return ResumeWatchdogSnapshot(
            marker: resumeLiveness,
            gracePeriod: max(configuration.backgroundResumeGracePeriod, 0)
        )
    }

    /// `true`, solange eine Freigabe **dieses** Turns noch entscheidbar ist
    /// (abgeleitete Phase `.open`).
    ///
    /// Grenze: bewusst `acceptsDecision`, nicht `waitsForUser` — `.expired`
    /// wartet serverseitig weiter, hat aber keine Chips mehr (V1).
    private var hasDecidableApproval: Bool {
        entries.contains { entry in
            entry.kind == .approval
                && turnEntryIDs.contains(entry.id)
                && derivedApprovalPhase(of: entry).acceptsDecision
        }
    }

    /// `true`, wenn eine Freigabe dieses Turns nach Client-Frist abgelaufen ist.
    private var hasExpiredApproval: Bool {
        entries.contains { entry in
            entry.kind == .approval
                && turnEntryIDs.contains(entry.id)
                && derivedApprovalPhase(of: entry) == .expired
        }
    }

    /// Die abgeleitete Phase eines Eintrags — eine Stelle für Karte, Riegel
    /// und Watchdog.
    private func derivedApprovalPhase(of entry: Entry) -> ApprovalPhase {
        ApprovalPhase.derive(
            stored: entry.approvalPhase,
            receivedAt: entry.approvalReceivedAt,
            timeout: configuration.approvalTimeout,
            now: Date()
        )
    }

    /// Bricht den Watchdog ab; idempotent. Grenze: der Antwortstrom bleibt
    /// unberührt — abgebrochen wird nur die Frist.
    private func cancelResumeWatchdog() {
        resumeWatchdogTask?.cancel()
        resumeWatchdogTask = nil
    }

    /// A1/E1: Der Strom hat eine volle Frist ohne Lebenszeichen überstanden —
    /// er gilt als tot. Er wird abgebrochen, der Turn-Zustand hart geschlossen
    /// und der serverseitig gespeicherte Turn über den vorhandenen Pfad geladen
    /// (`reconcileAfterBackground` → `openSession`).
    ///
    /// Grenze: kein zweiter Strom und keine zweite Merge-Logik. Der Abbruch ist
    /// ein technischer, kein Nutzerabbruch; der Ausgang ist ein **Verlust**,
    /// kein Erfolg (E1) — deshalb der eigene Text und der Wiederholweg.
    /// `approvalExpired` wählt den Grund im Text (V1); beide Texte nennen den
    /// Wiederholweg.
    private func abandonDeadStreamIfNeeded(generation: Int, approvalExpired: Bool) async {
        // V2: nur der aktuelle Turn darf geschlossen werden. Ein Watchdog
        // eines alten Turns hat hier nichts zu tun.
        guard generation == turnGeneration else { return }
        // Vor dem Abbruch freigeben: das Turn-Ende ruft `cancelResumeWatchdog()`
        // und darf diesen Task nicht selbst kündigen — er lädt gleich nach.
        resumeWatchdogTask = nil
        guard isStreaming else { return }

        // E3/V2: `run` darf ab hier weder melden noch mergen — sonst
        // überschriebe „Antwort abgebrochen.“ die ehrliche Meldung oder ein
        // Merge den gerade geladenen Serverstand. Der Riegel gilt nur für
        // **diese** Generation; `send()` setzt ihn für den nächsten Turn
        // zurück.
        abandonedGeneration = generation
        let runningTask = streamTask
        runningTask?.cancel()
        // E3: begrenztes Warten statt eines Waits auf den Task-Wert. Der Task
        // ist abgebrochen und darf keine Ereignisse mehr liefern; ein
        // hängender Task darf aber den Composer nicht sperren.
        await waitForTurnStop()

        // E3: den Turn-Zustand hart schließen, **bevor** nachgeladen wird. Das
        // ist idempotent zum `defer` in `run` (gleiche Zuweisungen, kein
        // zweiter Effekt); `merge` und `handle` sind durch die Generation
        // gesperrt.
        isStreaming = false
        turnStartedAt = nil
        statusNote = nil
        streamTask = nil
        cancelResumeWatchdog()

        // E1: kein Erfolgs-Hinweis nach einem verworfenen Turn.
        await reconcileAfterBackground(announcesResume: false)
        // Runde 4 (W4): `reconcileAfterBackground` gibt den Main-Actor ab
        // (`openSession`). In diesem Fenster darf `send()` einen neuen Turn
        // begonnen haben — dann gehören der Verlust-Text und der Wiederholweg
        // **nicht** mehr zu diesem Turn; sie würden dem neuen Turn als fremde
        // Meldung samt „Verlauf neu laden“ vorangestellt. Deshalb nach dem
        // `await` erneut die Generation prüfen. Grenze: im Normalfall ist sie
        // unverändert, dort ändert sich nichts.
        guard generation == turnGeneration else { return }
        guard historyLoaded else {
            // Das Nachladen ist gescheitert: `openSession` hat den genaueren
            // Grund gesetzt, `reconcileAfterBackground` den Wiederholweg. Der
            // ehrliche Verlust-Text ersetzt keine Ursache.
            return
        }
        notice = approvalExpired
            ? Self.backgroundApprovalExpiredNotice
            : Self.backgroundStreamLostNotice
        offerHistoryReload()
    }

    /// E3: wartet höchstens `streamStopWaitLimit` darauf, dass `run` seinen
    /// `defer` erreicht (`isStreaming == false`).
    ///
    /// Grenze: kein Warten auf den Task-Wert (`value`) — das hinge an genau
    /// dem Task, der hängen kann. Geprüft wird in Schritten von
    /// `streamStopPollInterval`, damit der Main-Actor zwischen den Blicken
    /// weiterläuft.
    private func waitForTurnStop() async {
        let limit = max(configuration.streamStopWaitLimit, 0)
        let step = max(configuration.streamStopPollInterval, 0.01)
        let deadline = Date().addingTimeInterval(limit)
        while isStreaming, Date() < deadline {
            do {
                try await Task.sleep(nanoseconds: UInt64(step * 1_000_000_000))
            } catch {
                return
            }
        }
    }

    /// Genau-einmal-Riegel für die Hintergrund-Aufgabe (§3.5.3).
    private func beginBackgroundTaskIfNeeded() {
        guard isStreaming else { return }
        guard backgroundTask == .invalid else { return }
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "chat-turn") {
            // F1: UIKit verlangt `endBackgroundTask(_:)` **vor** der Rückkehr
            // des Handlers. Ein Task-Hop auf den Main-Actor würde die Freigabe
            // erst nach der Rückkehr abarbeiten. Der Handler läuft auf dem
            // Main-Thread, die Klasse ist `@MainActor` — also synchron hier.
            MainActor.assumeIsolated {
                self.endBackgroundTaskIfNeeded()
            }
        }
    }

    /// Beendet die Aufgabe idempotent; danach ist der Platz wieder frei.
    private func endBackgroundTaskIfNeeded() {
        guard backgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTask)
        backgroundTask = .invalid
    }

    // MARK: Disclosure

    /// Öffnet die Denk-Klappe genau einmal je Eintrag, solange noch kein
    /// Antworttext da ist. Danach entscheidet nur noch der Nutzer (Rev 6 O4).
    private func autoExpandReasoning(at index: Int) {
        guard !entries[index].reasoningAutoExpanded, entries[index].text.isEmpty else { return }
        entries[index].reasoningAutoExpanded = true
        entries[index].reasoningDisclosure = .expanded
    }

    /// Toggelt **nur** diesen Eintrag; andere behalten ihren Zustand.
    func toggleReasoning(_ entryID: UUID) {
        guard let index = entries.firstIndex(where: { $0.id == entryID }) else { return }
        entries[index].reasoningDisclosure =
            entries[index].reasoningDisclosure == .collapsed ? .expanded : .collapsed
    }

    /// Toggelt **nur** diese Karte.
    func toggleToolDetail(_ entryID: UUID) {
        guard let index = entries.firstIndex(where: { $0.id == entryID }) else { return }
        entries[index].toolDetailDisclosure =
            entries[index].toolDetailDisclosure == .collapsed ? .expanded : .collapsed
    }

    // MARK: Freigabe

    /// Der vollständige Befehl für den Bestätigungsdialog; `nil`, wenn die ID
    /// nicht existiert, keine Freigabe ist oder keinen Befehl trägt (§4.4).
    ///
    /// Grenze: gibt den Befehl **unverkürzt** zurück — der Dialog muss genau
    /// den Text zeigen, den der Nutzer autorisiert.
    func approvalCommand(for entryID: UUID) -> String? {
        guard let entry = entries.first(where: { $0.id == entryID }),
              entry.kind == .approval,
              let approval = entry.approval
        else { return nil }
        return approval.command
    }

    /// Die Frist in Sekunden — die einzige Stelle, an der sie in die View
    /// gelangt (§4.4). Keine eigene Zahl in der Oberfläche.
    var approvalTimeoutSeconds: Int { Int(configuration.approvalTimeout) }

    /// Beantwortet eine Server-Freigabe. Fail closed: eine nicht angebotene
    /// Choice und jede Freigabe nach Fristablauf werden nie gesendet.
    func decideApproval(_ entryID: UUID, choice: ChatApprovalChoice) async {
        refreshConfiguration()
        guard decidingApprovalEntryID == nil,
              let index = entries.firstIndex(where: { $0.id == entryID }),
              entries[index].kind == .approval,
              let approval = entries[index].approval
        else { return }

        let derivedPhase = ApprovalPhase.derive(
            stored: entries[index].approvalPhase,
            receivedAt: entries[index].approvalReceivedAt,
            timeout: configuration.approvalTimeout,
            now: Date()
        )
        guard derivedPhase.acceptsDecision else { return }

        switch choice {
        case .once:
            guard approval.canApproveOnce else { return }
        case .deny:
            guard approval.canDeny else { return }
        }

        decidingApprovalEntryID = entryID
        defer { decidingApprovalEntryID = nil }
        entries[index].approvalPhase = .sending

        do {
            try await api.respondToApproval(runID: approval.runID, choice: choice)
            guard let current = entries.firstIndex(where: { $0.id == entryID }) else { return }
            entries[current].approvalPhase = choice == .once ? .executed : .denied
            // A3: `once` lässt `toolStatus` auf `.running`, damit die folgende
            // Werkzeugkarte übernimmt. F4: nach erfolgreichem `deny` ist die
            // Freigabe auch für die Karte beendet (Rev-5-Verhalten).
            if choice == .once {
                entries[current].toolStatus = .running
            } else {
                entries[current].toolStatus = .denied
            }
        }
        catch {
            if let current = entries.firstIndex(where: { $0.id == entryID }) {
                if isConflict(error) {
                    // F14: der Server hat bereits entschieden; welche
                    // Entscheidung, sagt nur er — nicht der Client.
                    entries[current].approvalPhase = .conflict
                    notice = "Freigabe nicht mehr aktiv."
                } else {
                    entries[current].approvalPhase = .open
                    notice = displayText(for: error)
                }
            }
        }
    }

    // MARK: Ablauf

    private enum TurnFailure: Error {
        case sessionGone
        case createFailed
    }

    private func run(text: String, generation: Int) async {
        defer {
            // V2: Nur der **aktuelle** Turn schließt seinen Zustand. Ein
            // Zombie-Task eines verworfenen Turns lässt den neuen unberührt.
            if generation == turnGeneration {
                isStreaming = false
                statusNote = nil
                createdSessionThisTurn = false
                turnStartedAt = nil
                // R-CH5: beide Turn-Felder ueberleben den Turn nicht mehr.
                streamRequested = false
                mergeFallbackDuration = nil
                // A1 (Rev 9): kein Watchdog überlebt seinen Turn.
                cancelResumeWatchdog()
            }
        }
        do {
            // V2: ein alter Turn startet keine Serverarbeit mehr. Der Riegel
            // steht vor jedem `await`, weil ein abgebrochener Task aus einem
            // laufenden Request zurückkehren kann.
            guard generation == turnGeneration, abandonedGeneration != generation else { return }
            // O7: erst prüfen, ob der Server das Profil ausliefert — ein 404
            // blockiert den Turn mit einer ehrlichen Meldung (F-R6-4).
            try await api.probeProfile()
            guard generation == turnGeneration, abandonedGeneration != generation else { return }
            let sessionID = try await prepareSession(generation: generation)
            guard generation == turnGeneration, abandonedGeneration != generation else { return }
            try await streamTurn(sessionID: sessionID, text: text, generation: generation)
            // E3 (Rev 9, MARAAA-188): ein Abbruch zwischen letztem Ereignis und
            // Merge darf keinen Merge mehr auslösen — der Watchdog hat den Turn
            // womöglich schon geschlossen und den Serverstand geladen.
            try Task.checkCancellation()
        } catch {
            // E3/V2: Hat der Watchdog **diesen** Turn bereits hart geschlossen
            // oder ist ein neuer Turn gestartet, ist dieser Fehler (der
            // Abbruch) keine Meldung mehr wert — sonst überschriebe
            // „Antwort abgebrochen.“ den ehrlichen Text.
            guard generation == turnGeneration, abandonedGeneration != generation else { return }
            // R1 (Rev 8 §4.4): Ein leerer Strom nach vollständig gelesener
            // Antwort ist kein „nichts gesendet“. Vor der F8-Meldung steht
            // genau ein Nachladeversuch über den vorhandenen Verlaufsweg.
            if !(error is TurnFailure),
               isEmptyStream(error),
               streamRequested,
               !Task.isCancelled,
               currentSession != nil {
                await rescueEmptyTurn()
                return
            }
            handle(error, text: text)
        }
    }

    // MARK: Turn-Rettung (Rev 8 §4.3)

    /// R1: genau **ein** Nachladeversuch über den vorhandenen Verlaufsweg.
    ///
    /// `true` = ein neuer Assistenten-Eintrag wurde gefunden. Grenze: kein
    /// zweiter Antwortstrom, kein `reloadHistory`/`openSession`, keine
    /// Wiederholung; `merge` ist derselbe Weg wie der normale Abschluss und
    /// behält die Live-Werkzeugkarten (Rev 8 §3.2.3, §4.3).
    @discardableResult
    private func rescueEmptyTurn() async -> Bool {
        guard let session = currentSession, !Task.isCancelled else { return false }

        mergeFallbackDuration = measuredTurnDuration()
        let outcome = await merge(sessionID: session.id)
        if case .merged(let agentEntries) = outcome, agentEntries > 0 {
            return true
        }
        // R-CH5: hat der Nutzer waehrend des Rettungs-`GET` abgebrochen, ist
        // das kein leeres Ergebnis. Der Abbruch behaelt seine Meldung
        // („Antwort abgebrochen.“) und bekommt weder F8-Text noch Knopf.
        guard !Task.isCancelled else { return false }

        // Rettung erfolglos: die sichtbare Tatsache ist „keine Antwort“, und
        // der vorhandene Knopf bietet den manuellen Weg an (Rev 8 §6.1/§6.2).
        notice = displayText(for: ChatStreamError.emptyResponse)
        offerHistoryReload()
        return false
    }

    /// Stellt sicher, dass eine Sitzung existiert, die im Verlauf sichtbar ist.
    ///
    /// V2: `generation` schützt die schreibenden Schritte. Ein abgebrochener
    /// Task kann aus `api.session`/`api.createSession` zurückkehren; ohne
    /// Riegel überschriebe er `currentSession` eines neuen Turns.
    private func prepareSession(generation: Int) async throws -> String {
        if let current = currentSession {
            do {
                let fresh = try await api.session(id: current.id)
                try ensureCurrentTurn(generation)
                currentSession = fresh
                return fresh.id
            } catch {
                if isNotFound(error) {
                    try ensureCurrentTurn(generation)
                    currentSession = nil
                    entries = []
                    watermark = nil
                    historyLoaded = false
                    hasMoreOlder = false
                    await loadSessions()
                    throw TurnFailure.sessionGone
                }
                throw error
            }
        }

        do {
            let created = try await api.createSession()
            try ensureCurrentTurn(generation)
            currentSession = created
            // E5/M4: eine neue Session hat keine Historie; die Baseline `0`
            // ist erlaubt, weil dieser Turn sie selbst angelegt hat.
            watermark = 0
            historyLoaded = true
            createdSessionThisTurn = true
            return created.id
        } catch {
            // E2: F1/F2/F22/422/andere 4xx und Abbruch behalten ihre Meldung;
            // nur Transport/Timeout/5xx/Unklassifiziertes wird zu F10.
            if Self.isCreateFailure(error) {
                throw TurnFailure.createFailed
            }
            throw error
        }
    }

    /// V2: wirft `CancellationError`, wenn `generation` nicht mehr der
    /// aktuelle Turn ist (oder der Watchdog ihn geschlossen hat).
    private func ensureCurrentTurn(_ generation: Int) throws {
        guard generation == turnGeneration, abandonedGeneration != generation else {
            throw CancellationError()
        }
    }

    /// E2: F10 ist der letzte Fall, kein Sammelbecken.
    private static func isCreateFailure(_ error: Error) -> Bool {
        if error is CancellationError { return false }
        if error is HermesChatConfigurationError { return false }
        guard let apiError = error as? APIError else { return true }
        switch apiError {
        case .timeout, .offline:
            return true
        case .server(let status, _, _, _):
            return status >= 500
        case .unauthorized, .forbidden, .notFound, .conflict,
             .rateLimited, .cancelled, .emptyResponse, .hermesLoginFailed,
             .hermesAuthenticationRequired, .hermesAPIServerKeyRequired,
             .methodNotAllowed:
            // Eine abgelehnte Hermes-Anmeldung behält ihre eigene Meldung und
            // wird nicht als „Sitzung nicht anlegbar“ umgeschrieben. Ein 405
            // behält den Hinweis auf Dashboard/API-Server, weil genau er die
            // Ursache benennt (falsche Basis-URL). Ein 401 des API-Servers
            // nennt den fehlenden `API_SERVER_KEY` und bleibt darum ebenfalls
            // unverändert.
            return false
        case .validation:
            // F9: 400 `invalid_title` wird wie F10 abgebrochen (gleicher Text);
            // die App sendet keinen Titel, der Fall bleibt defensiv.
            return true
        case .invalidConfiguration, .invalidRequest, .invalidResponse, .decoding:
            return true
        }
    }

    private func streamTurn(sessionID: String, text: String, generation: Int) async throws {
        var pendingEngine: ChatEngine?
        var agentEntryID: UUID?
        var didFinish = false
        // H1: die Antwort-ID kann von der gesendeten abweichen.
        var effectiveSessionID = sessionID
        defer {
            // spec-chat-live-activity §5.1/2: der Abgleich gehört zum Turn,
            // nicht zur Karte. Nach dem Turn — auch nach einem Abbruch —
            // läuft keine Anfrage weiter.
            liveActivityTask?.cancel()
            liveActivityTask = nil
            // V2: ein später alter Turn beendet nicht das Vorlesen des neuen.
            if generation == turnGeneration { voice?.finishAssistantStream() }
        }

        // R1: ab hier hat der Server die Anfrage erhalten; nur dann darf ein
        // Nachladen des Verlaufs erwogen werden (Rev 8 §3.2.1).
        // V2: ein alter Turn öffnet keinen Strom mehr und setzt den Merker des
        // neuen nicht.
        guard generation == turnGeneration, abandonedGeneration != generation else { return }
        streamRequested = true
        for try await event in provider.stream(sessionID: sessionID, userText: text) {
            // V2: ein Ereignis aus einem nicht mehr aktuellen Turn darf den
            // neuen nicht füttern (Lebenszeichen, Einträge, Merge).
            guard generation == turnGeneration, abandonedGeneration != generation else { return }
            // A1 (Rev 9, MARAAA-188): jedes Ereignis ist ein Lebenszeichen —
            // der Watchdog nach der Rückkehr zählt darauf.
            streamEventCount += 1
            // H2: erst ein tatsächlich empfangenes Ereignis beweist, dass der
            // Strom läuft. Ein Fehler davor rollt den Entwurf zurück (§4.8).
            streamStarted = true
            try Task.checkCancellation()
            switch event {
            case .sessionID(let responseID):
                receivedSessionHeader = true
                effectiveSessionID = responseID
                adoptSessionID(responseID)

            case .engine(let engine):
                pendingEngine = engine
                if let index = index(of: agentEntryID) {
                    entries[index].engine = engine
                }

            case .reasoningDelta(let delta):
                let id = ensureAgentEntry(&agentEntryID, engine: pendingEngine)
                guard let index = index(of: id) else { break }
                autoExpandReasoning(at: index)
                let combined = (entries[index].reasoning ?? "") + delta
                entries[index].reasoning = boundedText(
                    combined,
                    limit: configuration.maxReasoningCharacters
                )
                if combined.count > configuration.maxReasoningCharacters,
                   !didWarnReasoningTruncated {
                    didWarnReasoningTruncated = true
                    notice = "Denken wurde gekürzt."
                }

            case .textDelta(let delta):
                let id = ensureAgentEntry(&agentEntryID, engine: pendingEngine)
                guard let index = index(of: id) else { break }
                entries[index].text += delta
                // N2: nur Agent-Text erreicht den Satzpuffer — nie Reasoning.
                voice?.ingestAssistantDelta(delta)

            case .toolProgress(let progress):
                apply(progress)
                // §5.2: der Abgleich startet mit dem **ersten** Werkzeug-Frame.
                // Vorher gibt es nichts zu holen, und die Wartezeit auf das
                // Modell soll nicht mit Anfragen belegt werden.
                startLiveActivitySync(sessionID: effectiveSessionID, generation: generation)

            case .status(let note):
                statusNote = note

            case .approval(let approval):
                apply(approval)

            case .finished(let finish):
                didFinish = true
                apply(finish)
            }
        }

        // F15: Der Server hat keine Antwort-ID geliefert, und es gab noch keinen
        // Verlauf, der fortgesetzt werden könnte. Ein F12-Fehler hat Vorrang;
        // der Merge-Hinweis darf diese Warnung nicht überschreiben.
        // V2: nach dem Ende des Stroms gilt derselbe Riegel — ein alter Turn
        // schreibt weder Hinweis noch Merge in den neuen.
        guard generation == turnGeneration, abandonedGeneration != generation else { return }
        if !receivedSessionHeader, turnHistoryWasEmpty, notice == nil {
            notice = "Der Verlauf wird nicht fortgesetzt (Sitzungs-Header fehlt)."
        }

        // R2: die lokale Messung festhalten, **bevor** der Merge die
        // Live-Einträge ersetzt. Sie ist der Notbeleg ohne Server-Zeitstempel
        // und trägt den Live-Eintrag auch dann, wenn der Merge nichts Neues
        // findet (Rev 8 §4.5).
        let measured = measuredTurnDuration()
        attachLiveDuration(measured)
        mergeFallbackDuration = measured

        if didFinish {
            // V2: der Merge gehört zu genau diesem Turn. Die Generation hat
            // `merge` beim Eintritt festgehalten und prüft sie nach dem
            // `await` erneut; hier steht der billige Riegel davor.
            guard generation == turnGeneration, abandonedGeneration != generation else {
                return
            }
            switch await merge(sessionID: effectiveSessionID) {
            case .nothingNew:
                // F12: eine bereits gesetzte Fehlermeldung hat Vorrang.
                if notice == nil {
                    notice = "Antwort nicht im Verlauf gespeichert."
                }
            case .failed:
                notice = "Der Verlauf konnte nicht geladen werden."
            case .skipped, .merged:
                break
            }
        }
    }

    /// Übernimmt eine abweichende Antwort-ID in `currentSession` (§4.4/7).
    private func adoptSessionID(_ responseID: String) {
        guard let session = currentSession, session.id != responseID else { return }
        currentSession = SessionSummary(
            id: responseID,
            title: session.title,
            preview: session.preview,
            messageCount: session.messageCount,
            toolCallCount: session.toolCallCount,
            lastActive: session.lastActive,
            pinned: session.pinned,
            archived: session.archived,
            source: session.source
        )
    }

    private func ensureAgentEntry(_ id: inout UUID?, engine: ChatEngine?) -> UUID {
        if let id, index(of: id) != nil {
            return id
        }
        let entry = Entry(kind: .agent, text: "", engine: engine)
        entries.append(entry)
        turnEntryIDs.insert(entry.id)
        id = entry.id
        return entry.id
    }

    private func index(of entryID: UUID?) -> Int? {
        guard let entryID else { return nil }
        return entries.firstIndex(where: { $0.id == entryID })
    }

    // MARK: Ereignisse anwenden

    private func apply(_ progress: ChatToolProgress) {
        let status: ToolCallStatus = progress.status == .running ? .running : .completed

        if let index = entries.firstIndex(where: {
            $0.kind == .tool && $0.toolCallID == progress.toolCallID
        }) {
            if let label = progress.label, !label.isEmpty {
                entries[index].toolName = label
            }
            // E4: `completed` trägt kein Emoji und löscht den vorhandenen Wert nicht.
            if progress.status == .running,
               let emoji = progress.emoji, !emoji.isEmpty {
                entries[index].toolEmoji = emoji
            }
            entries[index].toolStatus = status
            return
        }

        let entry = Entry(
            kind: .tool,
            text: "",
            toolCallID: progress.toolCallID,
            toolName: progress.label ?? progress.tool,
            toolEmoji: progress.status == .running ? progress.emoji : nil,
            toolStatus: status
        )
        entries.append(entry)
        turnEntryIDs.insert(entry.id)
    }

    // MARK: Live-Verlaufsabgleich (spec-chat-live-activity §5.1)

    /// `true`, solange eine Werkzeugkarte des **laufenden** Turns läuft.
    ///
    /// Grenze: nur Karten dieses Turns (`turnEntryIDs`); eine Karte aus einem
    /// früheren Turn darf den Abgleich nicht wach halten (F1).
    private var hasRunningToolCard: Bool {
        entries.contains {
            turnEntryIDs.contains($0.id) && $0.kind == .tool && $0.toolStatus == .running
        }
    }

    /// Startet den Abgleich, wenn dieser Turn noch keinen hat.
    ///
    /// Grenze: höchstens einmal je Turn; ohne bekannte Sitzung oder ohne
    /// Wasserstand startet er nicht (§5.3/2, §5.3/3). Vor dem ersten
    /// Werkzeug-Frame wird er nicht aufgerufen (§5.2).
    private func startLiveActivitySync(sessionID: String, generation: Int) {
        guard liveActivityTask == nil else { return }
        guard watermark != nil || createdSessionThisTurn else { return }
        liveActivityTask = Task {
            await self.liveActivitySync(sessionID: sessionID, generation: generation)
        }
    }

    /// Holt den Verlauf, solange ein Werkzeug des Turns läuft, und füllt die
    /// Karten daraus.
    ///
    /// Grenze: eine Leseanfrage je Takt **und nur während eines Werkzeuglaufs**;
    /// nach dem letzten Werkzeug genau eine Abschlussrunde, danach keine
    /// Anfrage mehr bis zum nächsten laufenden Werkzeug (F1, §5.2). Ein lokaler
    /// Cursor verhindert, dass dieselben Zeilen in jeder Runde erneut
    /// übernommen werden; der `watermark` des Abschluss-Merges bleibt
    /// unangetastet. Kein Schreiben, kein zweiter Merge.
    private func liveActivitySync(sessionID: String, generation: Int) async {
        var consecutiveFailures = 0
        var polls = 0
        // F1: lokaler Cursor — höchste in dieser Schleife gesehene ID.
        var cursor = watermark ?? -1
        // F1: die Abschlussrunde holt das Ergebnis des zuletzt beendeten
        // Werkzeugs. Sie ist ab dem Start offen: der Abgleich beginnt mit
        // einem Werkzeug-Frame, und ein sehr kurzer Lauf darf sein Ergebnis
        // nicht verlieren, wenn das Ende vor der ersten Runde eintrifft.
        var finalRoundPending = true

        while polls < configuration.liveActivityMaxPolls {
            if Task.isCancelled { return }
            guard generation == turnGeneration,
                  abandonedGeneration != generation,
                  isStreaming
            else { return }
            // Kein Zahlenliteral: der Takt steht in der Konfiguration (§5.2).
            guard (try? await Task.sleep(for: .seconds(configuration.liveActivityPollInterval))) != nil
            else { return }
            if Task.isCancelled { return }
            guard generation == turnGeneration,
                  abandonedGeneration != generation,
                  isStreaming
            else { return }

            // F1: erst nach dem Takt entscheiden, ob es etwas zu holen gibt.
            // Ohne laufendes Werkzeug (und ohne offene Abschlussrunde) keine
            // Anfrage — die Wartezeit auf das Modell bleibt lastfrei.
            let running = hasRunningToolCard
            if running {
                finalRoundPending = true
            } else if finalRoundPending {
                // Abschlussrunde: das Ergebnis der letzten Werkzeugzeile steht
                // erst nach dem Ende des Werkzeugs im Verlauf.
                finalRoundPending = false
            } else {
                continue
            }

            polls += 1
            do {
                let page = try await api.messages(
                    sessionID: sessionID,
                    limit: configuration.liveActivityPageSize,
                    offset: 0,
                    order: .latest
                )
                consecutiveFailures = 0
                // Nach dem `await` kann der Turn vorbei sein; dann darf das
                // späte Ergebnis keinen Zustand mehr anfassen.
                guard generation == turnGeneration,
                      abandonedGeneration != generation
                else { return }
                // Cursor vor dem Anwenden lesen: die Grenze ist der Stand der
                // letzten Runde, nicht der dieser.
                let fresh = page.messages
                    .filter { $0.id > cursor }
                    .sorted { $0.id < $1.id }
                if let newest = page.messages.map(\.id).max() {
                    cursor = max(cursor, newest)
                }
                applyHistoryDelta(fresh)
            } catch {
                if error is CancellationError { return }
                consecutiveFailures += 1
                if consecutiveFailures >= configuration.liveActivityMaxConsecutiveFailures {
                    return
                }
            }
        }
    }

    /// Füllt vorhandene Werkzeugkarten aus einer Verlaufsseite (§5.1/1).
    ///
    /// Grenze: **nur** Werkzeugzeilen. Agent-Text, Freigaben und der Merge
    /// bleiben unangetastet; der Aufklappzustand ist Nutzerentscheidung und
    /// wird hier nie gesetzt. Karten werden über `toolCallID` gefunden und nur
    /// angelegt, wenn der Live-Strom sie noch nicht gemeldet hat.
    private func applyHistoryDelta(_ messages: [ChatMessage]) {
        guard !messages.isEmpty else { return }

        // Ergebnisse zuerst sammeln: eine `tool`-Zeile steht in der Seite
        // hinter ihrer Assistentenzeile, die Karte entsteht aber davor.
        var results: [String: String] = [:]
        for message in messages where message.role == "tool" {
            guard message.displayKind != "hidden", let callID = message.toolCallID else { continue }
            results[callID] = message.content.map {
                boundedText($0, limit: configuration.maxToolDetailCharacters)
            }
        }

        for message in messages where message.role == "assistant" {
            guard message.displayKind != "hidden" else { continue }
            for call in message.toolCalls ?? [] {
                guard let callID = call.id else { continue }
                let arguments = call.function?.arguments.map {
                    boundedText($0, limit: configuration.maxToolDetailCharacters)
                }
                let result = results[callID]

                if let index = entries.firstIndex(where: {
                    $0.kind == .tool && $0.toolCallID == callID
                }) {
                    // Der Live-Name aus `label` ist genauer als der Rohname.
                    if (entries[index].toolName ?? "").isEmpty,
                       let name = call.function?.name, !name.isEmpty {
                        entries[index].toolName = name
                    }
                    if entries[index].toolArgs == nil {
                        entries[index].toolArgs = arguments
                    }
                    if let result {
                        entries[index].toolResult = result
                        entries[index].toolStatus = .completed
                    } else {
                        // Nie einen bereits abgeschlossenen Status zurückdrehen.
                        let isOpen = entries[index].toolStatus == nil
                            || entries[index].toolStatus == .running
                        if isOpen { entries[index].toolStatus = .running }
                    }
                    continue
                }

                let entry = Entry(
                    kind: .tool,
                    text: "",
                    toolCallID: callID,
                    toolName: call.function?.name,
                    toolArgs: arguments,
                    toolResult: result,
                    toolStatus: result == nil ? .running : .completed
                )
                entries.append(entry)
                turnEntryIDs.insert(entry.id)
            }
        }
    }

    private func apply(_ approval: ChatApproval) {
        var entry = Entry(
            kind: .approval,
            text: approval.description ?? "",
            toolStatus: .awaitingApproval,
            approval: approval
        )
        entry.approvalPhase = .open
        entry.approvalReceivedAt = Date()
        entry.approvalToolName = lastToolNameInTurn()
        entry.approvalCommandTooLong =
            (approval.command ?? "").count > configuration.maxCommandCharacters
        entries.append(entry)
        turnEntryIDs.insert(entry.id)
    }

    /// Name der letzten benannten Werkzeugkarte dieses Turns; `nil`, wenn es
    /// keine gibt (`approval.request` trägt kein Werkzeugfeld).
    private func lastToolNameInTurn() -> String? {
        entries.last(where: {
            turnEntryIDs.contains($0.id)
                && $0.kind == .tool
                && !($0.toolName ?? "").isEmpty
        })?.toolName
    }

    private func apply(_ finish: ChatFinish) {
        switch finish.reason {
        case "length":
            notice = "Antwort wurde gekürzt."
        case "error":
            let detail = finish.errorMessage.map { " " + $0 } ?? ""
            notice = boundedText(
                "Hermes meldet einen Fehler." + detail,
                limit: configuration.maxNoticeCharacters
            )
        default:
            break
        }
    }

    // MARK: Merge nach einem Turn (§5.5)

    /// Ergebnis eines Verlaufs-Nachladens (Rev 8 §4.1).
    ///
    /// `merge` setzt selbst keine `notice` mehr — der Aufrufer entscheidet den
    /// Text. Deshalb kann der Rettungspfad denselben Weg benutzen, ohne dessen
    /// Meldungen zu erben.
    private enum MergeOutcome: Equatable {
        /// Der watermark-Riegel (§5.5 Rev 5) hat den Lauf verhindert.
        case skipped
        /// Der Verlaufs-GET hat geworfen.
        case failed
        /// Kein Eintrag über dem watermark.
        case nothingNew
        /// `agentEntries` = in diesem Lauf angelegte Agent-Einträge.
        case merged(agentEntries: Int)
    }

    @discardableResult
    private func merge(sessionID: String) async -> MergeOutcome {
        // E3/V2 (Rev 9, MARAAA-188): Ein vom Watchdog verworfener Turn merged
        // nicht mehr. Sein Serverstand ist bereits über
        // `reconcileAfterBackground` geladen; ein spätes Ergebnis — oder eine
        // späte Fehlermeldung aus `catch` — würde ihn überschreiben.
        //
        // Die Generation wird hier beim Eintritt festgehalten: der Aufruf
        // erfolgt auf dem Main-Actor ohne `await` davor, also noch im Turn, den
        // der Aufrufer geprüft hat. Ein alter Task kann damit nie die Nummer
        // eines inzwischen gestarteten Turns erben.
        let generation = turnGeneration
        guard abandonedGeneration != generation else { return .skipped }
        // E5/M4: Ein Merge mit `watermark == nil` ist nur für eine in genau
        // diesem Turn angelegte Session zulässig. Der Fall „openSession
        // fehlgeschlagen, dann gesendet“ ist durch `canSend` gesperrt; dieser
        // Riegel ist die zweite, billige Sicherung.
        guard watermark != nil || createdSessionThisTurn else { return .skipped }

        // R2, Rang 2: die lokale Messung des laufenden Turns. Der Aufrufer hat
        // sie unmittelbar davor gesetzt (Rev 8 §4.5).
        let fallbackDuration = mergeFallbackDuration

        do {
            let page = try await api.messages(
                sessionID: sessionID,
                limit: configuration.messagePageSize,
                offset: 0,
                order: .latest
            )
            // V2: nach dem `await` kann der Watchdog diesen Turn geschlossen
            // oder ein neuer Turn begonnen haben. Dann darf das späte Ergebnis
            // weder Einträge noch `watermark` des neuen Turns überschreiben.
            guard generation == turnGeneration, abandonedGeneration != generation else {
                return .skipped
            }
            // R2, Rang 1: aus der **ganzen** Seite, weil die zugehörige
            // User-Nachricht vor dem `watermark` liegen kann (Rev 8 §4.2).
            let durations = Self.generationDurations(in: page.messages)
            let fresh = page.messages
                .filter { $0.id > (watermark ?? -1) }
                .sorted { $0.id < $1.id }

            guard !fresh.isEmpty else { return .nothingNew }

            let expandedToolIDs = Set(
                entries.filter { $0.toolDetailDisclosure == .expanded }
                    .compactMap(\.toolCallID)
            )

            // N1.3/F1: der Auf-/Zu-Zustand der Denk-Klappe des laufenden Turns
            // wird vor dem Entfernen festgehalten und nach dem Neuaufbau
            // übertragen — sonst schließt sie am Turn-Ende ohne Nutzeraktion.
            let carriedReasoningDisclosure = turnReasoningDisclosure()

            // Nur Agent- und Freigabe-Einträge des Turns weichen dem
            // Serverstand; Werkzeugkarten behalten ihre Live-Identität.
            entries.removeAll { entry in
                turnEntryIDs.contains(entry.id) && (entry.kind == .agent || entry.kind == .approval)
            }

            let rebuiltStart = entries.count
            var consumedOptimisticUser = false
            for message in fresh {
                switch message.role {
                case "user":
                    applyMergedUser(message, consumed: &consumedOptimisticUser)
                case "assistant":
                    if let index = applyMergedAssistant(message) {
                        entries[index].generationDuration = durations[message.id] ?? fallbackDuration
                    }
                case "tool":
                    applyMergedTool(message)
                default:
                    continue
                }
            }

            carryReasoningDisclosure(carriedReasoningDisclosure, onto: rebuiltStart)

            // Der Turn ist zu Ende; ein noch laufender Status wäre gelogen.
            for index in entries.indices where entries[index].kind == .tool {
                if entries[index].toolStatus == .running {
                    entries[index].toolStatus = .completed
                }
                if let toolCallID = entries[index].toolCallID,
                   expandedToolIDs.contains(toolCallID) {
                    entries[index].toolDetailDisclosure = .expanded
                }
            }

            if let last = fresh.last {
                watermark = last.id
            }
            turnEntryIDs = []
            createdSessionThisTurn = false

            let agentEntries = entries[rebuiltStart...].filter { $0.kind == .agent }.count

            await loadSessions()
            syncCurrentSessionWithList()
            return .merged(agentEntries: agentEntries)
        } catch {
            return .failed
        }
    }

    private func applyMergedUser(_ message: ChatMessage, consumed: inout Bool) {
        guard let content = message.content, !content.isEmpty else { return }
        let text = boundedText(content, limit: configuration.maxTextCharacters)

        if !consumed, let optimisticID = optimisticUserEntryID,
           let index = entries.firstIndex(where: { $0.id == optimisticID }) {
            entries[index].text = text
            optimisticUserEntryID = nil
            consumed = true
            return
        }
        entries.append(Entry(kind: .user, text: text))
    }

    /// Baut den Agent-Eintrag einer gespeicherten Assistenten-Nachricht und
    /// gibt dessen Index zurück; `nil` = kein Agent-Eintrag erzeugt.
    ///
    /// Grenze: die Dauer setzt der Aufrufer (`merge`/`map`), weil sie aus der
    /// ganzen Nachrichtenseite kommt und nicht aus dieser einen Nachricht
    /// (Rev 8 §4.6). Werkzeugkarten erhalten nie eine Dauer.
    @discardableResult
    private func applyMergedAssistant(_ message: ChatMessage) -> Int? {
        let reasoningText = Self.reasoning(of: message, limit: configuration.maxReasoningCharacters)
        var agentIndex: Int?

        if let content = message.content, !content.isEmpty {
            entries.append(
                Entry(
                    kind: .agent,
                    text: boundedText(content, limit: configuration.maxTextCharacters),
                    reasoning: reasoningText,
                    engine: .hermes
                )
            )
            agentIndex = entries.count - 1
        } else if message.toolCalls?.isEmpty ?? true,
                  let reasoningText, !reasoningText.isEmpty {
            entries.append(
                Entry(kind: .agent, text: "", reasoning: reasoningText, engine: .hermes)
            )
            agentIndex = entries.count - 1
        }

        for call in message.toolCalls ?? [] {
            let arguments = call.function?.arguments.map {
                boundedText($0, limit: configuration.maxToolDetailCharacters)
            }
            let callID = call.id

            if let callID,
               let index = entries.firstIndex(where: {
                   $0.kind == .tool && $0.toolCallID == callID
               }) {
                if let name = call.function?.name, !name.isEmpty {
                    entries[index].toolName = name
                }
                entries[index].toolArgs = arguments
                entries[index].toolStatus = .completed
                continue
            }

            entries.append(
                Entry(
                    kind: .tool,
                    text: "",
                    toolCallID: callID,
                    toolName: call.function?.name,
                    toolArgs: arguments,
                    toolStatus: .completed
                )
            )
        }

        return agentIndex
    }

    private func applyMergedTool(_ message: ChatMessage) {
        let result = message.content.map {
            boundedText($0, limit: configuration.maxToolDetailCharacters)
        }

        if let callID = message.toolCallID,
           let index = entries.firstIndex(where: {
               $0.kind == .tool && $0.toolCallID == callID
           }) {
            entries[index].toolResult = result
            entries[index].toolStatus = .completed
            return
        }

        entries.append(
            Entry(
                kind: .tool,
                text: "",
                toolCallID: message.toolCallID,
                toolName: message.toolName ?? "Werkzeug",
                toolResult: result,
                toolStatus: .completed
            )
        )
    }

    /// N1.3/F1: Hält den Auf-/Zu-Zustand der Denk-Klappe des Agent-Eintrags
    /// dieses Turns fest, bevor `merge` ihn durch den Serverstand ersetzt.
    ///
    /// Grenze: nur Einträge dieses Turns (`turnEntryIDs`) und nur solche mit
    /// Denken. `nil` heißt „kein Live-Agent-Eintrag“ — der neu aufgebaute
    /// Eintrag bleibt dann bei seinem Default `.collapsed`.
    private func turnReasoningDisclosure() -> Entry.Disclosure? {
        entries.last(where: {
            turnEntryIDs.contains($0.id) && $0.kind == .agent && $0.reasoning != nil
        })?.reasoningDisclosure
    }

    /// N1.3/F1: Trägt den festgehaltenen Zustand auf den zuletzt aus dem
    /// Serververlauf aufgebauten Agent-Eintrag mit Denken (`entries[start...]`).
    /// `reasoningAutoExpanded` wird bewusst **nicht** gesetzt: die Automatik
    /// öffnet oder schließt diesen Eintrag nicht wieder, die Nutzerentscheidung
    /// bleibt erhalten.
    private func carryReasoningDisclosure(_ disclosure: Entry.Disclosure?, onto start: Int) {
        guard let disclosure, start < entries.count else { return }
        guard let index = entries[start...].lastIndex(where: {
            $0.kind == .agent && $0.reasoning != nil
        }) else { return }
        entries[index].reasoningDisclosure = disclosure
    }

    private func syncCurrentSessionWithList() {
        guard let id = currentSession?.id else { return }
        if let fresh = sessions.first(where: { $0.id == id }) {
            currentSession = fresh
        }
    }

    // MARK: Mapping gespeicherter Nachrichten (§5.4)

    /// Bildet geladene Nachrichten auf Einträge ab — ohne UI, damit testbar.
    static func map(messages: [ChatMessage], engine: ChatEngine = .hermes) -> [Entry] {
        let configuration = HermesChatConfiguration()
        // R2, Rang 1: jede geladene Antwort trägt ihre Dauer aus den
        // Server-Zeitstempeln; ohne Zeitstempel bleibt das Feld `nil`.
        let durations = generationDurations(in: messages)
        var result: [Entry] = []

        for message in messages {
            if message.role == "system" { continue }
            if message.displayKind == "hidden" { continue }

            switch message.role {
            case "user":
                guard let content = message.content, !content.isEmpty else { continue }
                result.append(
                    Entry(
                        kind: .user,
                        text: bounded(content, limit: configuration.maxTextCharacters)
                    )
                )

            case "assistant":
                let reasoningText = reasoning(of: message, limit: configuration.maxReasoningCharacters)
                if let content = message.content, !content.isEmpty {
                    result.append(
                        Entry(
                            kind: .agent,
                            text: bounded(content, limit: configuration.maxTextCharacters),
                            reasoning: reasoningText,
                            engine: engine,
                            generationDuration: durations[message.id]
                        )
                    )
                } else if message.toolCalls?.isEmpty ?? true,
                          let reasoningText, !reasoningText.isEmpty {
                    result.append(
                        Entry(
                            kind: .agent,
                            text: "",
                            reasoning: reasoningText,
                            engine: engine,
                            generationDuration: durations[message.id]
                        )
                    )
                }

                for call in message.toolCalls ?? [] {
                    result.append(
                        Entry(
                            kind: .tool,
                            text: "",
                            toolCallID: call.id,
                            toolName: call.function?.name,
                            toolArgs: call.function?.arguments.map {
                                bounded($0, limit: configuration.maxToolDetailCharacters)
                            },
                            toolStatus: .completed
                        )
                    )
                }

            case "tool":
                let content = message.content.map {
                    bounded($0, limit: configuration.maxToolDetailCharacters)
                }
                if let callID = message.toolCallID,
                   let index = result.lastIndex(where: {
                       $0.kind == .tool && $0.toolCallID == callID
                   }) {
                    result[index].toolResult = content
                    result[index].toolStatus = .completed
                } else {
                    result.append(
                        Entry(
                            kind: .tool,
                            text: "",
                            toolCallID: message.toolCallID,
                            toolName: message.toolName ?? "Werkzeug",
                            toolResult: content,
                            toolStatus: .completed
                        )
                    )
                }

            default:
                continue
            }
        }
        return result
    }

    private static func reasoning(of message: ChatMessage, limit: Int) -> String? {
        guard let raw = message.reasoningContent ?? message.reasoning, !raw.isEmpty else {
            return nil
        }
        return bounded(raw, limit: limit)
    }

    /// Kürzt an der Grenze und benennt die Kürzung — die View kürzt nicht.
    private static func bounded(_ text: String, limit: Int) -> String {
        guard text.count > limit else { return text }
        return String(text.prefix(limit)) + "\n… (gekürzt)"
    }

    // MARK: Dauer der Antwort (Rev 8)

    /// R2, Rang 2: lokale Messung von Sende- bis Abschlusszeitpunkt.
    ///
    /// `nil` ohne laufenden Turn (`turnStartedAt`). Grenze: keine Schätzung —
    /// ohne Startzeit gibt es keinen Wert (Rev 8 §3.3.2).
    private func measuredTurnDuration() -> TimeInterval? {
        guard let startedAt = turnStartedAt else { return nil }
        return Date().timeIntervalSince(startedAt)
    }

    /// R2, Rang 2 am Live-Eintrag: setzt die lokale Messung an den letzten
    /// Agent-Eintrag **dieses** Turns mit Text, sofern dort noch nichts steht.
    ///
    /// Grenze: nur Einträge dieses Turns (`turnEntryIDs`), nur Agent-Einträge,
    /// nur mit Text und nur ohne vorhandenen Wert — Einträge früherer Turns und
    /// aus dem Serververlauf bleiben unberührt (Rev 8 §4.5).
    private func attachLiveDuration(_ duration: TimeInterval?) {
        guard let duration else { return }
        guard let index = entries.lastIndex(where: {
            turnEntryIDs.contains($0.id)
                && $0.kind == .agent
                && !$0.text.isEmpty
                && $0.generationDuration == nil
        }) else { return }
        entries[index].generationDuration = duration
    }

    /// R2, Rang 1: Assistenten-ID → Dauer aus den Server-Zeitstempeln.
    ///
    /// Dauer = Zeitstempel der Assistenten-Nachricht minus Zeitstempel der
    /// letzten vorangehenden User-Nachricht derselben Liste. Grenze: reine
    /// Funktion, kein Zustand, kein HTTP — die **einzige** Stelle, die
    /// `ChatMessage.timestamp` interpretiert (Rev 8 §4.8).
    static func generationDurations(in messages: [ChatMessage]) -> [Int: TimeInterval] {
        let maximum = HermesChatConfiguration().maxVisibleGenerationDuration
        var lastUser: Double?
        var result: [Int: TimeInterval] = [:]

        for message in messages.sorted(by: { $0.id < $1.id }) {
            switch message.role {
            case "user":
                // Auch `nil` setzt zurück: ohne User-Zeitstempel gibt es keinen
                // Bezugspunkt für die folgende Antwort.
                lastUser = message.timestamp

            case "assistant":
                guard let timestamp = message.timestamp,
                      let userTimestamp = lastUser,
                      timestamp > userTimestamp
                else { continue }
                let duration = timestamp - userTimestamp
                // R5: eine unplausible Einheit ist kein Datenpunkt.
                if duration <= maximum {
                    result[message.id] = duration
                }

            default:
                continue
            }
        }
        return result
    }

    /// R2, Anzeige: `nil` = keine Zeile (unbekannt oder unter der Mindestdauer).
    ///
    /// Grenze: reine Weiterleitung; die Schwelle kommt aus der Konfiguration,
    /// die Formatierung aus `durationText(seconds:minimum:)`.
    func durationText(for entry: Entry) -> String? {
        guard let duration = entry.generationDuration else { return nil }
        return Self.durationText(
            seconds: duration,
            minimum: configuration.minVisibleGenerationDuration
        )
    }

    /// R2, reiner Formatierer (Rev 8 §3.3.3/§3.3.4). Kein `Entry`, keine View,
    /// kein `Date`, keine `Locale` — die einzige Stelle, an der eine Dauer in
    /// Text übergeht.
    static func durationText(seconds: TimeInterval, minimum: TimeInterval) -> String? {
        guard seconds.isFinite else { return nil }
        // R-CH5: die Umrechnung nach `Int` trappt oberhalb des `Int`-Bereichs
        // (z. B. 1e30); eine so grosse Dauer ist keine Anzeige.
        guard seconds <= TimeInterval(Int.max) else { return nil }
        // Abgerundet auf ganze Sekunden: 59.9 s darf nicht „1 min 0 s“ werden.
        let total = Int(floor(seconds))
        guard total >= 0, TimeInterval(total) >= minimum else { return nil }

        if total < 60 {
            return "\(total) s"
        }
        if total < 3_600 {
            return "\(total / 60) min \(total % 60) s"
        }
        return "\(total / 3_600) h \((total % 3_600) / 60) min"
    }

    // MARK: Fehler

    private func handle(_ error: Error, text: String) {
        if let failure = error as? TurnFailure {
            // Vor dem Strom: nichts wurde gesendet, der Entwurf kehrt zurück.
            rollbackUserEntry(text: text)
            switch failure {
            case .sessionGone:
                notice = "Die Unterhaltung existiert nicht mehr."
            case .createFailed:
                notice = "Die Unterhaltung konnte nicht angelegt werden — nichts gesendet."
            }
            return
        }

        if isCancellation(error) {
            // E2/F7: ein Abbruch vor dem ersten Ereignis ist „nichts gesendet“ —
            // der Entwurf kehrt zurück. Während des Stroms bleibt der Teilstand.
            if !streamStarted {
                rollbackUserEntry(text: text)
            }
            notice = "Antwort abgebrochen."
            return
        }

        // F-R6-1: Ein Timeout mitten im Strom ist kein stiller Erfolg. Der
        // Teiltext bleibt stehen, kein Rollback, kein Merge; die Meldung nennt
        // die eingestellte Schwelle und den Anschluss über den Verlauf (O3).
        if streamStarted, isTimeout(error) {
            offerHistoryReload()
            notice = boundedText(
                "Seit \(Int(configuration.streamIdleTimeout)) s keine Antwort. Der Turn kann auf dem Server weiterlaufen — „Verlauf neu laden“ holt ihn.",
                limit: configuration.maxNoticeCharacters
            )
            return
        }

        if !streamStarted {
            rollbackUserEntry(text: text)
        }
        notice = displayText(for: error)
    }

    private func rollbackUserEntry(text: String) {
        if let optimisticID = optimisticUserEntryID,
           let index = entries.firstIndex(where: { $0.id == optimisticID }) {
            entries.remove(at: index)
        }
        optimisticUserEntryID = nil
        turnEntryIDs = []
        draft = text
    }

    /// Übersetzt einen Fehler in einen anzeigbaren Satz — ohne Header, Tokens
    /// oder URLs. Unbekannte Fehler werden bewusst nicht roh ausgegeben.
    private func displayText(for error: Error) -> String {
        let message: String
        if let apiError = error as? APIError {
            message = Self.describe(apiError)
        } else if let streamError = error as? ChatStreamError {
            if case .http(let apiError) = streamError {
                message = Self.describe(apiError)
            } else {
                message = streamError.errorDescription ?? "Stream-Fehler."
            }
        } else if let urlError = error as? URLError {
            // M2: der Strom-Client kann mitten im Strom werfen; daraus
            // darf nie „Unbekannter Fehler.“ werden.
            message = Self.describe(urlError)
        } else if let localized = (error as? LocalizedError)?.errorDescription {
            message = localized
        } else {
            message = "Unbekannter Fehler."
        }
        return boundedText(message, limit: configuration.maxNoticeCharacters)
    }

    /// F6: Timeout/Offline/Abbruch aus `URLError` mit den festgelegten Texten.
    private static func describe(_ error: URLError) -> String {
        switch error.code {
        case .cancelled:
            return "Antwort abgebrochen."
        case .timedOut:
            return APIError.timeout.errorDescription ?? "Zeitüberschreitung — Dienst nicht erreichbar."
        case .notConnectedToInternet, .networkConnectionLost, .cannotConnectToHost,
             .cannotFindHost, .dnsLookupFailed:
            return APIError.offline.errorDescription ?? "Keine Netzwerkverbindung."
        default:
            return "Die Verbindung zu Hermes wurde unterbrochen."
        }
    }

    private static func describe(_ error: APIError) -> String {
        switch error {
        case .hermesAPIServerKeyRequired:
            // Der API-Server kennt keinen Password-Login; hier ist der
            // API-Schlüssel die Ursache, nicht Benutzername/Passwort.
            return error.errorDescription
                ?? "Hermes-API-Server: API-Schlüssel fehlt oder ist ungültig (API_SERVER_KEY)."
        case .unauthorized, .hermesLoginFailed:
            // Hermes meldet sich seit MARAAA-146 mit Benutzername/Passwort an.
            return "Hermes verweigert den Zugriff. Bitte Benutzername und Passwort in den Einstellungen prüfen."
        case .hermesAuthenticationRequired:
            // Ein 3xx ist ein Auth-Signal, kein roher HTTP-Status (MARAAA-154).
            return error.errorDescription ?? "Hermes-Anmeldung erforderlich — Benutzername/Passwort prüfen."
        case .forbidden:
            return "Zugriff verweigert (403). Der Server erlaubt keine Sitzungs-Fortsetzung."
        case .notFound:
            return "Die Unterhaltung existiert nicht mehr."
        case .rateLimited(let retryAfter):
            if let retryAfter, retryAfter > 0 {
                return "Zu viele Anfragen — in \(Int(retryAfter.rounded(.up))) s erneut versuchen."
            }
            return "Zu viele Anfragen — bitte später erneut versuchen."
        case .offline, .timeout:
            return error.errorDescription ?? "Keine Verbindung zu Hermes."
        case .server(let status, _, let message, _) where status < 500:
            // 422/andere 4xx: der Servertext ist die Meldung (E2), kein F10.
            return message
        default:
            return error.errorDescription ?? "Netzwerkfehler."
        }
    }

    private func isCancellation(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        if let apiError = error as? APIError, apiError == .cancelled { return true }
        if let streamError = error as? ChatStreamError, streamError == .cancelled { return true }
        return false
    }

    /// B2 (Rev 8 §3.2.1): ein leerer Strom nach **vollständig gelesener**
    /// HTTP-Antwort. Beide Fehler entstehen erst danach — ein Transportfehler,
    /// ein Abbruch oder ein Timeout ist ausdrücklich **kein** leerer Strom.
    private func isEmptyStream(_ error: Error) -> Bool {
        if let streamError = error as? ChatStreamError, streamError == .emptyResponse {
            return true
        }
        if let apiError = error as? APIError, apiError == .emptyResponse {
            return true
        }
        return false
    }

    /// Ein Timeout kann als `APIError.timeout`, als `ChatStreamError.http(.timeout)`
    /// oder als roher `URLError.timedOut` aus dem Strom kommen (F6/F-R6-1).
    private func isTimeout(_ error: Error) -> Bool {
        if let apiError = error as? APIError, apiError == .timeout { return true }
        if let streamError = error as? ChatStreamError, streamError == .http(.timeout) {
            return true
        }
        if let urlError = error as? URLError, urlError.code == .timedOut { return true }
        return false
    }

    private func isNotFound(_ error: Error) -> Bool {
        if let apiError = error as? APIError, apiError == .notFound { return true }
        return false
    }

    private func isUnreachable(_ error: Error) -> Bool {
        guard let apiError = error as? APIError else { return false }
        return apiError == .offline || apiError == .timeout
    }

    private func isConflict(_ error: Error) -> Bool {
        guard let apiError = error as? APIError else { return false }
        if case .conflict = apiError { return true }
        return false
    }

    private func boundedText(_ text: String, limit: Int) -> String {
        guard text.count > limit else { return text }
        return String(text.prefix(limit))
    }
}
