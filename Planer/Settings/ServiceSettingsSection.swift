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
/// Grenze: keine Anzeige von Server-Daten; „Test Verbindung“ ruft je Dienst
/// einen fachlichen Endpunkt ab und unterscheidet Erfolg, Token-Fehler,
/// Cloudflare Access und falschen Pfad. Nur Hermes fragt bei einem
/// nicht verwertbaren Ergebnis zusätzlich `/api/status` ab (Dashboard-Diagnose).
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
    /// das Dashboard antwortet dort mit 405 oder einer Weiterleitung. Scheitert
    /// der Schritt, fragt `testConnection` für Hermes zusätzlich `/api/status`
    /// ab und nennt die dort gemeldete API-Server-Adresse (MARAAA-159).
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
    ///
    /// Hermes hat einen eigenen Pfad: `/v1/models` endet am Dashboard mit 3xx,
    /// 2xx-HTML oder 401, und der Client wirft beim Redirect/Re-Login. Darum
    /// fängt `testHermesConnection` den Fehler lokal ab; `connectionMessage`
    /// ist dort nur noch Rückfall, nicht Endstation.
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

        if service == .hermes {
            await testHermesConnection()
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

    /// Verbindungstest für Hermes: erst `/v1/models`, bei Bedarf `/api/status`.
    ///
    /// Zweck: Am Dashboard antwortet `/v1/models` mit 302, 2xx-HTML oder 401;
    /// ein geworfener Fehler würde die Meldung sonst durch „Hermes-Anmeldung
    /// erforderlich“ ersetzen, obwohl die Ursache die verwechselte Oberfläche
    /// ist. Der erste Request wird darum lokal abgefangen. Erfolg ist nur 2xx
    /// **und** JSON, das nach API-Server aussieht; 401 `gateway_auth_failed`
    /// und 403 behalten ihre bestehenden Meldungen.
    /// Grenze: Alle übrigen Fälle fragen `/api/status`; eine verwertbare
    /// Antwort setzt **eine** endgültige Meldung und ersetzt die erste. Ist
    /// `/api/status` nicht verwertbar, bleibt die Meldung aus
    /// `connectionMessage` bzw. der Transportfehler erhalten.
    private func testHermesConnection() async {
        var status: Int?
        var responseBody = Data()
        var response: HTTPURLResponse?
        var transportError: Error?
        do {
            let result = try await client.sendRaw(connectionTestRequest, for: service)
            status = result.response.statusCode
            responseBody = result.data
            response = result.response
        } catch {
            transportError = error
        }

        if let status, (200..<300).contains(status), Self.isHermesAPIServerPayload(responseBody) {
            message = "Verbindung erfolgreich (Hermes-API-Server)."
            return
        }
        if let status, status == 401, Self.isGatewayAuthFailure(responseBody) {
            // Der API-Server ist erreichbar, aber der Schlüssel fehlt oder ist
            // falsch; dieselbe Meldung wie im Chat-Pfad (APIError).
            message = APIError.hermesAPIServerKeyRequired.localizedDescription
            return
        }
        if let status, let response, status == 403 {
            // Cloudflare Access antwortet vor jedem Dienst; diese Meldung wird
            // nicht von der Dashboard-Diagnose verdrängt.
            message = Self.connectionMessage(
                status: status,
                data: responseBody,
                response: response,
                service: service
            )
            return
        }

        if let diagnosis = await hermesDashboardDiagnosis() {
            message = diagnosis
            return
        }
        if let status, let response {
            message = Self.connectionMessage(
                status: status,
                data: responseBody,
                response: response,
                service: service
            )
        } else {
            message = transportError?.localizedDescription
                ?? "Hermes antwortet nicht und der Dashboard-Status ist nicht lesbar."
        }
    }

    /// Fragt den Dashboard-Status ab und formuliert daraus eine Meldung.
    ///
    /// Zweck: `GET /api/status` existiert nur auf dem Dashboard; seine Antwort
    /// nennt `gateway_platforms.api_server` mit Zustand und `listener_base`.
    /// Damit wird aus „404/405/3xx/Transportfehler“ eine Handlungsanweisung.
    /// Grenze: Die Antwort muss 2xx und dekodierbares JSON sein; alles andere
    /// ergibt `nil`, damit die erste Meldung erhalten bleibt.
    private func hermesDashboardDiagnosis() async -> String? {
        let request = APIRequest(method: .get, path: "/api/status")
        guard let (data, response) = try? await client.sendRaw(request, for: .hermes),
              (200..<300).contains(response.statusCode),
              let dashboard = try? JSONDecoder().decode(HermesDashboardStatus.self, from: data)
        else {
            return nil
        }
        // `classify` bekommt hier bewusst keinen `/v1/models`-Status: Der
        // Aufrufer hat bereits entschieden, dass die erste Antwort kein
        // API-Server-JSON war. Eine dekodierte Statusantwort ist das Dashboard.
        guard case .dashboard(let state, let listenerBase, _, _) =
                HermesSurface.classify(v1ModelsStatus: nil, dashboard: dashboard)
        else {
            return nil
        }
        // `{}` dekodiert erfolgreich, sagt aber nichts über das Dashboard aus.
        // Ohne mindestens ein bekanntes Feld bleibt die erste Meldung stehen.
        guard dashboard.gatewayPlatforms != nil || dashboard.gatewayRunning != nil else {
            return nil
        }
        return Self.dashboardMessage(state: state, listenerBase: listenerBase)
    }

    /// Formuliert die Diagnose für eine erreichte Dashboard-Oberfläche.
    ///
    /// Zweck: nennt Zustand und gemeldete `listener_base` des API-Servers und
    /// daraus den nächsten Schritt — gemeinsame HTTPS-Adresse über hermes-front,
    /// HTTPS-Terminierung bei Bindungsadresse oder direktes Eintragen einer
    /// konkreten Adresse.
    /// Grenze: reine Textbildung aus dem Status; `0.0.0.0` und `http://` werden
    /// nie als Basis-URL angeboten, weil die App sie nicht verbinden kann
    /// (MARAAA-98). Ein fehlender Zustand wird nicht als „nicht verbunden“
    /// behauptet.
    private static func dashboardMessage(state: String?, listenerBase: String?) -> String {
        let trimmedState = state?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let normalizedState = trimmedState.lowercased()
        guard !normalizedState.isEmpty else {
            return "Das Hermes-Dashboard antwortet, meldet aber keinen Zustand des API-Servers. Prüfe, ob die api_server-Plattform aktiv ist."
        }
        guard normalizedState == "connected" else {
            return "Das Hermes-Dashboard antwortet, aber der API-Server ist nicht verbunden (state: \(trimmedState)). Starte ihn und prüfe API_SERVER_HOST und API_SERVER_KEY."
        }
        guard let listenerBase = listenerBase?.trimmingCharacters(in: .whitespacesAndNewlines),
              !listenerBase.isEmpty
        else {
            return "Das ist das Hermes-Dashboard. Der Status meldet keine Adresse des API-Servers. Prüfe API_SERVER_HOST und API_SERVER_PORT."
        }
        switch HermesSurface.listenerScope(listenerBase) {
        case .loopback:
            return "Das ist das Hermes-Dashboard. Der API-Server läuft laut Status auf \(listenerBase) und ist nur auf dem Server selbst erreichbar. Die App braucht eine gemeinsame HTTPS-Adresse (hermes-front hinter dem Tunnel); Einzelheiten in docs/hermes-405-diagnose.md."
        case .allInterfaces:
            return "Das ist das Hermes-Dashboard. Der API-Server lauscht laut Status auf allen Interfaces (\(listenerBase)). Die App braucht davor eine HTTPS-Adresse (Reverse Proxy oder Tunnel) und den API-Schlüssel."
        case .other:
            return "Das ist das Hermes-Dashboard. Der API-Server läuft laut Status auf \(listenerBase). Die App braucht diese Adresse als HTTPS-Basis-URL — bei http:// zuerst TLS-Terminierung einrichten — und den API-Schlüssel."
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

    /// Prüft, ob der Body nach dem Hermes-API-Server aussieht.
    ///
    /// Zweck: Das Dashboard beantwortet `/v1/models` mit 200 und HTML
    /// (SPA-Catch-all). Nur ein JSON-Objekt mit `object` oder `data` beweist
    /// den API-Server; alles andere führt zur `/api/status`-Diagnose.
    /// Grenze: keine Schema-Validierung über die beiden Top-Level-Schlüssel
    /// hinaus.
    private static func isHermesAPIServerPayload(_ data: Data) -> Bool {
        guard let raw = try? JSONSerialization.jsonObject(with: data),
              let object = raw as? [String: Any]
        else {
            return false
        }
        return object["object"] != nil || object["data"] != nil
    }

    /// Erkennt die 401-Antwort des Hermes-API-Servers (`gateway_auth_failed`).
    ///
    /// Grenze: liest nur den Fehlercode; die Meldung bleibt unabhängig vom
    /// Servertext stabil.
    private static func isGatewayAuthFailure(_ data: Data) -> Bool {
        guard let text = String(data: data, encoding: .utf8) else { return false }
        return text.contains("gateway_auth_failed")
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
