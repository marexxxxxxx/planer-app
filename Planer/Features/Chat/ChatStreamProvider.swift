//
//  ChatStreamProvider.swift
//  Planer
//
//  Vertrag zwischen Chat-Oberfläche und Hermes-Antwortstrom
//  (spec-chat Rev 4 §9.1, §9.2).
//

import Foundation

/// Herkunft einer Chat-Antwort (spec-voice Rev 2 §7, N7).
///
/// Zweck: die Oberfläche zeigt an jedem Assistenten-Eintrag, welches Modell
/// geantwortet hat; ein stiller Wechsel ist damit per Bauart ausgeschlossen
/// (§7 Regel 6).
/// Grenze: in V3 liefert nur der Hermes-Anbieter `.hermes`. `.lokal` setzt
/// erst der Router aus V5.
enum ChatEngine: String, Equatable, Sendable {
    /// Antwort von Hermes über den Chat-Endpunkt.
    case hermes
    /// Antwort vom lokalen Modell auf dem Gerät (V5).
    case lokal

    /// Beschriftung der Herkunft an der Agent-Bubble.
    var title: String {
        switch self {
        case .hermes:
            return "Hermes"
        case .lokal:
            return "Gerät"
        }
    }
}

/// Ereignisse, die die Oberfläche kennt.
///
/// Zweck: `ChatView`/`ChatViewModel` reagieren nur auf diese Fälle; der Dialekt
/// des Servers bleibt dahinter.
/// Grenze: keine Werkzeugausführung. `toolProgress` beschreibt nur, was der
/// Server ohnehin tut.
enum ChatStreamEvent: Equatable, Sendable {
    /// Antwort-ID aus dem Session-Header (§4.4 Schritt 7, F15).
    ///
    /// Wird nur gesendet, wenn der Server den Header mitschickt. Das ViewModel
    /// übernimmt eine abweichende ID; fehlt der Header, bleibt die gesendete ID.
    case sessionID(String)
    /// Herkunft, vor dem ersten Delta (N7). In v1 immer `.hermes`.
    case engine(ChatEngine)
    /// `choices[0].delta.reasoning_content`
    case reasoningDelta(String)
    /// `choices[0].delta.content`
    case textDelta(String)
    /// benanntes Ereignis `hermes.tool.progress`
    case toolProgress(ChatToolProgress)
    /// benanntes Ereignis `hermes.status` (keine Chat-Zeile)
    case status(ChatStatusNote)
    /// benanntes Ereignis `approval.request`
    case approval(ChatApproval)
    /// Abschluss-Chunk bzw. `[DONE]`
    case finished(ChatFinish)
}

/// Fehler des Streaming-Anbieters.
enum ChatStreamError: Error, Equatable, LocalizedError {
    case cancelled
    case http(APIError)
    case protocolViolation(String)
    case limitExceeded(String)
    case emptyResponse

    var errorDescription: String? {
        switch self {
        case .cancelled:
            return "Antwort abgebrochen."
        case .http(let error):
            return error.errorDescription
        case .protocolViolation(let detail):
            return "Antwort nicht lesbar: \(detail)"
        case .limitExceeded(let detail):
            return detail
        case .emptyResponse:
            return "Der Server hat keine Antwort geliefert."
        }
    }
}

/// Der schmale Vertrag zwischen Chat-Oberfläche und Antwortstrom.
///
/// Zweck: die Oberfläche kennt nur diese Ereignisse; ein anderer Dialekt ist
/// eine andere Implementierung dieses Protokolls — ohne Änderung an `ChatView`
/// oder `ChatViewModel`.
/// Grenze: kein Werkzeugaufruf, keine Sitzungsverwaltung und keine Retry-Logik.
protocol ChatStreamProvider: Sendable {
    /// Streamt die Antwort auf genau einen neuen User-Turn in einer bestehenden
    /// Sitzung. Der Body trägt **nur** diesen Turn; die Historie lädt der Server
    /// aus seiner Datenbank. Abbruch über `Task.cancel()` →
    /// `ChatStreamError.cancelled`.
    func stream(sessionID: String, userText: String) -> AsyncThrowingStream<ChatStreamEvent, Error>
}

/// Body von `POST /v1/chat/completions` — genau ein User-Turn, kein Modell,
/// keine Werkzeuge, keine Historie.
struct ChatRequestBody: Encodable, Sendable {
    struct Message: Encodable, Sendable {
        let role: String
        let content: String
    }

    let messages: [Message]
    let stream: Bool
}

/// Der Hermes-Antwortstrom.
struct HermesChatStreamProvider: ChatStreamProvider {

    /// Obergrenze einer gepufferten JSON-Antwort (Nicht-Stream-Fallback).
    private static let maxJSONBodyBytes = 1_048_576
    /// Obergrenze des Fehlertextes aus einer Nicht-2xx-Antwort.
    private static let maxErrorBodyBytes = 4_096

    private let configuration: HermesChatConfiguration
    /// Der Strom-Client trägt `streamIdleTimeout`, nie den 10-s-Default des
    /// `NetworkClient`. Genau eine Instanz, einmal in `init` gebaut.
    private let client: NetworkClient

    init(
        configuration: HermesChatConfiguration = HermesChatConfiguration(),
        networkClient: NetworkClient? = nil
    ) {
        self.configuration = configuration
        self.client = networkClient ?? NetworkClient(timeout: configuration.streamIdleTimeout)
    }

    func stream(
        sessionID: String,
        userText: String
    ) -> AsyncThrowingStream<ChatStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await run(
                        sessionID: sessionID,
                        userText: userText,
                        continuation: continuation
                    )
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
        sessionID: String,
        userText: String,
        continuation: AsyncThrowingStream<ChatStreamEvent, Error>.Continuation
    ) async throws {
        // O1/N2: denselben einen Guard wie die API benutzen — kein zweiter
        // Guard-Ort, keine Kopie der URL. Der Wert kommt aus der Keychain.
        let service = try ServiceConfiguration.load(.hermes)
        try HermesChatConfiguration.validateBaseURL(path: service.baseURL.path)

        // Request und Header kommen aus dem `NetworkClient` — dieselbe Kette wie
        // jeder andere Dienst und damit genau eine Header-Injektion.
        let request = APIRequest(
            method: .post,
            path: configuration.chatPath,
            body: try makeChatRequestBody(userText: userText),
            accept: configuration.eventStreamContentType + ", application/json",
            headers: [
                configuration.sessionHeader: sessionID,
                "Content-Type": "application/json"
            ]
        )

        let stream: StreamingResponse
        do {
            stream = try await client.stream(request, for: .hermes)
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
            let body = (try? await HermesHTTP.collect(bytes, limit: Self.maxErrorBodyBytes)) ?? Data()
            throw ChatStreamError.http(
                APIError.from(
                    status: http.statusCode,
                    body: body,
                    retryAfter: NetworkClient.retryAfter(from: http)
                )
            )
        }

        // H1/F15: Die Antwort-ID aus dem Header ist die einzige verlässliche
        // Quelle nach einem Turn. Sie wird vor jedem Inhalt gemeldet.
        if let responseSessionID = http.value(forHTTPHeaderField: configuration.sessionHeader),
           !responseSessionID.isEmpty {
            continuation.yield(.sessionID(responseSessionID))
        }

        // N7: die Herkunft steht fest, bevor der erste Text ankommt.
        continuation.yield(.engine(.hermes))

        do {
            if HermesHTTP.isEventStream(
                http,
                eventStreamContentType: configuration.eventStreamContentType
            ) {
                try await consumeEventStream(bytes, continuation: continuation)
            } else {
                // Ein Server, der trotz `stream: true` ein JSON-Objekt liefert, ist
                // kein Fehler: die Antwort wird als ein Stück ausgegeben.
                let body = try await HermesHTTP.collect(bytes, limit: Self.maxJSONBodyBytes)
                try emit(responseBody: body, continuation: continuation)
            }
        } catch let error as URLError {
            // M2: `URLSession.AsyncBytes` wirft mitten im Strom. Ohne dieses
            // Mapping käme beim Nutzer „Unbekannter Fehler.“ an.
            throw Self.streamError(from: error)
        } catch is CancellationError {
            throw ChatStreamError.cancelled
        }
    }

    /// Bildet einen `URLError` aus dem laufenden Strom auf die festgelegten
    /// Fälle ab (F6): Timeout, offline, Abbruch.
    private static func streamError(from error: URLError) -> ChatStreamError {
        switch error.code {
        case .cancelled:
            return .cancelled
        case .timedOut:
            return .http(.timeout)
        default:
            return .http(.offline)
        }
    }

    // MARK: Anfrage

    /// Baut den Body aus **einem** User-Turn. Die Historie lädt der Server.
    private func makeChatRequestBody(userText: String) throws -> Data {
        let body = ChatRequestBody(
            messages: [ChatRequestBody.Message(role: "user", content: userText)],
            stream: true
        )
        do {
            return try JSONEncoder().encode(body)
        } catch {
            throw ChatStreamError.protocolViolation("Chat-Anfrage nicht serialisierbar.")
        }
    }

    // MARK: Ereignisse

    private func consumeEventStream(
        _ bytes: URLSession.AsyncBytes,
        continuation: AsyncThrowingStream<ChatStreamEvent, Error>.Continuation
    ) async throws {
        var decoder = ServerSentEventDecoder()
        var finishReason: String?
        var errorMessage: String?
        var characters = 0
        // F8: nur echter Inhalt zählt — der Rollen-Chunk ist inhaltslos.
        var sawContent = false

        for try await line in bytes.lines {
            try Task.checkCancellation()
            guard let event = try decoder.consume(line: line) else { continue }
            let payload = event.data.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !payload.isEmpty else { continue }

            if let name = event.event, !name.isEmpty {
                try emit(named: name, payload: payload, continuation: continuation)
                continue
            }

            if payload == "[DONE]" {
                break
            }
            guard let data = payload.data(using: .utf8) else { continue }

            let chunk: ChatCompletionChunk
            do {
                chunk = try Self.decoder.decode(ChatCompletionChunk.self, from: data)
            } catch {
                // F18: laut scheitern, nicht still weiterlaufen und eine leere
                // Antwort als Erfolg verkaufen.
                throw ChatStreamError.protocolViolation(
                    "Stream-Ereignis entspricht nicht dem Hermes-Vertrag (choices[0].delta)."
                )
            }

            if let message = chunk.error?.message, !message.isEmpty {
                errorMessage = message
            }

            guard let choice = chunk.choices.first else { continue }
            if let reasoning = choice.delta?.reasoningContent, !reasoning.isEmpty {
                sawContent = true
                characters += reasoning.count
                guard characters <= configuration.maxTextCharacters else {
                    throw ChatStreamError.limitExceeded("Antwort überschreitet das Zeichenlimit.")
                }
                continuation.yield(.reasoningDelta(reasoning))
            }
            if let content = choice.delta?.content, !content.isEmpty {
                sawContent = true
                characters += content.count
                guard characters <= configuration.maxTextCharacters else {
                    throw ChatStreamError.limitExceeded("Antwort überschreitet das Zeichenlimit.")
                }
                continuation.yield(.textDelta(content))
            }
            if let reason = choice.finishReason, !reason.isEmpty {
                finishReason = reason
            }
        }

        try Task.checkCancellation()

        // F12: ein Fehler hat Vorrang vor der Leer-Prüfung; der Teilstand bleibt.
        if finishReason == "error" {
            continuation.yield(
                .finished(ChatFinish(reason: finishReason, errorMessage: errorMessage))
            )
            return
        }
        // F8: kein Inhalt angekommen — das ist ein Fehler, kein leerer Erfolg.
        guard sawContent else {
            throw ChatStreamError.emptyResponse
        }
        continuation.yield(
            .finished(ChatFinish(reason: finishReason, errorMessage: errorMessage))
        )
    }

    /// Wertet ein benanntes SSE-Ereignis aus. Unbekannte Namen werden
    /// ignoriert (F17), der Strom läuft weiter.
    private func emit(
        named name: String,
        payload: String,
        continuation: AsyncThrowingStream<ChatStreamEvent, Error>.Continuation
    ) throws {
        guard let data = payload.data(using: .utf8) else { return }
        switch name {
        case "hermes.tool.progress":
            guard let progress = try? Self.decoder.decode(ChatToolProgress.self, from: data) else {
                throw ChatStreamError.protocolViolation("Werkzeug-Ereignis nicht lesbar.")
            }
            continuation.yield(.toolProgress(progress))
        case "hermes.status":
            guard let note = try? Self.decoder.decode(ChatStatusNote.self, from: data) else {
                throw ChatStreamError.protocolViolation("Status-Ereignis nicht lesbar.")
            }
            continuation.yield(.status(note))
        case "approval.request":
            guard let approval = try? Self.decoder.decode(ChatApproval.self, from: data) else {
                throw ChatStreamError.protocolViolation("Freigabe-Ereignis nicht lesbar.")
            }
            continuation.yield(.approval(approval))
        default:
            return
        }
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

        var sawContent = false
        if let reasoning = choice.message?.reasoningContent, !reasoning.isEmpty {
            sawContent = true
            continuation.yield(
                .reasoningDelta(String(reasoning.prefix(configuration.maxReasoningCharacters)))
            )
        }
        if let text = choice.message?.content, !text.isEmpty {
            sawContent = true
            continuation.yield(.textDelta(String(text.prefix(configuration.maxTextCharacters))))
        }

        let errorMessage = response.error?.message
        if choice.finishReason == "error" {
            continuation.yield(
                .finished(ChatFinish(reason: choice.finishReason, errorMessage: errorMessage))
            )
            return
        }
        guard sawContent else {
            throw ChatStreamError.emptyResponse
        }
        continuation.yield(
            .finished(ChatFinish(reason: choice.finishReason, errorMessage: errorMessage))
        )
    }

    // MARK: Wire-Typen

    /// Ein SSE-Ereignis des Chat-Completions-Dialekts (unbenannter Frame).
    private struct ChatCompletionChunk: Decodable {
        struct ErrorDetail: Decodable {
            let message: String?
        }

        struct Choice: Decodable {
            struct Delta: Decodable {
                let content: String?
                let reasoningContent: String?

                enum CodingKeys: String, CodingKey {
                    case content
                    case reasoningContent = "reasoning_content"
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
        let error: ErrorDetail?
    }

    /// Eine vollständige (nicht gestreamte) Antwort desselben Dialekts.
    private struct ChatCompletionResponse: Decodable {
        struct ErrorDetail: Decodable {
            let message: String?
        }

        struct Choice: Decodable {
            struct Message: Decodable {
                let content: String?
                let reasoningContent: String?

                enum CodingKeys: String, CodingKey {
                    case content
                    case reasoningContent = "reasoning_content"
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
        let error: ErrorDetail?
    }

    private static let decoder = JSONDecoder()
}
