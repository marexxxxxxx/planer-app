//
//  ChatDTOs.swift
//  Planer
//
//  Wire-Typen des Hermes-Chats (spec-chat Rev 4 §5.1).
//

import Foundation

/// Eine Unterhaltung, wie sie die Verlaufsliste zeigt.
///
/// `Decodable` mit eigenem `init(from:)`, weil `title`, `preview` und
/// `last_active` fehlen dürfen und `message_count`/`tool_call_count`/Flags
/// Defaults brauchen.
struct SessionSummary: Identifiable, Decodable, Equatable, Sendable {
    let id: String
    var title: String?
    var preview: String?
    var messageCount: Int
    var toolCallCount: Int
    /// Epoch-Sekunden aus `last_active` — **roh**, wie der Server sie liefert.
    var lastActive: Double?
    var pinned: Bool
    var archived: Bool
    var source: String

    /// Anzeigezeit: die **einzige** Stelle, an der die Epoche interpretiert wird.
    var lastActiveDate: Date? { lastActive.map(Date.init(timeIntervalSince1970:)) }

    private enum CodingKeys: String, CodingKey {
        case id, title, preview, pinned, archived, source
        case messageCount = "message_count"
        case toolCallCount = "tool_call_count"
        case lastActive = "last_active"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        title = try c.decodeIfPresent(String.self, forKey: .title)
        preview = try c.decodeIfPresent(String.self, forKey: .preview)
        messageCount = try c.decodeIfPresent(Int.self, forKey: .messageCount) ?? 0
        toolCallCount = try c.decodeIfPresent(Int.self, forKey: .toolCallCount) ?? 0
        lastActive = try c.decodeIfPresent(Double.self, forKey: .lastActive)
        pinned = try c.decodeIfPresent(Bool.self, forKey: .pinned) ?? false
        archived = try c.decodeIfPresent(Bool.self, forKey: .archived) ?? false
        source = try c.decode(String.self, forKey: .source)
    }

    /// Expliziter Init für Tests und den Merge. **Keine** Defaults, damit kein
    /// Feld stillschweigend leer bleibt.
    init(
        id: String,
        title: String?,
        preview: String?,
        messageCount: Int,
        toolCallCount: Int,
        lastActive: Double?,
        pinned: Bool,
        archived: Bool,
        source: String
    ) {
        self.id = id
        self.title = title
        self.preview = preview
        self.messageCount = messageCount
        self.toolCallCount = toolCallCount
        self.lastActive = lastActive
        self.pinned = pinned
        self.archived = archived
        self.source = source
    }
}

extension SessionSummary {
    /// Kurzes Quellen-Badge der Verlaufsliste („Telegram“, „App“, …).
    ///
    /// Die **einzige** Stelle, an der Quellen auf Anzeigetext abgebildet
    /// werden. Unbekannte Quellen fallen auf den Rohwert zurück, statt
    /// unsichtbar zu werden (MARAAA-155).
    var sourceBadge: String {
        switch source {
        case "telegram": return "Telegram"
        case "desktop": return "App"
        case "dashboard": return "Dashboard"
        case "api_server": return "API"
        case "cli": return "CLI"
        default: return source
        }
    }
}

/// Die Wire-Hülle von `POST /api/sessions` und `GET /api/sessions/{id}`:
/// `{object, session}`. `object` wird ignoriert.
///
/// Bewusst ohne eigenes `CodingKeys`: der Schlüssel heißt auf der Leitung wie
/// das Feld, die Synthese genügt.
struct SessionEnvelope: Decodable, Equatable, Sendable {
    let session: SessionSummary
}

/// Eine gespeicherte Nachricht aus `GET /api/sessions/{id}/messages`.
struct ChatMessage: Decodable, Equatable, Sendable {
    let id: Int
    let role: String
    let content: String?
    let reasoning: String?
    let reasoningContent: String?
    let toolCalls: [StoredToolCall]?
    let toolName: String?
    let toolCallID: String?
    let displayKind: String?
    let timestamp: Double?

    private enum CodingKeys: String, CodingKey {
        case id, role, content, reasoning, timestamp
        case reasoningContent = "reasoning_content"
        case toolCalls = "tool_calls"
        case toolName = "tool_name"
        case toolCallID = "tool_call_id"
        case displayKind = "display_kind"
    }
}

/// Ein gespeicherter Werkzeugaufruf einer Assistenten-Nachricht.
struct StoredToolCall: Decodable, Equatable, Sendable {
    struct Function: Decodable, Equatable, Sendable {
        let name: String?
        let arguments: String?
    }

    let id: String?
    let type: String?
    let function: Function?
}

/// Ein Werkzeug-Lebenszeichen aus `hermes.tool.progress`.
struct ChatToolProgress: Decodable, Equatable, Sendable {
    enum Status: String, Decodable, Equatable, Sendable {
        case running
        case completed
    }

    let toolCallID: String
    let tool: String
    let emoji: String?
    let label: String?
    let status: Status

    private enum CodingKeys: String, CodingKey {
        case tool, emoji, label, status
        /// Wire ist camelCase.
        case toolCallID = "toolCallId"
    }
}

/// Eine Statusmeldung aus `hermes.status`; keine Chat-Zeile.
struct ChatStatusNote: Decodable, Equatable, Sendable {
    let kind: String
    let text: String
}

/// Die **einzige** Stelle, an der die Freigabe-Wire-Werte definiert sind.
///
/// `ChatViewModel` reicht nur diesen Enum durch und bildet nie ein Roh-Literal.
enum ChatApprovalChoice: String, Equatable, Sendable {
    case once = "once"
    case deny = "deny"
}

/// Eine Server-Freigabe aus `approval.request`.
struct ChatApproval: Decodable, Equatable, Sendable {
    let runID: String
    let command: String?
    let description: String?
    /// Roh, wie der Server sie schickt: neben der einmaligen Freigabe und der
    /// Ablehnung bietet er auch dauerhafte Varianten an.
    ///
    /// Bewusst `[String]` und **nicht** `[ChatApprovalChoice]`: Der Enum kennt
    /// nur zwei Fälle; ein unbekannter Rohwert würde sonst die **ganze**
    /// Freigabe verlieren.
    let choices: [String]

    /// Nur die in v1 darstellbaren Choices; der Rest wird verworfen
    /// (fail closed).
    var offeredChoices: [ChatApprovalChoice] {
        choices.compactMap(ChatApprovalChoice.init(rawValue:))
    }

    var canApproveOnce: Bool { offeredChoices.contains(.once) }
    var canDeny: Bool { offeredChoices.contains(.deny) }

    private enum CodingKeys: String, CodingKey {
        case command, description, choices
        case runID = "run_id"
    }
}

/// Das Ende eines Turns. **Kein Wire-Typ:** aus dem Abschluss-Chunk
/// zusammengesetzt (`finish_reason`, `error.message`, `hermes.error`) und
/// deshalb ohne `Decodable`.
struct ChatFinish: Equatable, Sendable {
    let reason: String?
    let errorMessage: String?
}

/// Wire-Hülle von `GET /api/sessions`: `{object, data[], limit, offset, has_more}`.
struct SessionPage: Decodable, Equatable, Sendable {
    let sessions: [SessionSummary]
    let hasMore: Bool

    private enum CodingKeys: String, CodingKey {
        case sessions = "data"
        case hasMore = "has_more"
    }
}

/// Wire-Hülle von `GET …/messages`:
/// `{object, session_id, data[], pagination{limit, offset, order, returned}}`.
///
/// `pagination.returned` ist **verschachtelt** und mit `CodingKeys` allein
/// nicht erreichbar; deshalb ein eigener `init(from:)` mit `nestedContainer`.
struct MessagePage: Decodable, Equatable, Sendable {
    let messages: [ChatMessage]
    let returned: Int

    private enum CodingKeys: String, CodingKey {
        case messages = "data"
        case pagination
    }

    private enum PaginationKeys: String, CodingKey {
        case limit, offset, order, returned
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        messages = try c.decode([ChatMessage].self, forKey: .messages)
        let p = try c.nestedContainer(keyedBy: PaginationKeys.self, forKey: .pagination)
        returned = try p.decode(Int.self, forKey: .returned)
    }
}

/// Blätterrichtung von `GET …/messages`.
enum MessageOrder: String, Sendable {
    case oldest
    case latest
}

/// Anzeigezustand einer Werkzeugkarte. Kein Erfolgsversprechen: `completed`
/// heißt „abgeschlossen“, nicht „erfolgreich“.
enum ToolCallStatus: Equatable, Sendable {
    case running
    case completed
    case awaitingApproval
    case denied
}
