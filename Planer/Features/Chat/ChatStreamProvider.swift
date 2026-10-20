//
//  ChatStreamProvider.swift
//  Planer
//
//  Schmaler Vertrag für LLM-Text-Streaming — der nicht belegte Teil des
//  Chat-Tabs (spec-ios §9.3).
//

import Foundation

/// Eine Nachricht, wie der Streaming-Anbieter sie sieht.
///
/// Zweck: die Chat-Historie in der Form, die ein Chat-Completions-Endpunkt
/// erwartet — Rolle, Text und optional die Zuordnung zu einem Werkzeugaufruf.
/// Grenze: kein Anhang, kein Bild, kein `system`-Prompt durch die Oberfläche.
struct ChatTurn: Equatable, Sendable {
    enum Role: String, Sendable {
        case user
        case assistant
        case tool
    }

    let role: Role
    let content: String
    /// Nur bei `role == .tool`: die `id` des Aufrufs, dessen Ergebnis das ist.
    let toolCallID: String?
    /// Nur bei `role == .tool`: der Werkzeugname.
    let toolName: String?

    init(role: Role, content: String, toolCallID: String? = nil, toolName: String? = nil) {
        self.role = role
        self.content = content
        self.toolCallID = toolCallID
        self.toolName = toolName
    }
}

/// Ein vollständiger Werkzeugaufruf, den das Modell angefordert hat.
struct ToolCallRequest: Equatable, Sendable, Identifiable {
    /// Position im Delta-Strom; ordnet Badge und Ergebnis einander zu.
    let index: Int
    /// Aufruf-ID, die als `tool_call_id` zurückgegeben werden muss.
    let id: String
    let name: String
    /// Argumente als JSON-Text — erst der `MCPClient` prüft sie als Objekt.
    let argumentsJSON: String
}

/// Ereignisse, die die Oberfläche kennt.
///
/// Zweck: `ChatView`/`ChatViewModel` reagieren nur auf diese vier Fälle; der
/// Dialekt des Anbieters bleibt dahinter.
/// Grenze: keine Werkzeugausführung. `toolCallFinished` ist eine **Anforderung**
/// — ausgeführt wird sie über `MCPClient.callTool` (`tools/call`).
enum ChatStreamEvent: Equatable, Sendable {
    case textDelta(String)
    case toolCallStarted(index: Int, name: String)
    case toolCallFinished(ToolCallRequest)
    case finished(reason: String?)
}

/// Fehler des Streaming-Anbieters.
enum ChatStreamError: Error, Equatable, LocalizedError {
    case cancelled
    case http(APIError)
    case protocolViolation(String)
    case invalidArguments(String)
    case emptyResponse

    var errorDescription: String? {
        switch self {
        case .cancelled:
            return "Antwort abgebrochen."
        case .http(let error):
            return error.errorDescription
        case .protocolViolation(let detail):
            return "Antwort nicht lesbar: \(detail)"
        case .invalidArguments(let detail):
            return "Werkzeugargumente ungültig: \(detail)"
        case .emptyResponse:
            return "Der Chat-Endpunkt hat keine Antwort geliefert."
        }
    }
}

/// Der schmale Vertrag zwischen Chat-Oberfläche und Text-Streaming.
///
/// Zweck: die Oberfläche kennt nur diese Ereignisse; ein anderer Streaming-
/// Dialekt ist eine andere Implementierung dieses Protokolls — ohne Änderung an
/// `ChatView` oder `ChatViewModel`.
/// Grenze: kein Tool-Aufruf, keine MCP-Session und keine Retry-Logik. Tool-Calls
/// führt der `ChatViewModel` über `MCPClient` aus.
protocol ChatStreamProvider: Sendable {
    /// Liefert die Antwort als Ereignisfolge. Der Aufrufer bricht über
    /// `Task.cancel()` ab; die Implementierung beendet den Strom dann mit
    /// `ChatStreamError.cancelled`.
    func stream(messages: [ChatTurn], tools: [MCPTool]) -> AsyncThrowingStream<ChatStreamEvent, Error>
}

/// `[ANNAHME]` — OpenAI-kompatibler Streaming-Dialekt.
///
/// **Nicht belegt:** spec-ios §9.3 (F-Hermes-Streaming) stellt ausdrücklich
/// fest, dass MCP kein LLM-Text-Streaming standardisiert und das Format des
/// Hermes-Agenten offen ist. Diese Implementierung unterstellt deshalb:
///
/// - Endpunkt `POST /v1/chat/completions` (relativ zur Hermes-Basis-URL),
/// - Modellkennung `hermes`,
/// - SSE-Ereignisse mit `choices[0].delta.content` und
///   `choices[0].delta.tool_calls` (`id`, `function.name`,
///   `function.arguments`), Abschluss über `[DONE]` oder `finish_reason`.
///
/// Beides ist im Code als `[ANNAHME]` markiert. Antwortet Hermes anders, wird
/// **nur diese Datei** ersetzt: `ChatView`, `ChatViewModel` und `MCPClient`
/// bleiben unverändert, weil sie ausschließlich `ChatStreamProvider` bzw.
/// `ChatStreamEvent` kennen. Bis zur Auftraggeber-Antwort gilt der Dialekt als
/// Annahme — nicht als Vertrag.
struct OpenAICompatibleChatStreamProvider: ChatStreamProvider {

    struct Configuration: Sendable {
        /// `[ANNAHME]` Pfad des Chat-Endpunkts; belegt ist nur der MCP-Kern.
        var endpointPath = "/v1/chat/completions"

        /// `[ANNAHME]` Modellkennung. Muss der Auftraggeber an Hermes anpassen.
        var modelIdentifier = "hermes"

        /// Zeitlimit des Stroms. Ein Chat darf länger dauern als ein Sync-Lauf.
        var streamTimeout: TimeInterval = 120

        /// So viele Nachrichten der Historie werden gesendet (älteste fallen weg).
        var maxHistoryTurns = 24

        /// Obergrenze der Werkzeug-Definitionen je Anfrage.
        var maxTools = 64

        /// Obergrenze des gestreamten Textes einer Antwort.
        var maxDeltaCharacters = 24_000

        /// Obergrenze einer gepufferten JSON-Antwort (Nicht-Stream-Fallback).
        var maxJSONBodyBytes = 1_048_576
    }

    private let urlSession: URLSession
    private let keychain: KeychainManager
    private let settings: Configuration

    init(
        urlSession: URLSession = .shared,
        keychain: KeychainManager = KeychainManager(),
        settings: Configuration = Configuration()
    ) {
        self.urlSession = urlSession
        self.keychain = keychain
        self.settings = settings
    }

    func stream(
        messages: [ChatTurn],
        tools: [MCPTool]
    ) -> AsyncThrowingStream<ChatStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await run(messages: messages, tools: tools, continuation: continuation)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }

    // MARK: Ausführung

    private func run(
        messages: [ChatTurn],
        tools: [MCPTool],
        continuation: AsyncThrowingStream<ChatStreamEvent, Error>.Continuation
    ) async throws {
        // Request und Header kommen aus dem `NetworkClient` — dieselbe Kette wie
        // jeder andere Dienst und damit genau eine Header-Injektion (spec-ios §8-1).
        let networkClient = NetworkClient(
            session: urlSession,
            timeout: settings.streamTimeout,
            keychain: keychain
        )
        let request = APIRequest(
            method: .post,
            path: settings.endpointPath,
            body: try encodeBody(messages: messages, tools: tools),
            accept: MCPProtocol.eventStreamContentType + ", application/json",
            headers: ["Content-Type": "application/json"]
        )

        let stream: StreamingResponse
        do {
            stream = try await networkClient.stream(request, for: .hermes)
        } catch let error as APIError {
            if error == .cancelled {
                throw ChatStreamError.cancelled
            }
            throw ChatStreamError.http(error)
        } catch is CancellationError {
            throw ChatStreamError.cancelled
        }

        let http = stream.response
        let bytes = stream.bytes
        guard (200..<300).contains(http.statusCode) else {
            let body = (try? await HermesHTTP.collect(bytes, limit: 4_096)) ?? Data()
            throw ChatStreamError.http(
                APIError.from(
                    status: http.statusCode,
                    body: body,
                    retryAfter: NetworkClient.retryAfter(from: http)
                )
            )
        }

        if HermesHTTP.isEventStream(http) {
            try await consumeEventStream(bytes, continuation: continuation)
        } else {
            // Ein Server, der trotz `stream: true` ein JSON-Objekt liefert, ist
            // kein Fehler: die Antwort wird als ein Stück ausgegeben.
            let body = try await HermesHTTP.collect(bytes, limit: settings.maxJSONBodyBytes)
            try emit(responseBody: body, continuation: continuation)
        }
    }

    // MARK: Anfrage

    private func encodeBody(messages: [ChatTurn], tools: [MCPTool]) throws -> Data {
        let turns = messages.suffix(max(1, settings.maxHistoryTurns))
        var payload: [String: JSONValue] = [
            "model": .string(settings.modelIdentifier),
            "stream": .bool(true),
            "messages": .array(turns.map { Self.encode(turn: $0) })
        ]
        if !tools.isEmpty {
            payload["tools"] = .array(tools.prefix(settings.maxTools).map { tool in
                .object([
                    "type": .string("function"),
                    "function": .object([
                        "name": .string(tool.name),
                        "description": .string(tool.description ?? tool.title ?? ""),
                        "parameters": tool.inputSchema
                    ])
                ])
            })
        }
        do {
            return try JSONEncoder().encode(JSONValue.object(payload))
        } catch {
            throw ChatStreamError.protocolViolation("Chat-Anfrage nicht serialisierbar.")
        }
    }

    private static func encode(turn: ChatTurn) -> JSONValue {
        var object: [String: JSONValue] = [
            "role": .string(turn.role.rawValue),
            "content": .string(turn.content)
        ]
        if let toolCallID = turn.toolCallID {
            object["tool_call_id"] = .string(toolCallID)
        }
        if let toolName = turn.toolName {
            object["name"] = .string(toolName)
        }
        return .object(object)
    }

    // MARK: Ereignisse

    private func consumeEventStream(
        _ bytes: URLSession.AsyncBytes,
        continuation: AsyncThrowingStream<ChatStreamEvent, Error>.Continuation
    ) async throws {
        var decoder = ServerSentEventDecoder()
        var pending: [Int: PendingToolCall] = [:]
        var finishReason: String?
        var characters = 0
        var receivedEvent = false

        for try await line in bytes.lines {
            try Task.checkCancellation()
            guard let event = try decoder.consume(line: line) else { continue }
            let payload = event.data.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !payload.isEmpty else { continue }
            if payload == "[DONE]" {
                break
            }
            receivedEvent = true
            guard let data = payload.data(using: .utf8) else { continue }

            let chunk: ChatCompletionChunk
            do {
                chunk = try Self.decoder.decode(ChatCompletionChunk.self, from: data)
            } catch {
                // `[ANNAHME]`-Dialekt nicht erfüllt: laut scheitern, nicht still
                // weiterlaufen und eine leere Antwort als Erfolg verkaufen.
                throw ChatStreamError.protocolViolation(
                    "Stream-Ereignis entspricht nicht dem [ANNAHME]-Dialekt (choices[0].delta)."
                )
            }

            guard let choice = chunk.choices.first else { continue }
            if let delta = choice.delta?.content, !delta.isEmpty {
                characters += delta.count
                guard characters <= settings.maxDeltaCharacters else {
                    throw ChatStreamError.protocolViolation("Antwort überschreitet das Zeichenlimit.")
                }
                continuation.yield(.textDelta(delta))
            }
            for toolCallDelta in choice.delta?.toolCalls ?? [] {
                absorb(toolCallDelta, into: &pending, continuation: continuation)
            }
            if let reason = choice.finishReason, !reason.isEmpty {
                finishReason = reason
            }
        }

        try Task.checkCancellation()
        guard receivedEvent else {
            throw ChatStreamError.emptyResponse
        }

        for (index, call) in pending.sorted(by: { $0.key < $1.key }) {
            try emit(toolCall: call, index: index, continuation: continuation)
        }
        continuation.yield(.finished(reason: finishReason))
    }

    private func absorb(
        _ delta: ToolCallDelta,
        into pending: inout [Int: PendingToolCall],
        continuation: AsyncThrowingStream<ChatStreamEvent, Error>.Continuation
    ) {
        let index = delta.index ?? 0
        var call = pending[index] ?? PendingToolCall()

        if let identifier = delta.id, !identifier.isEmpty {
            call.identifier = identifier
        }
        if let name = delta.function?.name, !name.isEmpty, name != call.name {
            let isFirstAnnouncement = call.name.isEmpty
            call.name = name
            if isFirstAnnouncement {
                continuation.yield(.toolCallStarted(index: index, name: name))
            }
        }
        if let fragment = delta.function?.arguments {
            call.arguments += fragment
        }
        pending[index] = call
    }

    private func emit(
        toolCall call: PendingToolCall,
        index: Int,
        continuation: AsyncThrowingStream<ChatStreamEvent, Error>.Continuation
    ) throws {
        guard !call.name.isEmpty else { return }
        let identifier = call.identifier.isEmpty ? "call_\(index)" : call.identifier
        let rawArguments = call.arguments.trimmingCharacters(in: .whitespacesAndNewlines)
        let argumentsJSON = rawArguments.isEmpty ? "{}" : rawArguments
        guard let data = argumentsJSON.data(using: .utf8),
              (try? JSONDecoder().decode(JSONValue.self, from: data)) != nil
        else {
            throw ChatStreamError.invalidArguments(
                "Werkzeug \(call.name) hat kein gültiges JSON als Argumente."
            )
        }
        continuation.yield(
            .toolCallFinished(
                ToolCallRequest(
                    index: index,
                    id: identifier,
                    name: call.name,
                    argumentsJSON: argumentsJSON
                )
            )
        )
    }

    /// Fallback für eine vollständige JSON-Antwort (`application/json`).
    private func emit(
        responseBody: Data,
        continuation: AsyncThrowingStream<ChatStreamEvent, Error>.Continuation
    ) throws {
        let response: ChatCompletionResponse
        do {
            response = try Self.decoder.decode(ChatCompletionResponse.self, from: responseBody)
        } catch {
            throw ChatStreamError.protocolViolation("Antwort ohne choices[0].message.")
        }
        guard let choice = response.choices.first else {
            throw ChatStreamError.emptyResponse
        }

        if let text = choice.message?.content, !text.isEmpty {
            continuation.yield(.textDelta(String(text.prefix(settings.maxDeltaCharacters))))
        }

        var pending: [Int: PendingToolCall] = [:]
        for (offset, toolCall) in (choice.message?.toolCalls ?? []).enumerated() {
            let index = toolCall.index ?? offset
            var call = PendingToolCall()
            call.identifier = toolCall.id ?? ""
            call.name = toolCall.function?.name ?? ""
            call.arguments = toolCall.function?.arguments ?? "{}"
            pending[index] = call
        }
        for (index, call) in pending.sorted(by: { $0.key < $1.key }) {
            if !call.name.isEmpty {
                continuation.yield(.toolCallStarted(index: index, name: call.name))
            }
            try emit(toolCall: call, index: index, continuation: continuation)
        }
        continuation.yield(.finished(reason: choice.finishReason))
    }

    // MARK: Wire-Typen (`[ANNAHME]`)

    private struct PendingToolCall {
        var identifier = ""
        var name = ""
        var arguments = ""
    }

    /// Ein SSE-Ereignis des `[ANNAHME]`-Dialekts.
    private struct ChatCompletionChunk: Decodable {
        struct Choice: Decodable {
            struct Delta: Decodable {
                let content: String?
                let toolCalls: [ToolCallDelta]?

                enum CodingKeys: String, CodingKey {
                    case content
                    case toolCalls = "tool_calls"
                }
            }

            let delta: Delta?
            let finishReason: String?

            enum CodingKeys: String, CodingKey {
                case delta
                case finishReason = "finish_reason"
            }
        }

        let choices: [Choice]
    }

    /// Ein Delta eines Werkzeugaufrufs: `id`, `function.name`, `function.arguments`.
    private struct ToolCallDelta: Decodable {
        struct Function: Decodable {
            let name: String?
            let arguments: String?
        }

        let index: Int?
        let id: String?
        let function: Function?
    }

    /// Eine vollständige (nicht gestreamte) Antwort desselben Dialekts.
    private struct ChatCompletionResponse: Decodable {
        struct Choice: Decodable {
            struct Message: Decodable {
                let content: String?
                let toolCalls: [ToolCallDelta]?

                enum CodingKeys: String, CodingKey {
                    case content
                    case toolCalls = "tool_calls"
                }
            }

            let message: Message?
            let finishReason: String?

            enum CodingKeys: String, CodingKey {
                case message
                case finishReason = "finish_reason"
            }
        }

        let choices: [Choice]
    }

    private static let decoder = JSONDecoder()
}
