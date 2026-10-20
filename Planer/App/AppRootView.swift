import SwiftUI

/// Wurzel der App: genau fünf Tabs.
///
/// Tab-Inhalte kommen ausschließlich aus `TabRegistry`; Titel und SF-Symbole
/// stehen hier, weil die statische Abnahme des WP I1 sie wörtlich in dieser Datei
/// prüft. Die Vorgabe nennt iOS 17 als Minimum, die `Tab`-API gibt es erst ab
/// iOS 18 — deshalb der Availability-Zweig statt einer Anhebung des Mindestziels.
struct AppRootView: View {

    @State private var selection: AppTab = .chat

    var body: some View {
        if #available(iOS 18.0, *) {
            modernTabs
        } else {
            legacyTabs
        }
    }

    @available(iOS 18.0, *)
    private var modernTabs: some View {
        TabView(selection: $selection) {
            Tab("Chat", systemImage: "bubble.left.and.bubble.right", value: AppTab.chat) {
                TabRegistry.rootView(for: .chat)
            }
            Tab("To-Dos", systemImage: "checklist", value: AppTab.todos) {
                TabRegistry.rootView(for: .todos)
            }
            Tab("Einkauf", systemImage: "cart", value: AppTab.grocery) {
                TabRegistry.rootView(for: .grocery)
            }
            Tab("Rezepte", systemImage: "fork.knife", value: AppTab.recipes) {
                TabRegistry.rootView(for: .recipes)
            }
            Tab("Einstellungen", systemImage: "gearshape", value: AppTab.settings) {
                TabRegistry.rootView(for: .settings)
            }
        }
    }

    private var legacyTabs: some View {
        TabView(selection: $selection) {
            TabRegistry.rootView(for: .chat)
                .tabItem { Label("Chat", systemImage: "bubble.left.and.bubble.right") }
                .tag(AppTab.chat)

            TabRegistry.rootView(for: .todos)
                .tabItem { Label("To-Dos", systemImage: "checklist") }
                .tag(AppTab.todos)

            TabRegistry.rootView(for: .grocery)
                .tabItem { Label("Einkauf", systemImage: "cart") }
                .tag(AppTab.grocery)

            TabRegistry.rootView(for: .recipes)
                .tabItem { Label("Rezepte", systemImage: "fork.knife") }
                .tag(AppTab.recipes)

            TabRegistry.rootView(for: .settings)
                .tabItem { Label("Einstellungen", systemImage: "gearshape") }
                .tag(AppTab.settings)
        }
    }
}

#Preview("AppRootView") {
    AppRootView()
}
