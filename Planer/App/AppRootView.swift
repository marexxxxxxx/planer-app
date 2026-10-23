import SwiftUI

/// Wurzel der App: bis zu fünf Tabs, mindestens Chat und Einstellungen.
///
/// Tab-Inhalte kommen ausschließlich aus `TabRegistry`; Titel und SF-Symbole
/// stehen an `AppTab`, weil beide Tab-Bar-Zweige und die Einstellungen sie
/// brauchen. Die Vorgabe nennt iOS 17 als Minimum, die `Tab`-API gibt es erst ab
/// iOS 18 — deshalb der Availability-Zweig statt einer Anhebung des Mindestziels.
///
/// Welche Tabs sichtbar sind, entscheidet `TabVisibilityPreferences`; beide
/// Zweige rendern dieselbe Liste `visibleTabs`, damit ein ausgeblendeter Tab
/// nicht in einem der Zweige stehen bleibt.
struct AppRootView: View {

    @State private var selection: AppTab = .chat

    @ObservedObject private var tabVisibility = TabVisibilityPreferences.shared

    var body: some View {
        Group {
            if #available(iOS 18.0, *) {
                modernTabs
            } else {
                legacyTabs
            }
        }
        .onAppear(perform: reconcileSelection)
        .onChange(of: tabVisibility.hiddenTabs) { _, _ in
            reconcileSelection()
        }
    }

    /// Ein ausgeblendeter Tab darf nicht ausgewählt bleiben: sonst bliebe der
    /// Bildschirm leer und die Leiste hätte keinen aktiven Eintrag. Chat ist
    /// nicht abwählbar und deshalb immer ein gültiges Ziel.
    private func reconcileSelection() {
        guard !tabVisibility.isVisible(selection) else { return }
        selection = .chat
    }

    @available(iOS 18.0, *)
    private var modernTabs: some View {
        TabView(selection: $selection) {
            ForEach(tabVisibility.visibleTabs, id: \.self) { tab in
                Tab(value: tab) {
                    TabRegistry.rootView(for: tab)
                } label: {
                    Label(tab.title, systemImage: tab.systemImage)
                }
            }
        }
    }

    private var legacyTabs: some View {
        TabView(selection: $selection) {
            ForEach(tabVisibility.visibleTabs, id: \.self) { tab in
                TabRegistry.rootView(for: tab)
                    .tabItem { Label(tab.title, systemImage: tab.systemImage) }
                    .tag(tab)
            }
        }
    }
}

#Preview("AppRootView") {
    AppRootView()
}
