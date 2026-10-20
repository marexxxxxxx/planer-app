import SwiftData
import SwiftUI

/// Einstiegspunkt der App: injiziert den SwiftData-Container aus I2 und zeigt die
/// fünf Tabs hinter dem App-Lock-Gate aus `AppLockGate` (spec-ios §5).
@main
struct PlanerApp: App {

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
            AppLockGate {
                AppRootView()
            }
        }
        .modelContainer(modelContainer)
    }
}
