# Planer — Hermes iOS App

Native SwiftUI-Client für den selbstgehosteten Hermes Agent (MCP), das
To-Do-Dashboard (`hermes_tasks`), Grocy und Mealie. Fünf Tabs, Secrets
ausschließlich in der Keychain, iOS 17 als Mindestziel.

Dieses Repository enthält den Stand der WPs **I1–I6**: Design-System und
App-Shell (I1), Einstellungen und App-Lock (I2), Chat (I3), To-Dos (I4),
Einkauf (I5) und Rezepte (I6). Alle fünf Tabs sind implementiert.

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
- Das App-Icon liegt als einzelnes 1024×1024-PNG in
  `Planer/App/Assets.xcassets/AppIcon.appiconset/`; Xcode skaliert es für die
  übrigen Größen und übernimmt die Maskierung.

## Struktur

```
planer-app/
├── Planer.xcodeproj/project.pbxproj   App-Target, synchronisierte Ordner
├── Config/DesignTokens.json           maschinenlesbare Token-Spiegelung
├── Tests/                             statische Regressionstests + Fixtures
├── Planer/
│   ├── App/
│   │   ├── PlanerApp.swift            @main, ModelContainer + App-Lock-Gate
│   │   ├── AppRootView.swift          TabView, 5 Tabs
│   │   ├── TabRegistry.swift          AppTab + TabDefinition + Registry
│   │   ├── SettingsTabDefinition.swift   Tab 5 → SettingsView
│   │   └── Assets.xcassets/           AccentColor, AppIcon
│   ├── DesignSystem/
│   │   ├── DesignTokens.swift         Farben, Abstände, Radien, Typografie
│   │   └── Components/                MessageBubbleView, SettingsRowView, UnifiedListItemView
│   ├── Features/
│   │   ├── Chat/    ChatView, ChatViewModel, MCPClient, MCPSession, ToolCallPolicy
│   │   ├── Todos/   TodosView, TodosViewModel, TodoRepository, TodoEditorSheet
│   │   ├── Grocy/   GrocyView, GrocyViewModel, GrocyRepository, GrocyDTO
│   │   └── Mealie/  MealieView, MealieViewModel, MealieRepository, MealieDTO
│   ├── Networking/  NetworkClient, RetryPolicy, APIError, ServiceConfiguration
│   ├── Keychain/    KeychainManager
│   ├── Cache/       ModelContainer, Syncable, Entities
│   └── Settings/    SettingsView, AppLockGate, AppLockSection, ServiceSettingsSection
```

`Tests/Fixtures/` enthält Beispielantworten und JSON-Schemata für Tasks,
Grocy und Mealie.

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

**Naht zu I2:** `SettingsTabDefinition` (in `Planer/App/`) verweist auf
`SettingsView` aus `Planer/Settings/`. `PlanerApp.swift` injiziert den
`ModelContainer` aus `Planer/Cache/ModelContainer.swift` und legt das
App-Lock-Gate (`AppLockGate`) vor die Tabs.

## Design-Tokens

`DesignTokens.swift` ist die Quelle, `Config/DesignTokens.json` die
maschinenlesbare Spiegelung derselben Werte. Beide werden **nur gemeinsam**
geändert. Farben sind iOS-Systemfarben (Light/Dark automatisch); der Akzent ist
ein Platzhalter in `Assets.xcassets/AccentColor.colorset` und im JSON vermerkt.

## Statische Abnahme

Ohne Swift-Toolchain prüfbar:

```sh
grep -c 'Tab(' Planer/App/AppRootView.swift          # erwartet: 5
for s in bubble.left.and.bubble.right checklist cart fork.knife gearshape; do
  grep -q "$s" Planer/App/AppRootView.swift && echo "OK  $s" || echo "FEHLT $s"
done

for t in Tests/verify_*.sh; do bash "$t"; done
```

Die Skripte unter `Tests/` prüfen die Regressionsbefunde der WPs I2–I6
statisch ohne Swift-Toolchain und enden mit `Ergebnis: OK`.

Kompilierung, Rendering und Light/Dark-Darstellung sind **nur auf Mac prüfbar**
und nicht Teil des binären Kriteriums.

## Konventionen

- Keine Secrets im Repo: Tokens und Cloudflare-Zugänge liegen in der Keychain.
- Keine `UserDefaults`-Ablage von Secrets (Kriterium I2).
- Neue Dateien unter `Planer/` werden durch die synchronisierten Ordner
  automatisch Teil des Targets; keine pbxproj-Pflege nötig.
