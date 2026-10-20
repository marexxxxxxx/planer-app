import SwiftUI

/// Identität der fünf Wurzeltabs. Die Reihenfolge der Cases ist die verbindliche
/// Tab-Bar-Reihenfolge aus der Design-Vorgabe; `Hashable` braucht die `Tab`-API.
enum AppTab: Hashable {
    case chat
    case todos
    case grocery
    case recipes
    case settings
}

/// Vertrag, den jedes Feature-WP für seinen Tab erfüllt. Ein Feature tauscht nur
/// seine eigene `…TabDefinition` aus; I1-Dateien bleiben unberührt.
protocol TabDefinition {
    associatedtype RootView: View

    @ViewBuilder
    static func makeRootView() -> RootView
}

/// Einzige Stelle, an der `AppRootView` Tab-Inhalte bezieht.
///
/// Das `switch` ist bewusst vollständig: ein neuer Case in `AppTab` bricht die
/// Kompilierung, statt zur Laufzeit einen leeren Tab zu zeigen.
enum TabRegistry {

    @ViewBuilder
    static func rootView(for tab: AppTab) -> some View {
        switch tab {
        case .chat:
            ChatTabDefinition.makeRootView()
        case .todos:
            TodosTabDefinition.makeRootView()
        case .grocery:
            GrocyTabDefinition.makeRootView()
        case .recipes:
            MealieTabDefinition.makeRootView()
        case .settings:
            SettingsTabDefinition.makeRootView()
        }
    }
}
