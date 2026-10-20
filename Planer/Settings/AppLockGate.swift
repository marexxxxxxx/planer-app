//
//  AppLockGate.swift
//  Planer
//
//  Sperr-Gate vor dem App-Inhalt (spec-ios §4/§5, AD-6).
//

import LocalAuthentication
import SwiftUI

/// Wertet den App-Lock-Schalter aus und legt sich vor den App-Inhalt.
///
/// Zweck: verlangt beim Start und nach jedem Hintergrundwechsel Face ID/Touch ID
/// bzw. den Gerätecode, solange `appLockEnabled` gesetzt ist; bis zur erfolgreichen
/// Prüfung zeigt die App nur den Sperrbildschirm statt der Tabs.
/// Grenze: schützt ausschließlich die Oberfläche. Es gibt kein zusätzliches Secret
/// und keine eigene PIN — die Prüfung liefert `LocalAuthentication`, der Schalter
/// selbst liegt als nicht geheimer Bool in `UserDefaults` (AD-6).
struct AppLockGate<Content: View>: View {
    @AppStorage("appLockEnabled") private var appLockEnabled = false
    @Environment(\.scenePhase) private var scenePhase

    @State private var isUnlocked = false
    @State private var isAuthenticating = false
    @State private var message: String?

    private let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        Group {
            if appLockEnabled && !isUnlocked {
                lockedView
            } else {
                content
            }
        }
        .task {
            await unlockIfNeeded()
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .background:
                // Beim Verlassen sperren, damit der nächste Vordergrund wieder
                // eine Prüfung verlangt.
                isUnlocked = false
                message = nil
            case .active:
                Task { await unlockIfNeeded() }
            default:
                break
            }
        }
        .onChange(of: appLockEnabled) { _, enabled in
            // Das Einschalten läuft über `AppLockSection` und hat den Gerätecode
            // in diesem Moment bereits geprüft; ein zweiter Dialog wäre nur eine
            // Doppelabfrage. Beim Ausschalten ist ohnehin nichts zu halten.
            isUnlocked = enabled
            message = nil
        }
    }

    private var lockedView: some View {
        VStack(spacing: DesignTokens.Spacing.l) {
            Image(systemName: "lock.fill")
                .font(.system(size: 44))
                .foregroundStyle(DesignTokens.Palette.secondaryLabel)

            Text("Planer ist gesperrt")
                .font(DesignTokens.Typography.headline)

            if let message {
                Text(message)
                    .font(DesignTokens.Typography.footnote)
                    .foregroundStyle(DesignTokens.Palette.secondaryLabel)
                    .multilineTextAlignment(.center)
            }

            Button {
                Task { await authenticate() }
            } label: {
                if isAuthenticating {
                    ProgressView()
                } else {
                    Text("Mit Face ID / Touch ID entsperren")
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(isAuthenticating)
        }
        .padding(DesignTokens.Spacing.xl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(DesignTokens.Palette.groupedBackground.ignoresSafeArea())
    }

    /// Fragt nur, wenn die Sperre aktiv und noch nicht entsperrt ist.
    private func unlockIfNeeded() async {
        guard appLockEnabled, !isUnlocked else { return }
        await authenticate()
    }

    /// Prüft Biometrie bzw. Gerätecode; bei Abbruch bleibt die App gesperrt.
    private func authenticate() async {
        guard !isAuthenticating else { return }
        isAuthenticating = true
        defer { isAuthenticating = false }

        let context = LAContext()
        var evaluationError: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &evaluationError) else {
            let reason = evaluationError?.localizedDescription ?? "nicht verfügbar"
            message = "Entsperren nicht möglich: \(reason)"
            return
        }

        do {
            let success = try await context.evaluatePolicy(
                .deviceOwnerAuthentication,
                localizedReason: "Planer entsperren"
            )
            isUnlocked = success
            message = success ? nil : "Entsperren nicht bestätigt."
        } catch {
            message = "Entsperren nicht möglich: \(error.localizedDescription)"
        }
    }
}
