//
//  HermesChatAPI.swift
//  Planer
//
//  REST-Zugriffe des Chat-Tabs auf den Hermes-API-Server
//  (spec-chat Rev 4 §9.4).
//

import Foundation

/// Sitzungen listen, anlegen und laden, Nachrichten lesen, Freigabe beantworten.
///
/// Zweck: die HTTP-Flächen des Chats an einer Stelle; das ViewModel kennt nur
/// diese Methoden.
/// Grenze: kein Streaming (das macht `HermesChatStreamProvider`) und keine
/// Zustandshaltung über die eine geprüfte Basis-URL hinaus.
struct HermesChatAPI: Sendable {

    private let configuration: HermesChatConfiguration
    /// Lesen: `restTimeout`, `RetryPolicy.default`.
    private let reader: NetworkClient
    /// Schreiben: `restTimeout`, **kein** Retry — ein zweites `POST /api/sessions`
    /// würde sonst eine Geister-Sitzung anlegen.
    private let writer: NetworkClient
    private let baseURLGuard = BaseURLGuard()

    /// `networkClient` überschreibt nur den Lese-Client (Tests).
    init(
        configuration: HermesChatConfiguration = HermesChatConfiguration(),
        networkClient: NetworkClient? = nil
    ) {
        self.configuration = configuration
        self.reader = networkClient ?? NetworkClient(timeout: configuration.restTimeout)
        // E1: Argumente in Deklarationsreihenfolge `init(session:retryPolicy:timeout:keychain:)`.
        self.writer = NetworkClient(
            retryPolicy: RetryPolicy(maxAttempts: 1),
            timeout: configuration.restTimeout
        )
    }

    // MARK: Lesen

    /// Alle Quellen; die App blendet nur interne Quellen aus (MARAAA-155).
    /// Ein `source`-Query-Parameter würde die Hermes-Historie auf `desktop`
    /// verkürzen und fehlt deshalb bewusst.
    func listSessions(limit: Int, offset: Int) async throws -> SessionPage {
        try await validateBaseURL()
        let request = APIRequest(
            method: .get,
            path: configuration.sessionsPath,
            query: [
                URLQueryItem(name: "limit", value: String(limit)),
                URLQueryItem(name: "offset", value: String(offset))
            ]
        )
        return try await reader.send(request, for: .hermes, as: SessionPage.self)
    }

    func session(id: String) async throws -> SessionSummary {
        try await validateBaseURL()
        let request = APIRequest(
            method: .get,
            path: configuration.sessionsPath + "/" + id
        )
        let envelope = try await reader.send(request, for: .hermes, as: SessionEnvelope.self)
        return envelope.session
    }

    func messages(sessionID: String, limit: Int, offset: Int, order: MessageOrder) async throws -> MessagePage {
        try await validateBaseURL()
        let request = APIRequest(
            method: .get,
            path: configuration.sessionsPath + "/" + sessionID + "/messages",
            query: [
                URLQueryItem(name: "limit", value: String(limit)),
                URLQueryItem(name: "offset", value: String(offset)),
                URLQueryItem(name: "order", value: order.rawValue)
            ]
        )
        return try await reader.send(request, for: .hermes, as: MessagePage.self)
    }

    // MARK: Schreiben

    /// Legt die Unterhaltung **vor** dem ersten Turn an, damit sie den
    /// Source-Tag der App trägt und im Verlauf sichtbar bleibt.
    func createSession() async throws -> SessionSummary {
        try await validateBaseURL()
        let body = try JSONEncoder().encode(CreateSessionBody(source: configuration.sessionSource))
        let request = APIRequest(
            method: .post,
            path: configuration.sessionsPath,
            body: body,
            headers: ["Content-Type": "application/json"]
        )
        let envelope = try await writer.send(request, for: .hermes, as: SessionEnvelope.self)
        return envelope.session
    }

    /// Beantwortet eine Freigabe. Der Wire-Wert kommt ausschließlich aus dem
    /// Enum — kein Roh-Literal in dieser Datei.
    func respondToApproval(runID: String, choice: ChatApprovalChoice) async throws {
        try await validateBaseURL()
        let path = String(format: configuration.approvalPath, runID)
        let body = try JSONEncoder().encode(ApprovalBody(choice: choice.rawValue))
        let request = APIRequest(
            method: .post,
            path: path,
            body: body,
            headers: ["Content-Type": "application/json"]
        )
        _ = try await writer.send(request, for: .hermes)
    }

    // MARK: Profil-Vorprüfung

    /// Prüft einmal je Turn, ob das gewählte Profil ausgeliefert wird (O7).
    ///
    /// - `profile == ""` → sofort zurück, kein Request.
    /// - `404` auf `/p/<profil>/health` → `profileNotServed(profil)`.
    /// - jeder andere Ausgang → kein Urteil über das Profil, kein Fehler.
    /// Grenze: nur `404` blockiert; 401/403/5xx/Transport überlässt die
    /// Entscheidung dem normalen Pfad (F-R6-5).
    func probeProfile() async throws {
        guard !configuration.profile.isEmpty else { return }
        try await validateBaseURL()
        let request = APIRequest(method: .get, path: configuration.healthPath)
        let result: (data: Data, response: HTTPURLResponse)
        do {
            result = try await reader.sendRaw(request, for: .hermes)
        } catch {
            // Kein Urteil: ein Transport- oder Auth-Fehler sagt nichts über
            // das Profil; der normale Pfad liefert seinen eigenen Fehler.
            return
        }
        if result.response.statusCode == 404 {
            throw HermesChatConfigurationError.profileNotServed(configuration.profile)
        }
    }

    // MARK: Basis-URL

    /// Einmal je Instanz: der Pfad der Basis-URL muss leer sein, sonst wird
    /// kein Request gesendet (F22). Die Prüfung selbst liegt in der
    /// Konfiguration; hier steht nur der Aufruf.
    private func validateBaseURL() async throws {
        try await baseURLGuard.validate(configuration: configuration)
    }

    private struct CreateSessionBody: Encodable {
        let source: String
    }

    private struct ApprovalBody: Encodable {
        let choice: String
    }
}

/// Merkt sich, dass die Basis-URL geprüft wurde.
///
/// Zweck: genau ein Guard-Aufruf je `HermesChatAPI`-Instanz; die Keychain wird
/// nicht vor jedem Request erneut gelesen.
/// Grenze: keine Zwischenspeicherung des Werts — die URL selbst bleibt allein
/// in der Keychain.
private actor BaseURLGuard {
    private var isValidated = false

    func validate(configuration: HermesChatConfiguration) throws {
        guard !isValidated else { return }
        let service = try ServiceConfiguration.load(.hermes)
        try HermesChatConfiguration.validateBaseURL(path: service.baseURL.path)
        isValidated = true
    }
}
