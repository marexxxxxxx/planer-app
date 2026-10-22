import LocalAuthentication
import SwiftData
import SwiftUI

/// Einstiegspunkt der App: injiziert den SwiftData-Container aus I2 und legt die
/// fünf Tabs hinter das App-Lock-Gate (spec-ios §4/§5, AD-6).
///
/// Das Gate sitzt bewusst im Einstiegspunkt: er ist die einzige Stelle, die den
/// App-Inhalt umschließt, und `scenePhase` steht hier ohnehin zur Verfügung.
/// Bis zur erfolgreichen `LocalAuthentication`-Prüfung wird `AppRootView` gar
/// nicht erst erzeugt; beim Wechsel in den Hintergrund fällt die Sperre zurück.
@main
struct PlanerApp: App {

    /// Derselbe `UserDefaults`-Schlüssel, den `AppLockSection` setzt.
    @AppStorage("appLockEnabled") private var appLockEnabled = false
    @Environment(\.scenePhase) private var scenePhase

    @State private var isUnlocked = false
    @State private var isAuthenticating = false
    @State private var lockMessage: String?

    /// Eine Sprachschicht für alle Tabs (spec-voice §6): erzeugt hier, per
    /// `.environmentObject` an `AppRootView` und damit an Chat und To-Dos.
    @StateObject private var voiceCoordinator = VoiceCoordinator()

    /// Die einzige Anwendung des Erscheinungsbilds (spec-chat Rev 6 O6).
    @StateObject private var appearance = AppearancePreferences.shared

    private let modelContainer: ModelContainer

    init() {
        do {
            modelContainer = try PlanerModelContainer.make()
        } catch {
            // Ohne Container hätte jeder Tab einen leeren, nicht speicherbaren
            // Cache — das ist ein Konfigurationsfehler, kein Laufzeitzustand,
            // den die App verdecken dürfte.
            fatalError("SwiftData-Container konnte nicht erstellt werden: \(error)")
        }
    }

    var body: some Scene {
        WindowGroup {
            Group {
                if appLockEnabled && !isUnlocked {
                    lockScreen
                } else {
                    AppRootView()
                }
            }
            .preferredColorScheme(appearance.colorScheme)
            .environmentObject(voiceCoordinator)
            .task {
                await unlockIfNeeded()
            }
            .onChange(of: scenePhase) { _, phase in
                // §8.3: freihändig nur im Vordergrund — Hintergrund beendet
                // Aufnahme und Ausgabe; `.active` startet nichts von selbst.
                voiceCoordinator.handleScenePhase(phase)
                switch phase {
                case .background:
                    // Beim Verlassen sperren, damit der nächste Vordergrund
                    // wieder eine Prüfung verlangt.
                    isUnlocked = false
                    lockMessage = nil
                case .active:
                    Task { await unlockIfNeeded() }
                default:
                    break
                }
            }
            .onChange(of: appLockEnabled) { _, enabled in
                // Das Einschalten prüft `AppLockSection` bereits; ein zweiter
                // Dialog direkt danach wäre eine Doppelabfrage.
                isUnlocked = enabled
                lockMessage = nil
            }
        }
        .modelContainer(modelContainer)
    }

    /// Sperr-Oberfläche, solange die Prüfung nicht erfolgreich war.
    private var lockScreen: some View {
        VStack(spacing: DesignTokens.Spacing.l) {
            Image(systemName: "lock.fill")
                .font(.system(size: 44))
                .foregroundStyle(DesignTokens.Palette.secondaryLabel)

            Text("Planer ist gesperrt")
                .font(DesignTokens.Typography.headline)

            if let lockMessage {
                Text(lockMessage)
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
    @MainActor
    private func unlockIfNeeded() async {
        guard appLockEnabled, !isUnlocked else { return }
        await authenticate()
    }

    /// Prüft Biometrie bzw. Gerätecode; bei Abbruch bleibt die App gesperrt.
    @MainActor
    private func authenticate() async {
        guard !isAuthenticating else { return }
        isAuthenticating = true
        defer { isAuthenticating = false }

        let context = LAContext()
        var evaluationError: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &evaluationError) else {
            let reason = evaluationError?.localizedDescription ?? "nicht verfügbar"
            lockMessage = "Entsperren nicht möglich: \(reason)"
            return
        }

        do {
            let success = try await context.evaluatePolicy(
                .deviceOwnerAuthentication,
                localizedReason: "Planer entsperren"
            )
            isUnlocked = success
            lockMessage = success ? nil : "Entsperren nicht bestätigt."
        } catch {
            lockMessage = "Entsperren nicht möglich: \(error.localizedDescription)"
        }
    }
}
