//
//  AppLockSection.swift
//  Planer
//
//  App-Sperre über LocalAuthentication (spec-ios §4, AD-6).
//

import LocalAuthentication
import SwiftUI

/// Sektion „Allgemein & Sicherheit“ mit dem App-Sperr-Schalter.
///
/// Zweck: aktiviert die Sperre über Face ID/Touch ID und schaltet sie nur frei,
/// wenn die Biometrie bzw. der Gerätecode erfolgreich geprüft wurde.
/// Grenze: legt kein Secret ab und schützt nur die App-Oberfläche; der Schalter
/// selbst ist nicht geheim (`appLockEnabled` in `UserDefaults`, AD-6).
struct AppLockSection: View {
    @AppStorage("appLockEnabled") private var appLockEnabled = false
    @State private var message: String?

    var body: some View {
        Section {
            Toggle("App-Sperre (Face ID / Touch ID)", isOn: $appLockEnabled)
                .onChange(of: appLockEnabled) { _, enabled in
                    guard enabled else {
                        message = nil
                        return
                    }
                    Task { await verifyOwner() }
                }

            if let message {
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Allgemein & Sicherheit")
        } footer: {
            Text("Die Sperre nutzt Face ID/Touch ID über die Secure Enclave; es wird kein Passwort gespeichert.")
        }
    }

    /// Prüft Biometrie bzw. Gerätecode und nimmt den Schalter bei Misserfolg zurück.
    private func verifyOwner() async {
        let context = LAContext()
        var evaluationError: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &evaluationError) else {
            appLockEnabled = false
            let reason = evaluationError?.localizedDescription ?? "nicht verfügbar"
            message = "App-Sperre nicht möglich: \(reason)"
            return
        }

        do {
            let success = try await context.evaluatePolicy(
                .deviceOwnerAuthentication,
                localizedReason: "App-Sperre aktivieren"
            )
            appLockEnabled = success
            message = success ? "App-Sperre aktiv." : "App-Sperre nicht aktiviert."
        } catch {
            appLockEnabled = false
            message = "App-Sperre nicht aktiviert: \(error.localizedDescription)"
        }
    }
}
