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
  übrigen Größen und übernimmt die Maskierung. Das eingecheckte Bild ist ein
  generierter Platzhalter, nicht das endgültige Icon (siehe „Offene Punkte").

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
│   │   ├── Chat/    ChatView, ChatViewModel, SessionListView, ThinkingDisclosureView, ToolCallCard, ToolConfirmationChips, ChatDTOs, ChatConfiguration, ChatSSE, HermesChatAPI, ChatStreamProvider
│   │   ├── Todos/   TodosView, TodosViewModel, TodoRepository, TodoEditorSheet
│   │   ├── Grocy/   GrocyView, GrocyViewModel, GrocyRepository, GrocyDTO
│   │   └── Mealie/  MealieView, MealieViewModel, MealieRepository, MealieDTO
│   ├── Networking/  NetworkClient, HermesSession, RetryPolicy, APIError, ServiceConfiguration, ServiceType
│   ├── Keychain/    KeychainManager
│   ├── Cache/       ModelContainer, Syncable, Entities
│   └── Settings/    SettingsView, AppLockSection, ServiceSettingsSection
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
App-Lock-Gate (Sperr-Oberfläche + `LocalAuthentication`) vor die Tabs.

## Design-Tokens

`DesignTokens.swift` ist die Quelle, `Config/DesignTokens.json` die
maschinenlesbare Spiegelung derselben Werte. Beide werden **nur gemeinsam**
geändert. Farben sind iOS-Systemfarben (Light/Dark automatisch); der Akzent ist
ein Platzhalter in `Assets.xcassets/AccentColor.colorset` und im JSON vermerkt.

## Auth

Jeder Request trägt die Cloudflare-Access-Header
`CF-Access-Client-Id`/`CF-Access-Client-Secret`; gesetzt werden sie
ausschließlich in `NetworkClient.injectHeaders`. Mealie nutzt zusätzlich
`Authorization: Bearer <api_token>`, Grocy `GROCY-API-KEY`, das Dashboard keinen
Header.

Hermes nutzt im Dashboard-Betrieb **keinen** Bearer. Die App meldet sich dort
mit dem Password-Login an:

```
POST /auth/password-login
Content-Type: application/json

{"provider":"basic","username":"…","password":"…"}
```

Die Antwort `{"ok":true,"next":"/"}` bringt `Set-Cookie`-Session-Cookies. Sie
liegen nur im Prozessspeicher (`HermesCookieJar`) und werden bei jedem
folgenden Hermes-Request — auch beim Chat-Stream — als `Cookie`-Header
gesendet. Antwortet Hermes mit 401 und `reason` `no_cookie`/
`invalid_or_expired_session` bzw. `error` `session_expired`/`unauthenticated`,
loggt sich die App genau einmal neu ein, übernimmt die neuen Cookies und
wiederholt den Request einmal. Ein erneuter 401 wird als Fehler gemeldet.

In den Einstellungen stehen für Hermes `Benutzername` und `Passwort`
(SecureField); beide werden über `KeychainManager` gespeichert, ein leeres
Feld löscht den Eintrag. Mealie, Grocy und Dashboard behalten ihre bisherigen
Token-Felder. Es gibt keine Secrets im Repo und keine `UserDefaults`-Ablage.

### Hermes: Dashboard und API-Server sind zwei Oberflächen

Hermes betreibt zwei getrennte Prozesse, die nicht dieselben Routen kennen:

| Oberfläche | Authentifizierung | Endpunkte |
| --- | --- | --- |
| Dashboard (Port 9119) | Password-Login + Session-Cookies | `POST /auth/password-login`, `GET /api/sessions`, `GET /api/sessions/{id}`, `GET /api/sessions/{id}/messages` |
| API-Server (Port 8642) | `Authorization: Bearer <API_SERVER_KEY>` | `POST /api/sessions`, `GET/PATCH/DELETE /api/sessions/{id}`, `GET …/messages`, `POST /v1/chat/completions`, `POST /v1/runs/{id}/approval`, `GET /v1/models` |

Das Dashboard hat **kein** `POST /api/sessions` und keine `/v1/*`-Routen; ein
POST dorthin endet mit `405 {"detail":"Method Not Allowed"}`. Der API-Server
kennt umgekehrt kein `/auth/password-login` (404) und ignoriert Cookies — er
akzeptiert ausschließlich den Bearer-Schlüssel. Zeigt die Basis-URL also auf
das Dashboard, scheitert der Chat mit HTTP 405, obwohl der Password-Login
selbst funktioniert.

In den Einstellungen sind für den Chat-Betrieb deshalb einzutragen:

- **Basis-URL**: Origin des API-Servers (Port 8642), ohne Pfad und ohne
  abschließendes `/api`, z. B. `https://host:8642`.
- **API-Schlüssel (API-Server, optional)**: der Wert von `API_SERVER_KEY`.

Läuft beides hinter einem Reverse Proxy auf **einem** Host, ist die Basis-URL
der eine öffentliche Origin (ohne Pfad, z. B. `https://host`) und der
**API-Schlüssel erforderlich**: Der App-Verkehr geht an den API-Server, der
ausschließlich `Authorization: Bearer <API_SERVER_KEY>` akzeptiert. Der
Password-Login gilt nur für die Dashboard-Oberfläche, nicht für den API-Server
— ein 401 von dort (`gateway_auth_failed`) meldet darum den fehlenden oder
ungültigen `API_SERVER_KEY`, nicht falsche Zugangsdaten.

Ist der Schlüssel gesetzt, sendet jeder Hermes-Request
`Authorization: Bearer <key>` und keinen `Cookie`-Header; der Password-Login
entfällt (er würde am API-Server mit 404 scheitern). Bleibt das Feld leer,
gilt unverändert der oben beschriebene Password-Login gegen das Dashboard.
Der Verbindungstest fragt für Hermes `GET /v1/models` ab und erkennt daran den
API-Server; 405 und eine Weiterleitung auf `/login` werden als
„Dashboard statt API-Server“ gemeldet. Scheitert `/v1/models` (3xx, 2xx-HTML, 404/405 oder Transportfehler), fragt er
zusätzlich `GET /api/status` ab und wertet `gateway_platforms.api_server` aus:
Die Meldung nennt den gemeldeten Zustand (`state`) und die `listener_base`.
Loopback (`127.0.0.1`/`localhost`/`::1`) heißt „nur auf dem Server selbst
erreichbar“ und verweist auf eine gemeinsame HTTPS-Adresse (hermes-front hinter
dem Tunnel); `0.0.0.0`/`::` heißt „alle Interfaces“, dann muss HTTPS
davorstehen; eine konkrete Adresse wird nur als HTTPS-Basis-URL genannt.
`0.0.0.0` und `http://` werden nie zum Eintragen empfohlen, und ein fehlender
`state` wird nicht als „nicht verbunden“ behauptet. 401 `gateway_auth_failed`
und 403 behalten ihre bisherigen Meldungen. Siehe
[`docs/hermes-405-diagnose.md`](docs/hermes-405-diagnose.md), Abschnitt
„Was die curl-Ausgaben bedeuten“.

Unabhängig von der Betriebsart trägt jeder Hermes-Request den Header
`X-Hermes-Client: planer`; ein vorgeschalteter Proxy kann darüber App- und
Dashboard-Verkehr trennen (beide nutzen `/api/*`). Der Header dient **nur** der
Wegewahl und ist **keine** Autorisierung: Der Wert ist kein Secret, er
beeinflusst die Authentifizierung nicht und ersetzt weder `API_SERVER_KEY` noch
den Password-Login.

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

## Offene Punkte

- **App-Icon-Bild:** In `Planer/App/Assets.xcassets/AppIcon.appiconset/` liegt
  mit `AppIcon-1024.png` nur ein generiertes Platzhalterbild (1024×1024, RGB
  ohne Alphakanal). Das endgültige App-Icon-Bild fehlt und muss vom
  Auftraggeber gesetzt werden. Der Eintrag in `Contents.json` bleibt dabei
  unverändert; das Bild ersetzt nur die vorhandene Datei.
- **Build und Darstellung:** Kompilierung, Simulator-/Gerätetest, Rendering und
  Light/Dark-Darstellung sind nur auf einem Mac prüfbar.

## Konventionen

- Keine Secrets im Repo: Tokens und Cloudflare-Zugänge liegen in der Keychain.
- Keine `UserDefaults`-Ablage von Secrets (Kriterium I2).
- Neue Dateien unter `Planer/` werden durch die synchronisierten Ordner
  automatisch Teil des Targets; keine pbxproj-Pflege nötig.
