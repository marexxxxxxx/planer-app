import SwiftUI

/// Stub-Root-View von Tab 2. Gehört I4 (To-Dos gegen `worldplaner` /api/tasks)
/// und wird dort ersetzt.
struct TodosView: View {
    var body: some View {
        NavigationStack {
            ContentUnavailableView(
                "To-Dos",
                systemImage: "checklist",
                description: Text("Liste, Filter und Swipe folgen mit I4.")
            )
            .navigationTitle("To-Dos")
            .background(DesignTokens.Palette.groupedBackground)
        }
    }
}

#Preview("TodosView") {
    TodosView()
}
