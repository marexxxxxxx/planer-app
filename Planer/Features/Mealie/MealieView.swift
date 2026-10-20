import SwiftUI

/// Stub-Root-View von Tab 4. Gehört I6 (Rezepte/Mealie) und wird dort ersetzt.
struct MealieView: View {
    var body: some View {
        NavigationStack {
            ContentUnavailableView(
                "Rezepte",
                systemImage: "fork.knife",
                description: Text("Wochenplan und Rezeptbibliothek folgen mit I6.")
            )
            .navigationTitle("Rezepte")
            .background(DesignTokens.Palette.groupedBackground)
        }
    }
}

#Preview("MealieView") {
    MealieView()
}
