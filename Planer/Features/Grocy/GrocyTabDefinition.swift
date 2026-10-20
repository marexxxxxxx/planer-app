import SwiftUI

/// Tab-Provider für Einkauf (I5): liefert die Einkaufs-/Vorrats-Ansicht.
enum GrocyTabDefinition: TabDefinition {
    static func makeRootView() -> some View {
        GrocyView()
    }
}
