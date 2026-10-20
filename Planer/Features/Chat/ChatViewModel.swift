//
//  ChatViewModel.swift
//  Planer
//
//  Zustand und Ablauf des Chat-Tabs: MCP-Session, Werkzeugkatalog,
//  Antwortstrom, Werkzeugausführung (spec-ios §9.1, §10).
//

import Combine
import Foundation

/// Führt den Chat: verbindet den MCP-Client, streamt die Antwort und führt
/// angeforderte Werkzeuge über `tools/call` aus.
///
/// Zweck: die Oberfläche bleibt dumm (`ChatView` rendert nur `entries`); alle
/// Zustandsübergänge — Verbindung, Ablauf, Abbruch, Freigabe, Fehler — passieren
/// hier.
/// Grenze: kein HTTP und keine Header (das macht `MCPClient`) und kein
/// Streaming-Dialekt (das macht `ChatStreamProvider`). **Werkzeugaufrufe sind
/// default-deny:** ohne `readOnlyHint` entsteht eine `ToolCallConfirmation`,
/// die als `pendingToolCall` wartet, bis `approveToolCall` oder
/// `declineToolCall` kommt (Action-Chips). Die Klasse ist `@MainActor`, weil sie
/// direkt SwiftUI-Zustand hält.
@MainActor
final class ChatViewModel: ObservableObject {

    /// Verbindungszustand für die Statuszeile.
    enum Connection: Equatable {
        case idle
        case connecting
        case ready(protocolVersion: String?)
        case failed(String)
    }

    /// Eine Zeile im Verlauf.
    struct Entry: Identifiable, Equatable {
        enum Kind: Equatable {
            case user
            case agent
            case tool
        }

        let id: UUID
        var kind: Kind
        var text: String
        /// Nur bei `kind == .tool`.
        var toolName: String?
        /// Nur bei `kind == .tool`.
        var toolStatus: ToolCallBadge.Status?
        /// Nur bei `kind == .tool`: der Aufruf wartet auf die Action-Chips.
        var awaitsConfirmation: Bool
        /// Nur bei `kind == .agent`: woher die Antwort stammt (§7, N7).
        var engine: ChatEngine?

        init(
            id: UUID = UUID(),
            kind: Kind,
            text: String,
            toolName: String? = nil,
            toolStatus: ToolCallBadge.Status? = nil,
            awaitsConfirmation: Bool = false,
            engine: ChatEngine? = nil
        ) {
            self.id = id
            self.kind = kind
            self.text = text
            self.toolName = toolName
            self.toolStatus = toolStatus
            self.awaitsConfirmation = awaitsConfirmation
            self.engine = engine
        }
    }

    /// Harte Grenzen gegen unbegrenzte Läufe und unbegrenzte Texte.
    private enum Limits {
        /// So viele Werkzeugrunden innerhalb einer Nutzernachricht.
        static let maxToolRounds = 3
        static let maxDraftCharacters = 4_000
        static let maxNoticeCharacters = 300
        static let maxToolDetailCharacters = 600
        static let maxToolResultCharacters = 2_000
    }

    @Published private(set) var entries: [Entry] = []
    @Published private(set) var isStreaming = false
    @Published private(set) var connection: Connection = .idle
    @Published private(set) var notice: String?
    @Published private(set) var toolCount = 0
    @Published var draft = ""

    /// Der Werkzeugaufruf, auf dessen Freigabe der Lauf gerade wartet.
    ///
    /// `nil` heißt: kein Chip offen, kein Aufruf blockiert. Gesetzt wird der
    /// Wert ausschließlich in `waitForDecision(on:)`, geleert in jeder Auflösung
    /// (Freigabe, Ablehnung, Abbruch, Trennen, Verlauf löschen) — ein Chip kann
    /// sich damit nie auf einen anderen als den angezeigten Aufruf beziehen.
    @Published private(set) var pendingToolCall: ToolCallConfirmation?

    /// Die Sprachschicht (V3, §6). `ChatView` setzt sie nach dem Erzeugen des
    /// Modells — ein `@StateObject` erlaubt keinen Environment-Zugriff im
    /// Initializer (N1).
    ///
    /// `nil` heißt: kein Vorlesen und kein Diktat — der Chat funktioniert
    /// unverändert.
    var voice: (any VoiceAssistant)?

    private let mcpClient: MCPClient
    private let provider: ChatStreamProvider
    private var tools: [MCPTool] = []
    private var turns: [ChatTurn] = []
    private var streamTask: Task<Void, Never>?
    /// Offene Action-Chips je Werkzeug-Eintrag. Der Lauf wartet hier, bis der
    /// Nutzer freigibt oder ablehnt — ohne Antwort wird nichts gesendet.
    private var pendingConfirmations: [UUID: CheckedContinuation<Bool, Never>] = [:]

    /// Der Anbieter ist injizierbar: ein anderer Streaming-Dialekt ist ein
    /// anderer `ChatStreamProvider`, keine Änderung an dieser Klasse.
    init(
        mcpClient: MCPClient = MCPClient(),
        provider: ChatStreamProvider = OpenAICompatibleChatStreamProvider()
    ) {
        self.mcpClient = mcpClient
        self.provider = provider
    }

    // MARK: Abgeleiteter Zustand

    var canSend: Bool {
        !isStreaming && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var statusText: String {
        switch connection {
        case .idle:
            return "Nicht verbunden"
        case .connecting:
            return "Verbinde …"
        case .ready:
            return toolCount > 0 ? "Verbunden · \(toolCount) Werkzeuge" : "Verbunden"
        case .failed(let message):
            return "Nicht erreichbar: \(boundedText(message, limit: 80))"
        }
    }

    var isConnected: Bool {
        if case .ready = connection { return true }
        return false
    }

    // MARK: Verbindung

    /// Baut die MCP-Sitzung auf (`initialize`) und lädt den Werkzeugkatalog.
    /// Idempotent: eine bestehende Verbindung wird nicht erneut aufgebaut.
    func connect() async {
        guard !isStreaming, !isConnected else { return }
        notice = nil
        do {
            try await ensureConnected()
        } catch {
            // `ensureConnected` hat den Fehlerzustand bereits gesetzt.
        }
    }

    /// Beendet die Sitzung (HTTP-`DELETE` mit `Mcp-Session-Id`) und bricht einen
    /// laufenden Strom ab. Der lokale Zustand zeigt danach „nicht verbunden“.
    func disconnect() {
        resolvePendingConfirmations(approved: false, text: "Verbindung getrennt — nicht ausgeführt.")
        voice?.stopSpeaking()
        streamTask?.cancel()
        streamTask = nil
        if isConnected {
            connection = .idle
        }
        Task { await mcpClient.disconnect() }
    }

    // MARK: Senden

    /// Startet das Senden der aktuellen Eingabe.
    ///
    /// Grenze: leere Eingaben und parallele Sendungen werden ignoriert; zu lange
    /// Eingaben werden mit Hinweis abgelehnt, nicht abgeschnitten.
    func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isStreaming else { return }
        guard text.count <= Limits.maxDraftCharacters else {
            notice = "Die Nachricht ist länger als \(Limits.maxDraftCharacters) Zeichen."
            return
        }

        draft = ""
        notice = nil
        // N4: der Nutzer sendet — laufendes Vorlesen endet sofort.
        voice?.stopSpeaking()
        entries.append(Entry(kind: .user, text: text))
        turns.append(ChatTurn(role: .user, content: text))
        streamTask = Task { await run() }
    }

    /// Übernimmt ein diktiertes Ergebnis in den Entwurf (N6, §6).
    ///
    /// Der Text landet mit einem Leerzeichen getrennt in `draft` — genau dort,
    /// wo getippter Text auch landet. **Gesendet wird nicht**: das bleibt
    /// Sache von `send()`.
    func appendDictation(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        let combined = draft.isEmpty ? trimmed : draft + " " + trimmed
        if combined.count > Limits.maxDraftCharacters {
            draft = String(combined.prefix(Limits.maxDraftCharacters))
            notice = "Der Entwurf wurde auf \(Limits.maxDraftCharacters) Zeichen gekürzt."
        } else {
            draft = combined
        }
    }

    /// Bricht die laufende Antwort ab (spec-ios §10: jeder lange Vorgang ist
    /// abbrechbar). Ein Abbruch ist kein Fehler und kein Erfolg.
    func cancel() {
        resolvePendingConfirmations(approved: false, text: "Abgebrochen — nicht ausgeführt.")
        voice?.stopSpeaking()
        streamTask?.cancel()
    }

    func dismissNotice() {
        notice = nil
    }

    // MARK: Werkzeug-Freigabe

    /// Gibt einen wartenden Werkzeugaufruf frei (Action-Chip „Ausführen“).
    ///
    /// Grenze: wirkt nur auf einen Eintrag, der tatsächlich wartet; ein zweiter
    /// Tipp hat keine Wirkung und löst keinen zweiten Aufruf aus.
    func approveToolCall(_ entryID: UUID) {
        guard pendingToolCall?.id == entryID,
              let continuation = pendingConfirmations.removeValue(forKey: entryID)
        else { return }
        pendingToolCall = nil
        if let index = entries.firstIndex(where: { $0.id == entryID }) {
            entries[index].awaitsConfirmation = false
            entries[index].toolStatus = .running
            entries[index].text = ""
        }
        continuation.resume(returning: true)
    }

    /// Lehnt einen wartenden Werkzeugaufruf ab (Action-Chip „Ablehnen“).
    ///
    /// Der Aufruf erreicht den Server nie; das Modell erhält stattdessen einen
    /// Werkzeug-Turn mit der Ablehnung, damit es nicht stillschweigend von einer
    /// Ausführung ausgeht.
    func declineToolCall(_ entryID: UUID) {
        guard pendingToolCall?.id == entryID,
              let continuation = pendingConfirmations.removeValue(forKey: entryID)
        else { return }
        pendingToolCall = nil
        markDeclined(entryID, text: "Vom Nutzer abgelehnt — nicht ausgeführt.")
        continuation.resume(returning: false)
    }

    /// Löscht Verlauf und Historie; die Verbindung bleibt bestehen.
    func clear() {
        resolvePendingConfirmations(approved: false, text: "Verlauf gelöscht — nicht ausgeführt.")
        voice?.stopSpeaking()
        streamTask?.cancel()
        streamTask = nil
        entries.removeAll()
        turns.removeAll()
        notice = nil
        draft = ""
    }

    // MARK: Ablauf

    private struct StreamOutcome {
        let assistantText: String
        let toolRequests: [ToolCallRequest]
        let badgeIDs: [Int: UUID]
    }

    private func run() async {
        isStreaming = true
        defer { isStreaming = false }

        do {
            try await ensureConnected()

            var rounds = 0
            while true {
                try Task.checkCancellation()
                let outcome = try await streamOnce()

                if !outcome.assistantText.isEmpty {
                    turns.append(ChatTurn(role: .assistant, content: outcome.assistantText))
                }
                // N3: die Runde ist durch — der Restpuffer wird zur letzten
                // Äußerung, damit der Schluss einer Antwort nicht verschluckt wird.
                voice?.finishAssistantStream()
                guard !outcome.toolRequests.isEmpty else { break }
                guard rounds < Limits.maxToolRounds else {
                    // Teilstand melden statt weiterzulaufen oder Erfolg zu behaupten.
                    notice = "Werkzeug-Aufrufe nach \(Limits.maxToolRounds) Runden gestoppt."
                    break
                }
                rounds += 1

                for request in outcome.toolRequests {
                    try Task.checkCancellation()
                    let badgeID = outcome.badgeIDs[request.index]
                        ?? appendConfirmationEntry(for: request)

                    // Default deny: ohne ausdrückliche `readOnlyHint` wartet der
                    // Aufruf auf die Action-Chips. Erst „Ausführen“ sendet.
                    // `ToolCallPolicy` entscheidet, `ToolCallConfirmation` hält
                    // die Entscheidung samt wartendem Aufruf.
                    let confirmation = ToolCallConfirmation(
                        id: badgeID,
                        pendingToolCall: request,
                        requiresConfirmation: ToolCallPolicy.requiresConfirmation(for: tool(named: request.name))
                    )
                    if confirmation.requiresConfirmation {
                        setAwaitingConfirmation(badgeID)
                        let approved = await waitForDecision(on: confirmation)
                        try Task.checkCancellation()
                        guard approved else {
                            recordDecline(request, badgeID: badgeID)
                            continue
                        }
                    }

                    await execute(request, badgeID: badgeID)
                }
            }
        } catch {
            handle(error)
        }
    }

    private func ensureConnected() async throws {
        if isConnected { return }
        connection = .connecting
        do {
            try await mcpClient.connectIfNeeded()
            let session = await mcpClient.currentSession()
            connection = .ready(protocolVersion: session.negotiatedVersion)
            await refreshTools()
        } catch {
            connection = .failed(displayText(for: error))
            throw error
        }
    }

    private func refreshTools() async {
        do {
            let catalog = try await mcpClient.listTools()
            tools = catalog.tools
            toolCount = catalog.tools.count
            if catalog.truncated {
                notice = "Die Werkzeugliste wurde auf \(catalog.tools.count) Einträge gekürzt."
            }
        } catch {
            // Ohne Werkzeuge bleibt Text-Chat möglich — aber der Ausfall wird
            // benannt, nicht als leerer Katalog ausgegeben.
            tools = []
            toolCount = 0
            notice = "Werkzeuge nicht ladbar: \(displayText(for: error))"
        }
    }

    /// Eine Antwortrunde: Text streamen, Werkzeuganforderungen einsammeln.
    private func streamOnce() async throws -> StreamOutcome {
        var assistantText = ""
        var assistantEngine: ChatEngine?
        var agentEntryID: UUID?
        var toolRequests: [ToolCallRequest] = []
        var badgeIDs: [Int: UUID] = [:]

        for try await event in provider.stream(messages: turns, tools: tools) {
            try Task.checkCancellation()
            switch event {
            case .textDelta(let delta):
                assistantText += delta
                if let id = agentEntryID,
                   let index = entries.firstIndex(where: { $0.id == id }) {
                    entries[index].text += delta
                } else {
                    let entry = Entry(kind: .agent, text: delta, engine: assistantEngine)
                    agentEntryID = entry.id
                    entries.append(entry)
                }
                // N2: nur Agent-Text erreicht den Satzpuffer — nie Nutzertext.
                voice?.ingestAssistantDelta(delta)

            case .engine(let engine):
                // N7: setzt `Entry.engine` und damit die Herkunft am Eintrag
                // (§7). Der Anbieter schickt das Ereignis vor dem ersten Delta.
                assistantEngine = engine
                if let id = agentEntryID,
                   let index = entries.firstIndex(where: { $0.id == id }) {
                    entries[index].engine = engine
                }

            case .toolCallStarted(let index, let name):
                let entry = Entry(kind: .tool, text: "", toolName: name, toolStatus: .running)
                badgeIDs[index] = entry.id
                entries.append(entry)

            case .toolCallFinished(let request):
                toolRequests.append(request)

            case .finished:
                break
            }
        }

        return StreamOutcome(
            assistantText: assistantText,
            toolRequests: toolRequests,
            badgeIDs: badgeIDs
        )
    }

    // MARK: Freigabe-Hilfen

    private func tool(named name: String) -> MCPTool? {
        tools.first { $0.name == name }
    }

    /// Legt einen Eintrag an, falls der Anbieter kein `toolCallStarted` geliefert
    /// hat. Die Freigabe braucht immer eine sichtbare Zeile mit Chips.
    private func appendConfirmationEntry(for request: ToolCallRequest) -> UUID {
        let entry = Entry(
            kind: .tool,
            text: "",
            toolName: request.name,
            toolStatus: .awaitingConfirmation,
            awaitsConfirmation: true
        )
        entries.append(entry)
        return entry.id
    }

    private func setAwaitingConfirmation(_ entryID: UUID) {
        guard let index = entries.firstIndex(where: { $0.id == entryID }) else { return }
        entries[index].awaitsConfirmation = true
        entries[index].toolStatus = .awaitingConfirmation
        entries[index].text = ""
    }

    /// Hält den Lauf an, bis der Nutzer einen Chip tippt oder der Lauf endet.
    ///
    /// Setzt `pendingToolCall` für die Dauer des Wartens: der angezeigte Chip
    /// und der blockierte Aufruf sind damit derselbe Wert. Endet das Warten ohne
    /// Entscheidung (Abbruch, Trennen), räumt `resolvePendingConfirmations` den
    /// Wert ab.
    private func waitForDecision(on confirmation: ToolCallConfirmation) async -> Bool {
        let entryID = confirmation.id
        pendingToolCall = confirmation
        let approved: Bool = await withCheckedContinuation { continuation in
            pendingConfirmations[entryID] = continuation
        }
        pendingToolCall = nil
        return approved
    }

    /// Löst alle offenen Chips auf (Abbruch, Trennen, Verlauf löschen), damit
    /// kein Aufruf ohne Antwort hängen bleibt.
    private func resolvePendingConfirmations(approved: Bool, text: String) {
        let pending = pendingConfirmations
        pendingConfirmations.removeAll()
        pendingToolCall = nil
        for (entryID, continuation) in pending {
            if !approved {
                markDeclined(entryID, text: text)
            }
            continuation.resume(returning: approved)
        }
    }

    private func markDeclined(_ entryID: UUID, text: String) {
        guard let index = entries.firstIndex(where: { $0.id == entryID }) else { return }
        entries[index].awaitsConfirmation = false
        entries[index].toolStatus = .declined
        entries[index].text = text
    }

    /// Meldet die Ablehnung als Werkzeug-Ergebnis an das Modell — nicht als
    /// Erfolg und nicht als Fehler des Servers.
    private func recordDecline(_ request: ToolCallRequest, badgeID: UUID?) {
        let text = "Vom Nutzer abgelehnt — nicht ausgeführt."
        if let badgeID {
            markDeclined(badgeID, text: text)
        }
        turns.append(
            ChatTurn(
                role: .tool,
                content: text,
                toolCallID: request.id,
                toolName: request.name
            )
        )
    }

    /// Führt einen angeforderten Werkzeugaufruf aus (`tools/call`).
    ///
    /// **Schreibende Werkzeuge erreichen diese Stelle nie ohne Freigabe.** Der
    /// einzige Aufrufer ist die Schleife in `run()`, und die prüft vorher
    /// `ToolCallConfirmation.requiresConfirmation`: ist es `true`, wartet sie in
    /// `waitForDecision(on:)` auf `approveToolCall`. Bei `declineToolCall`,
    /// Abbruch, Trennen oder „Verlauf löschen“ wird der Aufruf verworfen und
    /// `recordDecline` an das Modell gemeldet — der Server sieht ihn nicht.
    /// Automatisch laufen nur Aufrufe, deren Werkzeug der Server ausdrücklich
    /// mit `readOnlyHint: true` als lesend deklariert hat.
    ///
    /// Grenze: ein Fehler wird als Werkzeug-Ergebnis an das Modell und als
    /// Badge an die Oberfläche gegeben — kein Absturz, kein stiller Erfolg.
    private func execute(_ request: ToolCallRequest, badgeID: UUID?) async {
        do {
            let arguments = try parseArguments(request.argumentsJSON)
            let result = try await mcpClient.callTool(name: request.name, arguments: arguments)
            let text = result.text.isEmpty ? "(kein Text)" : result.text

            updateBadge(
                badgeID,
                status: result.isError ? .failed : .succeeded,
                text: boundedText(text, limit: Limits.maxToolDetailCharacters)
            )
            turns.append(
                ChatTurn(
                    role: .tool,
                    content: boundedText(text, limit: Limits.maxToolResultCharacters),
                    toolCallID: request.id,
                    toolName: request.name
                )
            )
            if result.isError {
                notice = "Werkzeug \(request.name) meldet einen Fehler."
            }
        } catch {
            let text = displayText(for: error)
            updateBadge(badgeID, status: .failed, text: text)
            turns.append(
                ChatTurn(
                    role: .tool,
                    content: "Fehler: \(text)",
                    toolCallID: request.id,
                    toolName: request.name
                )
            )
            if let mcpError = error as? MCPError, mcpError == .sessionExpired {
                connection = .idle
            }
        }
    }

    private func updateBadge(_ id: UUID?, status: ToolCallBadge.Status, text: String) {
        guard let id, let index = entries.firstIndex(where: { $0.id == id }) else { return }
        entries[index].toolStatus = status
        entries[index].text = text
    }

    private func parseArguments(_ raw: String) throws -> JSONValue {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let payload = trimmed.isEmpty ? "{}" : trimmed
        guard let data = payload.data(using: .utf8),
              let value = try? JSONDecoder().decode(JSONValue.self, from: data),
              value.objectValue != nil
        else {
            throw ChatStreamError.invalidArguments("Argumente sind kein JSON-Objekt.")
        }
        return value
    }

    // MARK: Fehler

    private func handle(_ error: Error) {
        if isCancellation(error) {
            notice = "Antwort abgebrochen."
            return
        }
        if let mcpError = error as? MCPError, mcpError == .sessionExpired {
            connection = .idle
            notice = "Die MCP-Sitzung ist abgelaufen. Bitte erneut senden."
            return
        }
        notice = displayText(for: error)
    }

    /// Übersetzt einen Fehler in einen anzeigbaren Satz — ohne Header, Tokens
    /// oder URLs. Unbekannte Fehler werden bewusst nicht roh ausgegeben.
    private func displayText(for error: Error) -> String {
        let message: String
        if let apiError = error as? APIError {
            message = Self.describe(apiError)
        } else if let mcpError = error as? MCPError {
            message = mcpError.errorDescription ?? "MCP-Fehler."
        } else if let streamError = error as? ChatStreamError {
            message = streamError.errorDescription ?? "Stream-Fehler."
        } else if let localized = (error as? LocalizedError)?.errorDescription {
            message = localized
        } else {
            message = "Unbekannter Fehler."
        }
        return boundedText(message, limit: Limits.maxNoticeCharacters)
    }

    private static func describe(_ error: APIError) -> String {
        if case .rateLimited(let retryAfter) = error, let retryAfter, retryAfter > 0 {
            return "Zu viele Anfragen — in \(Int(retryAfter.rounded(.up))) s erneut versuchen."
        }
        return error.errorDescription ?? "Netzwerkfehler."
    }

    private func isCancellation(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        if let apiError = error as? APIError, apiError == .cancelled { return true }
        if let mcpError = error as? MCPError, mcpError == .cancelled { return true }
        if let streamError = error as? ChatStreamError, streamError == .cancelled { return true }
        return false
    }
}
