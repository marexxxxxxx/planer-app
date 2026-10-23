//
//  TabVisibilityPreferences.swift
//  Planer
//
//  Ausgeblendete Tabs der unteren Leiste (MARAAA-190).
//

import SwiftUI

/// Einzige Quelle dafür, welche Tabs die untere Leiste zeigt.
///
/// Zweck: die Wahl aus den Einstellungen dauerhaft in `UserDefaults` halten und
/// `AppRootView` dieselbe Liste lesen lassen. Ein flüchtiger `@State` würde den
/// Neustart nicht überleben.
/// Grenze: Chat und Einstellungen sind nicht abwählbar (`AppTab.isHideable`);
/// fremde oder veraltete Rohwerte im Speicher werden beim Lesen verworfen.
@MainActor
final class TabVisibilityPreferences: ObservableObject {

    static let shared = TabVisibilityPreferences()

    static let key = "hiddenAppTabs"

    /// Nur abwählbare Tabs; Chat und Einstellungen können hier nie stehen.
    @Published private(set) var hiddenTabs: Set<AppTab>

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let stored = defaults.stringArray(forKey: Self.key) ?? []
        self.hiddenTabs = Set(
            stored.compactMap(AppTab.init(rawValue:)).filter(\.isHideable)
        )
    }

    /// Verbindliche Reihenfolge für die Leiste; leer ist nie möglich, weil
    /// Chat und Einstellungen immer sichtbar bleiben.
    var visibleTabs: [AppTab] {
        AppTab.allCases.filter { !hiddenTabs.contains($0) }
    }

    func isVisible(_ tab: AppTab) -> Bool {
        !hiddenTabs.contains(tab)
    }

    /// Schreibt die Auswahl; ein nicht abwählbarer Tab bleibt unverändert.
    func setVisible(_ visible: Bool, for tab: AppTab) {
        guard tab.isHideable else { return }

        var next = hiddenTabs
        if visible {
            next.remove(tab)
        } else {
            next.insert(tab)
        }
        guard next != hiddenTabs else { return }

        hiddenTabs = next
        defaults.set(next.map(\.rawValue).sorted(), forKey: Self.key)
    }
}
