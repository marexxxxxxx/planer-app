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
/// Zustandsübergänge — Verbindung, Ablauf, Abbruch, Fehler — passieren hier.
/// Grenze: kein HTTP und keine Header (das macht `MCPClient`) und kein
/// Streaming-Dialekt (das macht `ChatStreamProvider`). Die Klasse ist
/// `@MainActor`, weil sie direkt SwiftUI-Zustand hält.
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

        init(
            id: UUID = UUID(),
            kind: Kind,
            text: String,
            toolName: String? = nil,
            toolStatus: ToolCallBadge.Status? = nil
        ) {
            self.id = id
            self.kind = kind
            self.text = text
            self.toolName = toolName
            self.toolStatus = toolStatus
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

    private let mcpClient: MCPClient
    private let provider: ChatStreamProvider
    private var tools: [MCPTool] = []
    private var turns: [ChatTurn] = []
    private var streamTask: Task<Void, Never>?

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
        entries.append(Entry(kind: .user, text: text))
        turns.append(ChatTurn(role: .user, content: text))
        streamTask = Task { await run() }
    }

    /// Bricht die laufende Antwort ab (spec-ios §10: jeder lange Vorgang ist
    /// abbrechbar). Ein Abbruch ist kein Fehler und kein Erfolg.
    func cancel() {
        streamTask?.cancel()
    }

    func dismissNotice() {
        notice = nil
    }

    /// Löscht Verlauf und Historie; die Verbindung bleibt bestehen.
    func clear() {
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
                guard !outcome.toolRequests.isEmpty else { break }
                guard rounds < Limits.maxToolRounds else {
                    // Teilstand melden statt weiterzulaufen oder Erfolg zu behaupten.
                    notice = "Werkzeug-Aufrufe nach \(Limits.maxToolRounds) Runden gestoppt."
                    break
                }
                rounds += 1

                for request in outcome.toolRequests {
                    try Task.checkCancellation()
                    await execute(request, badgeID: outcome.badgeIDs[request.index])
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
                    let entry = Entry(kind: .agent, text: delta)
                    agentEntryID = entry.id
                    entries.append(entry)
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

    /// Führt einen angeforderten Werkzeugaufruf aus (`tools/call`).
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
