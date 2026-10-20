//
//  ServiceSettingsSection.swift
//  Planer
//
//  URL/Token/CF-Access je Dienst + „Test Verbindung“ (spec-ios §5).
//

import SwiftUI

/// Einstellungs-Sektion eines einzelnen Dienstes.
///
/// Zweck: Basis-URL, CF-Access-Paar und den dienstspezifischen API-Account
/// erfassen und ausschließlich über `KeychainManager` speichern.
/// Grenze: keine Validierung der fachlichen API und keine Anzeige von
/// Server-Daten; „Test Verbindung“ prüft nur die Erreichbarkeit der Basis-URL.
struct ServiceSettingsSection: View {
    let service: ServiceType

    private let keychain = KeychainManager()
    private let client = NetworkClient()

    @State private var baseURL = ""
    @State private var cloudflareClientID = ""
    @State private var cloudflareClientSecret = ""
    @State private var apiCredentialValue = ""
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

            TextField("CF-Access-Client-ID", text: $cloudflareClientID)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()

            SecureField("CF-Access-Client-Secret", text: $cloudflareClientSecret)

            if let credential = service.apiCredential {
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

    /// Liest die gespeicherten Werte in die Eingabefelder.
    private func load() {
        do {
            baseURL = try keychain.value(for: service, account: .baseURL) ?? ""
            cloudflareClientID = try keychain.value(for: service, account: .cloudflareClientID) ?? ""
            cloudflareClientSecret = try keychain.value(for: service, account: .cloudflareClientSecret) ?? ""
            if let credential = service.apiCredential {
                apiCredentialValue = try keychain.value(for: service, account: credential) ?? ""
            }
        } catch {
            message = error.localizedDescription
        }
    }

    /// Persistiert die Felder; leere Felder löschen den jeweiligen Account.
    ///
    /// Die Basis-URL wird vor jedem Persistieren gegen die Transport-Regel aus
    /// `ServiceConfiguration` geprüft, damit eine http-Fremd-Adresse als
    /// sichtbarer Fehler endet und nicht erst später als „Offline“ auffällt.
    private func save() {
        do {
            try persistFields()
            message = "Gespeichert."
        } catch {
            message = error.localizedDescription
        }
    }

    private func persistFields() throws {
        let trimmedBaseURL = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedBaseURL.isEmpty {
            _ = try ServiceConfiguration.validateBaseURL(trimmedBaseURL, for: service)
        }
        try persist(baseURL, account: .baseURL)
        try persist(cloudflareClientID, account: .cloudflareClientID)
        try persist(cloudflareClientSecret, account: .cloudflareClientSecret)
        if let credential = service.apiCredential {
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

    /// Prüft die Erreichbarkeit über den `NetworkClient` (damit die Header-Injektion
    /// genau einmal existiert); ein HTTP-Status ungleich 2xx gilt als erreichbar.
    private func testConnection() async {
        isTesting = true
        defer { isTesting = false }

        do {
            try persistFields()
        } catch {
            message = error.localizedDescription
            return
        }

        do {
            _ = try await client.send(APIRequest(method: .get, path: ""), for: service)
            message = "Verbindung erfolgreich."
        } catch let error as APIError {
            if let status = error.httpStatus {
                switch status {
                case 401, 403:
                    message = "Dienst erreichbar, Zugriff verweigert (HTTP \(status))."
                default:
                    message = "Dienst erreichbar (HTTP \(status))."
                }
            } else {
                message = error.localizedDescription
            }
        } catch {
            message = error.localizedDescription
        }
    }
}
