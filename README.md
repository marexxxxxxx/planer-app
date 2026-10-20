# Planer — Hermes iOS App

Native SwiftUI-Client für den selbstgehosteten Hermes Agent (MCP), das
To-Do-Dashboard (`hermes_tasks`), Grocy und Mealie. Fünf Tabs, Secrets
ausschließlich in der Keychain, iOS 17 als Mindestziel.

Dieses Repository enthält den Stand **WP I1 — Design-System & App-Shell**.
Die Feature-Tabs sind bewusst Stubs; sie gehören den WPs I3–I6.

## Öffnen und bauen

```sh
open Planer.xcodeproj
```

- Xcode 16 oder neuer, Bundle-ID `com.marex.planer`, App-Target `Planer`.
- Das Projekt nutzt **synchronisierte Ordner** (`PBXFileSystemSynchronizedRootGroup`):
  alle Dateien unter `Planer/` werden automatisch kompiliert. Neue Dateien
  brauchen keinen Eintrag in `project.pbxproj`.
- Das Schema `Planer` legt Xcode beim ersten Öffnen automatisch an.
- `IPHONEOS_DEPLOYMENT_TARGET = 17.0`. Die `Tab`-API der Tab-Bar existiert erst
  ab iOS 18; `AppRootView` hat dafür einen Availability-Zweig mit
  `.tabItem`-Fallback. Kein Mindestziel anheben, ohne die Vorgabe zu ändern.
- Debuggen/Testen im Simulator ist nur auf einem Mac möglich.

## Struktur (I1)

```
planer-app/
├── Planer.xcodeproj/project.pbxproj   App-Target, synchronisierte Ordner
├── Config/DesignTokens.json           maschinenlesbare Token-Spiegelung
├── Planer/
│   ├── App/
│   │   ├── PlanerApp.swift            @main
│   │   ├── AppRootView.swift          TabView, 5 Tabs
│   │   ├── TabRegistry.swift          AppTab + TabDefinition + Registry
│   │   ├── SettingsTabDefinition.swift   Tab 5 → I2-SettingsView
│   │   └── Assets.xcassets/           AccentColor, AppIcon (leer)
│   ├── DesignSystem/
│   │   ├── DesignTokens.swift         Farben, Abstände, Radien, Typografie
│   │   └── Components/
│   │       ├── MessageBubbleView.swift    user | agent | toolCall
│   │       ├── SettingsRowView.swift      Label + Feld + Status-Punkt
│   │       └── UnifiedListItemView.swift  Liste für To-Dos/Einkauf/Rezepte
│   └── Features/
│       ├── Chat/    ChatView.swift, ChatTabDefinition.swift       (I3)
│       ├── Todos/   TodosView.swift, TodosTabDefinition.swift     (I4)
│       ├── Grocy/   GrocyView.swift, GrocyTabDefinition.swift     (I5)
│       └── Mealie/  MealieView.swift, MealieTabDefinition.swift   (I6)
```

`Planer/Networking/`, `Planer/Keychain/`, `Planer/Cache/` und `Planer/Settings/`
gehören I2 und werden von I1 nicht angefasst.

## Tab-Anbindung

`AppRootView` deklariert fünf Tabs mit Titel und SF-Symbol. Die **Inhalte**
kommen ausschließlich aus `TabRegistry.rootView(for:)`; jeder Case verweist auf
die `TabDefinition` seines Feature-Ordners. Ein Feature-WP ersetzt nur seine
eigene `…TabDefinition` und seine View — `AppRootView` und `TabRegistry` bleiben
unberührt.

| Tab | Label | SF Symbol | Provider | WP |
| --- | --- | --- | --- | --- |
| 1 | Chat | `bubble.left.and.bubble.right` | `ChatTabDefinition` | I3 |
| 2 | To-Dos | `checklist` | `TodosTabDefinition` | I4 |
| 3 | Einkauf | `cart` | `GrocyTabDefinition` | I5 |
| 4 | Rezepte | `fork.knife` | `MealieTabDefinition` | I6 |
| 5 | Einstellungen | `gearshape` | `SettingsTabDefinition` | I2 |

**Übergabe an I2:** `SettingsTabDefinition` (in `Planer/App/`) verweist auf
`SettingsView` aus `Planer/Settings/`. `PlanerApp.swift` injiziert den
`ModelContainer` aus `Planer/Cache/ModelContainer.swift`. Beide Dateien kommen
von I2 und sind damit Voraussetzung für einen Build; die vier I2-Ordner selbst
fasst I1 nicht an.

## Design-Tokens

`DesignTokens.swift` ist die Quelle, `Config/DesignTokens.json` die
maschinenlesbare Spiegelung derselben Werte. Beide werden **nur gemeinsam**
geändert. Farben sind iOS-Systemfarben (Light/Dark automatisch); der Akzent ist
ein Platzhalter in `Assets.xcassets/AccentColor.colorset` und im JSON vermerkt.

## Statische Abnahme I1

Ohne Swift-Toolchain prüfbar:

```sh
grep -c 'Tab(' Planer/App/AppRootView.swift          # erwartet: 5
for s in bubble.left.and.bubble.right checklist cart fork.knife gearshape; do
  grep -q "$s" Planer/App/AppRootView.swift && echo "OK  $s" || echo "FEHLT $s"
done
```

Kompilierung, Rendering und Light/Dark-Darstellung sind **nur auf Mac prüfbar**
und nicht Teil des binären Kriteriums.

## Konventionen

- Keine Secrets im Repo: Tokens und Cloudflare-Zugänge liegen in der Keychain.
- Keine `UserDefaults`-Ablage von Secrets (Kriterium I2).
- Neue Dateien unter `Planer/` werden durch die synchronisierten Ordner
  automatisch Teil des Targets; keine pbxproj-Pflege nötig.
