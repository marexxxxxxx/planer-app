import SwiftUI

/// Identität der fünf Wurzeltabs. Die Reihenfolge der Cases ist die verbindliche
/// Tab-Bar-Reihenfolge aus der Design-Vorgabe; der Rohwert ist der Schlüssel,
/// unter dem `TabVisibilityPreferences` ausgeblendete Tabs speichert.
enum AppTab: String, CaseIterable, Hashable {
    case chat
    case todos
    case grocery
    case recipes
    case settings

    var title: String {
        switch self {
        case .chat: return "Chat"
        case .todos: return "To-Dos"
        case .grocery: return "Einkauf"
        case .recipes: return "Rezepte"
        case .settings: return "Einstellungen"
        }
    }

    var systemImage: String {
        switch self {
        case .chat: return "bubble.left.and.bubble.right"
        case .todos: return "checklist"
        case .grocery: return "cart"
        case .recipes: return "fork.knife"
        case .settings: return "gearshape"
        }
    }

    /// Chat und Einstellungen sind der Rückweg in die Einstellungen — ohne sie
    /// wäre ein ausgeblendeter Tab nicht wieder einblendbar.
    var isHideable: Bool {
        switch self {
        case .todos, .grocery, .recipes: return true
        case .chat, .settings: return false
        }
    }

    /// Nur die abwählbaren Tabs, in Tab-Bar-Reihenfolge; Quelle der Schalter
    /// in `TabBarSettingsSection`.
    static var hideableTabs: [AppTab] {
        allCases.filter(\.isHideable)
    }
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
