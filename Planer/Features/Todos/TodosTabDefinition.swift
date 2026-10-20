import SwiftUI

/// Stub-Tab-Provider für To-Dos. Gehört I4 und wird dort ersetzt.
enum TodosTabDefinition: TabDefinition {
    static func makeRootView() -> some View {
        TodosView()
    }
}
