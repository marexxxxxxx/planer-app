//
//  ChatViewModel.swift
//  Planer
//
//  Zustand und Ablauf des Chat-Tabs: Sitzungen, Verlauf, Antwortstrom,
//  Denken, Werkzeugkarten und Freigabe (spec-chat Rev 4 §4, §5.3, §5.5).
//

import Combine
import Foundation

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
        var engine: ChatEngine?

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
        /// `true`, sobald der POST beantwortet wurde.
        var approvalResolved: Bool

        init(
            id: UUID = UUID(),
            kind: Kind,
            text: String,
            reasoning: String? = nil,
            reasoningDisclosure: Disclosure = .collapsed,
            engine: ChatEngine? = nil,
            toolCallID: String? = nil,
            toolName: String? = nil,
            toolEmoji: String? = nil,
            toolArgs: String? = nil,
            toolResult: String? = nil,
            toolStatus: ToolCallStatus? = nil,
            toolDetailDisclosure: Disclosure = .collapsed,
            approval: ChatApproval? = nil,
            approvalResolved: Bool = false
        ) {
            self.id = id
            self.kind = kind
            self.text = text
            self.reasoning = reasoning
            self.reasoningDisclosure = reasoningDisclosure
            self.engine = engine
            self.toolCallID = toolCallID
            self.toolName = toolName
            self.toolEmoji = toolEmoji
            self.toolArgs = toolArgs
            self.toolResult = toolResult
            self.toolStatus = toolStatus
            self.toolDetailDisclosure = toolDetailDisclosure
            self.approval = approval
            self.approvalResolved = approvalResolved
        }
    }

    // MARK: Zustand

    @Published private(set) var sessions: [SessionSummary] = []
    @Published private(set) var currentSession: SessionSummary?
    @Published private(set) var entries: [Entry] = []
    @Published private(set) var isLoadingSessions = false
    @Published private(set) var isLoadingHistory = false
    @Published private(set) var isStreaming = false
    @Published private(set) var notice: String?
    @Published private(set) var statusNote: ChatStatusNote?
    @Published var draft = ""
    @Published private(set) var hasMoreOlder = false
    /// Befund 14: „Mehr laden“ ist erlaubt, solange noch keine leere Seite kam.
    @Published private(set) var loadedAllSessions = false
    /// Der Freigabe-Eintrag, dessen POST gerade läuft (Chips sind dann inaktiv).
    @Published private(set) var decidingApprovalEntryID: UUID?

    /// Die Sprachschicht (V3, §9.6). `ChatView` setzt sie nach dem Erzeugen des
    /// Modells — ein `@StateObject` erlaubt keinen Environment-Zugriff im
    /// Initializer.
    ///
    /// `nil` heißt: kein Vorlesen und kein Diktat — der Chat funktioniert
    /// unverändert.
    var voice: (any VoiceAssistant)?

    private let api: HermesChatAPI
    private let provider: any ChatStreamProvider
    private let configuration: HermesChatConfiguration

    private var streamTask: Task<Void, Never>?
    /// Höchste bereits dargestellte Nachrichten-ID; `0` ist die Baseline einer
    /// geladenen, aber leeren Session (E5) — nie eine echte Server-ID.
    private var watermark: Int?
    private var optimisticUserEntryID: UUID?
    /// Während des Stroms angelegte Agent-/Werkzeug-/Freigabe-Einträge.
    private var turnEntryIDs: Set<UUID> = []
    /// `true`, sobald der Strom tatsächlich ein Ereignis geliefert hat. Davor
    /// gilt ein Fehler als „nichts gesendet“ (§4.8/F10).
    private var streamStarted = false
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

    init(
        api: HermesChatAPI = HermesChatAPI(),
        provider: any ChatStreamProvider = HermesChatStreamProvider()
    ) {
        self.api = api
        self.provider = provider
        self.configuration = HermesChatConfiguration()
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

    // MARK: Verlauf

    /// Lädt die erste Seite der Sitzungsliste. Der Server filtert bereits nach
    /// dem Source-Tag; die App verwirft fremde Einträge zusätzlich defensiv.
    func loadSessions() async {
        guard !isLoadingSessions else { return }
        isLoadingSessions = true
        defer { isLoadingSessions = false }

        do {
            let page = try await api.listSessions(
                limit: configuration.sessionPageSize,
                offset: 0
            )
            sessions = page.sessions.filter { $0.source == configuration.sessionSource }
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
                $0.source == configuration.sessionSource && !known.contains($0.id)
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
    }

    // MARK: Senden

    /// Startet das Senden der aktuellen Eingabe.
    ///
    /// Grenze: leere Eingaben, laufende Turns und ein halb geladener Verlauf
    /// werden ignoriert; zu lange Eingaben werden mit Hinweis abgelehnt, nicht
    /// abgeschnitten.
    func send() {
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
        createdSessionThisTurn = false
        receivedSessionHeader = false
        turnHistoryWasEmpty = watermark == nil || watermark == 0
        // Ein Hinweis „Denken wurde gekürzt.“ gilt je Turn, nicht je Chat.
        didWarnReasoningTruncated = false

        isStreaming = true
        streamTask = Task { await run(text: text) }
    }

    /// Bricht die laufende Antwort ab. Ein Abbruch ist kein Fehler und kein
    /// Erfolg: kein Merge, kein Server-Aufruf.
    func cancel() {
        voice?.stopSpeaking()
        streamTask?.cancel()
        streamTask = nil
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
    }

    // MARK: Disclosure

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

    /// Beantwortet eine Server-Freigabe. Fail closed: eine nicht angebotene
    /// Choice wird nie gesendet.
    func decideApproval(_ entryID: UUID, choice: ChatApprovalChoice) async {
        guard decidingApprovalEntryID == nil,
              let index = entries.firstIndex(where: { $0.id == entryID }),
              entries[index].kind == .approval,
              !entries[index].approvalResolved,
              let approval = entries[index].approval
        else { return }

        switch choice {
        case .once:
            guard approval.canApproveOnce else { return }
        case .deny:
            guard approval.canDeny else { return }
        }

        decidingApprovalEntryID = entryID
        defer { decidingApprovalEntryID = nil }

        do {
            try await api.respondToApproval(runID: approval.runID, choice: choice)
            guard let current = entries.firstIndex(where: { $0.id == entryID }) else { return }
            entries[current].approvalResolved = true
            entries[current].toolStatus = choice == .once ? .running : .denied
        } catch {
            guard let current = entries.firstIndex(where: { $0.id == entryID }) else { return }
            if isConflict(error) {
                // F14: der Server hat bereits entschieden; der Strom läuft weiter.
                entries[current].approvalResolved = true
                entries[current].toolStatus = .denied
                notice = "Freigabe nicht mehr aktiv."
            } else {
                notice = displayText(for: error)
            }
        }
    }

    // MARK: Ablauf

    private enum TurnFailure: Error {
        case sessionGone
        case createFailed
    }

    private func run(text: String) async {
        defer {
            isStreaming = false
            statusNote = nil
            createdSessionThisTurn = false
        }
        do {
            let sessionID = try await prepareSession()
            try await streamTurn(sessionID: sessionID, text: text)
        } catch {
            handle(error, text: text)
        }
    }

    /// Stellt sicher, dass eine Sitzung existiert, die im Verlauf sichtbar ist.
    private func prepareSession() async throws -> String {
        if let current = currentSession {
            do {
                let fresh = try await api.session(id: current.id)
                currentSession = fresh
                return fresh.id
            } catch {
                if isNotFound(error) {
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
             .hermesAuthenticationRequired:
            // Eine abgelehnte Hermes-Anmeldung behält ihre eigene Meldung und
            // wird nicht als „Sitzung nicht anlegbar“ umgeschrieben.
            return false
        case .validation:
            // F9: 400 `invalid_title` wird wie F10 abgebrochen (gleicher Text);
            // die App sendet keinen Titel, der Fall bleibt defensiv.
            return true
        case .invalidConfiguration, .invalidRequest, .invalidResponse, .decoding:
            return true
        }
    }

    private func streamTurn(sessionID: String, text: String) async throws {
        var pendingEngine: ChatEngine?
        var agentEntryID: UUID?
        var didFinish = false
        // H1: die Antwort-ID kann von der gesendeten abweichen.
        var effectiveSessionID = sessionID
        defer { voice?.finishAssistantStream() }

        for try await event in provider.stream(sessionID: sessionID, userText: text) {
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
        if !receivedSessionHeader, turnHistoryWasEmpty, notice == nil {
            notice = "Der Verlauf wird nicht fortgesetzt (Sitzungs-Header fehlt)."
        }

        if didFinish {
            await merge(sessionID: effectiveSessionID)
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

    private func apply(_ approval: ChatApproval) {
        let entry = Entry(
            kind: .approval,
            text: approval.description ?? "",
            toolStatus: .awaitingApproval,
            approval: approval,
            approvalResolved: false
        )
        entries.append(entry)
        turnEntryIDs.insert(entry.id)
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

    private func merge(sessionID: String) async {
        // E5/M4: Ein Merge mit `watermark == nil` ist nur für eine in genau
        // diesem Turn angelegte Session zulässig. Der Fall „openSession
        // fehlgeschlagen, dann gesendet“ ist durch `canSend` gesperrt; dieser
        // Riegel ist die zweite, billige Sicherung.
        guard watermark != nil || createdSessionThisTurn else { return }

        do {
            let page = try await api.messages(
                sessionID: sessionID,
                limit: configuration.messagePageSize,
                offset: 0,
                order: .latest
            )
            let fresh = page.messages
                .filter { $0.id > (watermark ?? -1) }
                .sorted { $0.id < $1.id }

            guard !fresh.isEmpty else {
                // F12: eine bereits gesetzte Fehlermeldung hat Vorrang.
                if notice == nil {
                    notice = "Antwort nicht im Verlauf gespeichert."
                }
                return
            }

            let expandedToolIDs = Set(
                entries.filter { $0.toolDetailDisclosure == .expanded }
                    .compactMap(\.toolCallID)
            )

            // Nur Agent- und Freigabe-Einträge des Turns weichen dem
            // Serverstand; Werkzeugkarten behalten ihre Live-Identität.
            entries.removeAll { entry in
                turnEntryIDs.contains(entry.id) && (entry.kind == .agent || entry.kind == .approval)
            }

            var consumedOptimisticUser = false
            for message in fresh {
                switch message.role {
                case "user":
                    applyMergedUser(message, consumed: &consumedOptimisticUser)
                case "assistant":
                    applyMergedAssistant(message)
                case "tool":
                    applyMergedTool(message)
                default:
                    continue
                }
            }

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

            await loadSessions()
            syncCurrentSessionWithList()
        } catch {
            notice = "Der Verlauf konnte nicht geladen werden."
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

    private func applyMergedAssistant(_ message: ChatMessage) {
        let reasoningText = Self.reasoning(of: message, limit: configuration.maxReasoningCharacters)

        if let content = message.content, !content.isEmpty {
            entries.append(
                Entry(
                    kind: .agent,
                    text: boundedText(content, limit: configuration.maxTextCharacters),
                    reasoning: reasoningText,
                    engine: .hermes
                )
            )
        } else if message.toolCalls?.isEmpty ?? true,
                  let reasoningText, !reasoningText.isEmpty {
            entries.append(
                Entry(kind: .agent, text: "", reasoning: reasoningText, engine: .hermes)
            )
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
                            engine: engine
                        )
                    )
                } else if message.toolCalls?.isEmpty ?? true,
                          let reasoningText, !reasoningText.isEmpty {
                    result.append(
                        Entry(kind: .agent, text: "", reasoning: reasoningText, engine: engine)
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
            // M2: `URLSession.AsyncBytes` kann mitten im Strom werfen; daraus
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
