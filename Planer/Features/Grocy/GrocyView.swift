import SwiftUI

/// Stub-Root-View von Tab 3. Gehört I5 (Einkauf/Grocy) und wird dort ersetzt.
struct GrocyView: View {
    var body: some View {
        NavigationStack {
            ContentUnavailableView(
                "Einkauf",
                systemImage: "cart",
                description: Text("Einkaufsliste und Vorrat folgen mit I5.")
            )
            .navigationTitle("Einkauf")
            .background(DesignTokens.Palette.groupedBackground)
        }
    }
}

#Preview("GrocyView") {
    GrocyView()
}
