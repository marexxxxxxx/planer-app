//
//  ServiceSettingsSection.swift
//  Planer
//
//  URL/Token/CF-Access je Dienst + „Test Verbindung“ (spec-ios §5).
//

import Foundation
import SwiftUI

/// Einstellungs-Sektion eines einzelnen Dienstes.
///
/// Zweck: Basis-URL, CF-Access-Paar und den dienstspezifischen API-Account
/// erfassen, die URL auf den vom Dienst erwarteten `/api`-Pfad normalisieren
/// und ausschließlich über `KeychainManager` speichern.
/// Grenze: keine Anzeige von Server-Daten; „Test Verbindung“ ruft genau einen
/// fachlichen Endpunkt ab und unterscheidet Erfolg, Token-Fehler, Cloudflare
/// Access und falschen Pfad.
struct ServiceSettingsSection: View {
    let service: ServiceType

    private let keychain = KeychainManager()
    /// Redirects bleiben stehen, damit ein Cloudflare-Access-302 sichtbar wird.
    private let client = NetworkClient.connectionTest

    @State private var baseURL = ""
    @State private var cloudflareClientID = ""
    @State private var cloudflareClientSecret = ""
    @State private var apiCredentialValue = ""
    /// Hermes-Anmeldung (MARAAA-146); Mealie/Grocy/Dashboard bleiben beim Token.
    @State private var hermesUsername = ""
    @State private var hermesPassword = ""
    /// Optionaler Schlüssel des Hermes-API-Servers (Port 8642); gesetzt schaltet
    /// er Hermes auf `Authorization: Bearer` statt Password-Login um.
    @State private var hermesAPIToken = ""
    @State private var message: String?
    @State private var isTesting = false

    init(service: ServiceType) {
        self.service = service
    }

    var body: some View {
        Section {
            TextField("Basis-URL", text: $baseURL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.URL)

            Text(baseURLExample)
                .font(.caption)
                .foregroundStyle(.secondary)

            TextField("CF-Access-Client-ID", text: $cloudflareClientID)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()

            SecureField("CF-Access-Client-Secret", text: $cloudflareClientSecret)

            if service == .hermes {
                // Zwei Betriebsarten: Das Dashboard authentifiziert über den
                // Password-Login (MARAAA-146); ein optional hinterlegter
                // API-Schlüssel schaltet auf den API-Server und Bearer um.
                TextField("Benutzername", text: $hermesUsername)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                SecureField("Passwort", text: $hermesPassword)
                SecureField("API-Schlüssel (API-Server, optional)", text: $hermesAPIToken)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Text("Chat-Endpunkte liegen auf dem API-Server (Port 8642) und brauchen den API-Schlüssel. Mit Schlüssel entfällt der Password-Login; Benutzername/Passwort gelten nur für das Dashboard.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if let credential = service.apiCredential {
                SecureField(credential.displayName, text: $apiCredentialValue)
            }

            Button("Speichern") {
                save()
            }

            Button {
                Task { await testConnection() }
            } label: {
                if isTesting {
                    ProgressView()
                } else {
                    Text("Test Verbindung")
                }
            }
            .disabled(isTesting)

            if let message {
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text(service.displayName)
        } footer: {
            Text("Werte werden ausschließlich in der Keychain gespeichert.")
        }
        .task {
            load()
        }
    }

    /// Beispiel für die Eingabe: Mealie/Grocy/Dashboard bekommen `/api`
    /// automatisch, Hermes erwartet den nackten Origin.
    private var baseURLExample: String {
        switch service {
        case .mealie, .grocy, .dashboard:
            return "Beispiel: https://host (→ /api automatisch)"
        case .hermes:
            return "Beispiel: https://hermes.example.com (ohne Pfad)"
        }
    }

    /// Liest die gespeicherten Werte in die Eingabefelder.
    ///
    /// Eine ältere, nicht normalisierte Basis-URL wird beim Laden in ihre
    /// gültige Form gebracht; schlägt das fehl, bleibt der Rohwert sichtbar,
    /// damit er korrigiert werden kann.
    private func load() {
        do {
            let storedBaseURL = try keychain.value(for: service, account: .baseURL) ?? ""
            if storedBaseURL.isEmpty {
                baseURL = ""
            } else {
                do {
                    let normalized = try ServiceConfiguration.normalizeBaseURL(storedBaseURL, for: service)
                    baseURL = normalized.absoluteString
                    // Ein Altbestand ohne `/api` (bzw. Hermes mit `/api`) wird
                    // beim Laden idempotent in die gültige Form überführt,
                    // damit Feature-Code und Einstellungen denselben Wert sehen.
                    if normalized.absoluteString != storedBaseURL {
                        try keychain.set(normalized.absoluteString, for: service, account: .baseURL)
                    }
                } catch {
                    baseURL = storedBaseURL
                    message = error.localizedDescription
                }
            }
            cloudflareClientID = try keychain.value(for: service, account: .cloudflareClientID) ?? ""
            cloudflareClientSecret = try keychain.value(for: service, account: .cloudflareClientSecret) ?? ""
            if service == .hermes {
                hermesUsername = try keychain.value(for: service, account: .username) ?? ""
                hermesPassword = try keychain.value(for: service, account: .password) ?? ""
                hermesAPIToken = try keychain.value(for: service, account: .apiToken) ?? ""
            } else if let credential = service.apiCredential {
                apiCredentialValue = try keychain.value(for: service, account: credential) ?? ""
            }
        } catch {
            message = error.localizedDescription
        }
    }

    /// Persistiert die Felder; leere Felder löschen den jeweiligen Account.
    private func save() {
        do {
            try persistFields()
            message = "Gespeichert."
        } catch {
            message = error.localizedDescription
        }
    }

    /// Normalisiert die Basis-URL und schreibt erst danach.
    ///
    /// Die Normalisierung liegt im gemeinsamen Speicherpfad, damit „Speichern“
    /// und „Test Verbindung“ dieselbe URL ablegen; eine http-Fremd-Adresse
    /// scheitert damit sichtbar bei der Eingabe (MARAAA-98) und nicht erst
    /// später als „Offline“.
    private func persistFields() throws {
        let trimmedBaseURL = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedBaseURL.isEmpty {
            try keychain.remove(for: service, account: .baseURL)
        } else {
            let normalized = try ServiceConfiguration.normalizeBaseURL(trimmedBaseURL, for: service)
            baseURL = normalized.absoluteString
            try keychain.set(normalized.absoluteString, for: service, account: .baseURL)
        }
        try persist(cloudflareClientID, account: .cloudflareClientID)
        try persist(cloudflareClientSecret, account: .cloudflareClientSecret)
        if service == .hermes {
            try persist(hermesUsername, account: .username)
            // Das Passwort wird nicht getrimmt: Leerzeichen können Teil des
            // Geheimnisses sein. Nur ein leeres Feld löscht den Eintrag.
            try persistSecret(hermesPassword, account: .password)
            // Der API-Schlüssel wird getrimmt; ein leeres Feld löscht ihn und
            // schaltet Hermes zurück auf den Password-Login.
            try persist(hermesAPIToken, account: .apiToken)
        } else if let credential = service.apiCredential {
            try persist(apiCredentialValue, account: credential)
        }
    }

    private func persist(_ value: String, account: ServiceCredential) throws {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            try keychain.remove(for: service, account: account)
        } else {
            try keychain.set(trimmed, for: service, account: account)
        }
    }

    /// Speichert einen Wert unverändert; nur ein leeres Feld löscht ihn.
    private func persistSecret(_ value: String, account: ServiceCredential) throws {
        if value.isEmpty {
            try keychain.remove(for: service, account: account)
        } else {
            try keychain.set(value, for: service, account: account)
        }
    }

    /// Fachlicher Endpunkt je Dienst; er beweist, dass Basis-URL, Zugangsdaten
    /// und CF-Access zusammenpassen — nicht nur, dass der Host antwortet.
    ///
    /// Mealie/Grocy/Dashboard laufen über die `/api`-Basis, Hermes über den
    /// Origin und trägt `/api` selbst im Pfad. Für Hermes prüft der Test
    /// `/v1/models` ohne Query: Dieser Endpunkt existiert nur auf dem
    /// API-Server (Port 8642) und beweist damit zugleich die richtige Oberfläche;
    /// das Dashboard antwortet dort mit 405 oder einer Weiterleitung.
    private var connectionTestRequest: APIRequest {
        switch service {
        case .mealie:
            return APIRequest(
                method: .get,
                path: "/recipes",
                query: [URLQueryItem(name: "perPage", value: "1")]
            )
        case .grocy:
            return APIRequest(method: .get, path: "/objects/products")
        case .dashboard:
            return APIRequest(
                method: .get,
                path: "/tasks",
                query: [URLQueryItem(name: "limit", value: "1")]
            )
        case .hermes:
            return APIRequest(method: .get, path: "/v1/models")
        }
    }

    /// Speichert die normalisierte URL und prüft danach den fachlichen
    /// Endpunkt. Erfolg ist ausschließlich 2xx **und** JSON.
    private func testConnection() async {
        isTesting = true
        defer { isTesting = false }

        guard !baseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            message = ServiceConfigurationError.missingBaseURL(service).localizedDescription
            return
        }

        do {
            try persistFields()
        } catch {
            message = error.localizedDescription
            return
        }

        do {
            let (data, response) = try await client.sendRaw(connectionTestRequest, for: service)
            message = Self.connectionMessage(
                status: response.statusCode,
                data: data,
                response: response,
                service: service
            )
        } catch {
            message = error.localizedDescription
        }
    }

    /// Übersetzt Status und Body in einen konkreten Hinweis.
    ///
    /// Reihenfolge: 401 nennt die fehlenden Zugangsdaten, 403 und eine 200-HTML-Seite
    /// kommen von Cloudflare Access, 404 heißt falscher Pfad. Der Pfad-Hinweis
    /// ist dienstspezifisch: Hermes erwartet den Origin ohne Pfad, die übrigen
    /// Dienste enden auf `/api` (MARAAA-142). Ein 302 wird nicht verfolgt und
    /// bleibt darum als `Location` sichtbar. Für Hermes benennen 405 und 3xx
    /// zusätzlich die verwechselte Oberfläche (Dashboard statt API-Server).
    private static func connectionMessage(
        status: Int,
        data: Data,
        response: HTTPURLResponse,
        service: ServiceType
    ) -> String {
        if status == 401 {
            return "Zugriff verweigert (401): \(tokenName(for: service)) fehlt oder ist ungültig."
        }
        if status == 403 {
            return "Cloudflare Access: Service-Token fehlt oder ungültig."
        }
        if status == 405, service == .hermes {
            return "Das ist das Hermes-Dashboard, nicht der API-Server: POST ist dort nicht erlaubt. Basis-URL auf den API-Server (Port 8642) setzen und API-Schlüssel eintragen."
        }
        if status == 404 {
            switch service {
            case .hermes:
                return "Pfad falsch — Hermes erwartet den Origin ohne Pfad."
            case .mealie, .grocy, .dashboard:
                return "Pfad falsch, /api prüfen."
            }
        }
        if (300..<400).contains(status) {
            if isCloudflareRedirect(response) {
                return "Cloudflare Access: Service-Token fehlt oder ungültig."
            }
            if service == .hermes {
                return "Das ist das Hermes-Dashboard (Weiterleitung auf /login). Chat braucht die API-Server-URL (Port 8642)."
            }
            return "Dienst antwortet mit Umleitung (HTTP \(status))."
        }
        if (200..<300).contains(status) {
            // Cloudflare Access liefert nach dem Redirect eine HTML-Anmeldung
            // mit Status 200; ein echter Dienst antwortet hier mit JSON.
            guard !looksLikeHTML(data, response: response) else {
                return "Cloudflare Access: Service-Token fehlt oder ungültig."
            }
            guard isJSON(data) else {
                return "Antwort nicht lesbar: kein JSON."
            }
            if service == .hermes {
                return "Verbindung erfolgreich (Hermes-API-Server)."
            }
            return "Verbindung erfolgreich."
        }
        return "Dienst antwortet mit HTTP \(status)."
    }

    private static func tokenName(for service: ServiceType) -> String {
        switch service {
        case .grocy:
            return "API-Key"
        case .hermes:
            // Der Verbindungstest fragt `/v1/models` auf dem API-Server ab;
            // dort zählt ausschließlich der API-Schlüssel. Benutzername und
            // Passwort gelten nur für den Password-Login des Dashboards.
            return "API-Schlüssel"
        case .mealie:
            return "API-Token"
        case .dashboard:
            return "Anmeldung"
        }
    }

    private static func isJSON(_ data: Data) -> Bool {
        guard !data.isEmpty else { return false }
        return (try? JSONSerialization.jsonObject(with: data)) != nil
    }

    /// Cloudflare Access liefert nach dem Redirect eine HTML-Anmeldeseite.
    private static func looksLikeHTML(_ data: Data, response: HTTPURLResponse) -> Bool {
        if let mimeType = response.mimeType?.lowercased(), mimeType.contains("html") {
            return true
        }
        guard let text = String(data: data.prefix(512), encoding: .utf8) else {
            return false
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("<")
    }

    private static func isCloudflareRedirect(_ response: HTTPURLResponse) -> Bool {
        let location = response.value(forHTTPHeaderField: "Location")?.lowercased() ?? ""
        return location.contains("cloudflareaccess.com")
    }
}
