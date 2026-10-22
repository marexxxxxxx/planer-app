#!/usr/bin/env bash
#
# Statische Abnahme der sieben Leistungen aus MARAAA-160
# (spec-chat Rev 6 Delta §7.2/§7.3, Entscheidungen O1-O11).
#
# Geprüft werden Dateien, Symbole, Zeilenreihenfolgen und Zählungen — keine
# Swift-Toolchain, keine Kompilierung, kein Aufruf anderer Tests.
#
#   bash Tests/verify_chat_ux.sh [timeouts|stream|thinking|working|appearance|profile|rows|all]
#
# Exit-Status: 0 = alle Prüfungen des Abschnitts grün, 1 = mindestens eine rot,
# 2 = falscher Aufruf. Der Status stammt aus `fail`, nie aus einem `echo`.
#
# Die Prüfnummern (T/S/D/W/A/P/H) sind die der Testmatrix §7.3. Die dort
# genannte Zeile M1–M17 aus §7.4 macht den zugehörigen Abschnitt rot; die
# Mutationsmatrix steht im Bericht zu MARAAA-164.
#
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$root"

chat="Planer/Features/Chat"
cfg="$chat/ChatConfiguration.swift"
pref="$chat/ChatPreferences.swift"
vm="$chat/ChatViewModel.swift"
view="$chat/ChatView.swift"
api="$chat/HermesChatAPI.swift"
prov="$chat/ChatStreamProvider.swift"
net="Planer/Networking/NetworkClient.swift"
dir="$chat/HermesProfileDirectory.swift"
work="$chat/WorkingIndicatorView.swift"
sse="$chat/ChatSSE.swift"
appearance="Planer/App/AppearancePreferences.swift"
planerapp="Planer/App/PlanerApp.swift"
settings="Planer/Settings"
chatsec="$settings/ChatSettingsSection.swift"
appsec="$settings/AppearanceSettingsSection.swift"
settingsview="$settings/SettingsView.swift"
tokens="Planer/DesignSystem/DesignTokens.swift"
row="Planer/DesignSystem/Components/SettingsRowView.swift"
bubble="Planer/DesignSystem/Components/MessageBubbleView.swift"
mealie="Planer/Features/Mealie/MealieView.swift"
image="Planer/Features/Mealie/MealieImageView.swift"
jsontokens="Config/DesignTokens.json"

fail=0

pass() { echo "ok:   $1"; }
bad()  { echo "FAIL: $1"; fail=1; }

need() { if grep -qE "$2" "$1"; then pass "$3"; else bad "$3  [$1 ~ /$2/]"; fi; }
need_fixed() { if grep -qF "$2" "$1"; then pass "$3"; else bad "$3  [$1 = $2]"; fi; }
ban() { if grep -qE "$2" "$1"; then bad "$3  [$1 ~ /$2/]"; else pass "$3"; fi; }
ban_fixed() { if grep -qF "$2" "$1"; then bad "$3  [$1 = $2]"; else pass "$3"; fi; }
file_required() { if [[ -f "$1" ]]; then pass "Datei: $1"; else bad "Datei fehlt: $1"; fi; }

# `grep -c` endet bei 0 Treffern mit Status 1; unter `pipefail` darf das den
# Zähler nicht verfälschen. Deshalb erst den Status schlucken, dann zählen.
count_matches() {
    local n
    n="$(grep -cE "$2" "$1" 2>/dev/null || true)"
    echo "${n:-0}" | tr -d ' '
}

at_least() {
    local file="$1" pattern="$2" min="$3" label="$4" n
    n="$(count_matches "$file" "$pattern")"
    if [[ "$n" -ge "$min" ]]; then
        pass "$label (Treffer: $n)"
    else
        bad "$label (Treffer: $n, erwartet: >= $min)  [$file ~ /$pattern/]"
    fi
}

exactly() {
    local file="$1" pattern="$2" want="$3" label="$4" n
    n="$(count_matches "$file" "$pattern")"
    if [[ "$n" -eq "$want" ]]; then
        pass "$label (Treffer: $n)"
    else
        bad "$label (Treffer: $n, erwartet: $want)  [$file ~ /$pattern/]"
    fi
}

# Abschnitt einer Datei: von der Zeile, die $2 enthält, bis zur ersten Zeile,
# die $3 enthält (beide Grenzen eingeschlossen). Grenzen sind **wörtlich** und
# werden mit index() verglichen — ein Regex würde bei jedem `\(` in awk
# warnen und die Grenze unschärfer machen.
section() {
    awk -v s="$2" -v e="$3" '!f && index($0, s) > 0 { f=1 } f { print; if (index($0, e) > 0) exit }' "$1"
}

section_has() {
    local file="$1" start="$2" end="$3" pattern="$4" label="$5"
    if section "$file" "$start" "$end" | grep -qE "$pattern"; then
        pass "$label"
    else
        bad "$label  [$file, Abschnitt /$start/../$end/ ~ /$pattern/]"
    fi
}

section_lacks() {
    local file="$1" start="$2" end="$3" pattern="$4" label="$5"
    if section "$file" "$start" "$end" | grep -qE "$pattern"; then
        bad "$label  [$file, Abschnitt /$start/../$end/ ~ /$pattern/]"
    else
        pass "$label"
    fi
}

ban_tree() {
    local pattern="$1" label="$2" dir="${3:-$chat}" hits
    hits="$(grep -rInE "$pattern" "$dir" --include='*.swift' 2>/dev/null | wc -l | tr -d ' ' || true)"
    if [[ "${hits:-0}" -eq 0 ]]; then
        pass "$label"
    else
        bad "$label (Treffer: $hits)"
    fi
}

# ---------------------------------------------------------------------------
# (a) Zwei persistierte Zeitlimits — §7.3.1
# ---------------------------------------------------------------------------
timeouts_section() {
    echo "--- (a) Zeitlimits: zwei persistierte Nutzerwerte"

    file_required "$pref"
    need "$pref" 'final class ChatPreferences: ObservableObject' \
        "T1  ChatPreferences ist die einzige Quelle"
    need "$pref" '@MainActor' "T2  ChatPreferences ist main-actor-isoliert"
    need_fixed "$pref" 'static let streamIdleTimeoutKey = "chatStreamIdleTimeout"' \
        "T3  Schlüssel des Strom-Zeitlimits"
    need_fixed "$pref" 'static let restTimeoutKey = "chatRestTimeout"' \
        "T4  Schlüssel des REST-Zeitlimits"
    need_fixed "$pref" 'static let profileKey = "chatHermesProfile"' \
        "T5  Schlüssel des Hermes-Profils"
    need_fixed "$pref" 'static let defaultStreamIdleTimeout = 900' \
        "T6  Default Strom-Zeitlimit 900 s"
    need_fixed "$pref" 'static let defaultRestTimeout = 30' \
        "T7  Default REST-Zeitlimit 30 s"
    need "$pref" 'static let streamIdleTimeoutRange: ClosedRange<Int> = 60\.\.\.3600' \
        "T8  Bereich Strom-Zeitlimit 60...3600"
    need "$pref" 'static let restTimeoutRange: ClosedRange<Int> = 10\.\.\.300' \
        "T9  Bereich REST-Zeitlimit 10...300"
    need "$pref" '@Published private\(set\) var streamIdleTimeout: Int' \
        "T10 veröffentlichter Strom-Wert"
    need "$pref" '@Published private\(set\) var restTimeout: Int' \
        "T11 veröffentlichter REST-Wert"
    need "$pref" '@Published private\(set\) var profile: String' \
        "T12 veröffentlichtes Profil"
    at_least "$pref" 'min\(max\(seconds, range\.lowerBound\), range\.upperBound\)' 2 \
        "T13 beide Clamps ziehen auf die Grenze"
    need "$pref" 'defaults\.object\(forKey: Self\.streamIdleTimeoutKey\) as\? Int' \
        "T14 fehlender Wert wird von 0 unterschieden"
    ban "$pref" 'defaults\.integer\(forKey:' \
        "T15 kein integer(forKey:) (0 würde still klemmen)"
    need_fixed "$pref" 'defaults.set(clamped, forKey: Self.streamIdleTimeoutKey)' \
        "T16 Strom-Wert wird persistiert"
    need_fixed "$pref" 'defaults.set(clamped, forKey: Self.restTimeoutKey)' \
        "T17 REST-Wert wird persistiert"
    need "$pref" 'func setStreamIdleTimeout\(_ seconds: Int\)' \
        "T18 Setter Strom-Zeitlimit"
    need "$pref" 'func setRestTimeout\(_ seconds: Int\)' \
        "T19 Setter REST-Zeitlimit"
    # T20 der Matrix verbietet das Wort „secret“ — die Datei sagt aber in ihrer
    # eigenen Grenze „keine Secrets“. Deshalb hier die belastbare Fassung:
    # kein Schreibvorgang und kein Schlüssel mit Geheimnisnamen.
    ban "$pref" 'defaults\.set\([^)]*([Pp]assword|[Tt]oken|[Ss]ecret)' \
        "T20 kein Geheimnis wird in UserDefaults geschrieben"
    ban "$pref" 'Key = "[^"]*([Pp]assword|[Tt]oken|[Ss]ecret)' \
        "T20b kein UserDefaults-Schlüssel mit Geheimnisnamen"
    need "$pref" 'var configuration: HermesChatConfiguration' \
        "T21 fertige Konfiguration aus den drei Werten"
    need "$cfg" 'struct HermesChatConfiguration: Sendable, Equatable' \
        "T22 Konfiguration ist Wertetyp und vergleichbar"
    need "$cfg" 'var streamIdleTimeout: TimeInterval = 900' \
        "T23 Strom-Default in der Konfiguration"
    need "$cfg" 'var restTimeout: TimeInterval = 30' \
        "T24 REST-Default in der Konfiguration"

    local pref_stream cfg_stream pref_rest cfg_rest
    pref_stream="$(grep -oE 'defaultStreamIdleTimeout = [0-9]+' "$pref" | grep -oE '[0-9]+' | head -1)"
    cfg_stream="$(grep -oE 'streamIdleTimeout: TimeInterval = [0-9]+' "$cfg" | grep -oE '[0-9]+' | head -1)"
    pref_rest="$(grep -oE 'defaultRestTimeout = [0-9]+' "$pref" | grep -oE '[0-9]+' | head -1)"
    cfg_rest="$(grep -oE 'restTimeout: TimeInterval = [0-9]+' "$cfg" | grep -oE '[0-9]+' | head -1)"
    if [[ -n "$pref_stream" && "$pref_stream" = "$cfg_stream" \
          && -n "$pref_rest" && "$pref_rest" = "$cfg_rest" ]]; then
        pass "T25 Defaults stimmen überein ($pref_stream/$pref_rest s)"
    else
        bad "T25 Defaults stimmen überein (Preferences: ${pref_stream:-?}/${pref_rest:-?}, Konfiguration: ${cfg_stream:-?}/${cfg_rest:-?})"
    fi

    need "$vm" 'self\.configuration = preferences\.configuration' \
        "T26 ViewModel liest die Nutzerwerte nur aus den Preferences"
    ban "$vm" 'self\.configuration = HermesChatConfiguration\(\)' \
        "T27 keine zweite Wahrheit über Nutzerwerte"
    need "$vm" 'private func refreshConfiguration\(\)' \
        "T28 Konfiguration wird bei Änderung neu gebaut"
    section_has "$vm" 'func send()' 'private enum TurnFailure' 'refreshConfiguration\(\)' \
        "T29 send() übernimmt einen geänderten Wert"
    need "$vm" 'guard wanted != configuration else \{ return \}' \
        "T30 Neubau nur bei echter Änderung"
    need "$api" 'NetworkClient\(timeout: configuration\.restTimeout' \
        "T31 REST-Client trägt das REST-Zeitlimit"
    need "$prov" 'NetworkClient\(timeout: configuration\.streamIdleTimeout\)' \
        "T32 Strom-Client trägt das Strom-Zeitlimit"
    need "$vm" 'let wanted = preferences\.configuration' \
        "T33 refreshConfiguration liest die Preferences"

    # Zusatzauflage 3: in UserDefaults stehen nur Timeout, Profil, Appearance.
    exactly "$pref" 'static let (streamIdleTimeoutKey|restTimeoutKey|profileKey) = "' 3 \
        "X1  ChatPreferences kennt genau drei Schlüssel"
    exactly "$appearance" 'static let key = "' 1 \
        "X2  AppearancePreferences kennt genau einen Schlüssel"
    exactly "$appearance" 'static let key = "appAppearance"' 1 \
        "X3  Appearance-Schlüssel heißt appAppearance"
    local writes_ok
    writes_ok="$(grep -cE 'defaults\.set\(clamped, forKey: Self\.(streamIdleTimeoutKey|restTimeoutKey)\)' "$pref" || true)"
    if [[ "${writes_ok:-0}" -eq 2 ]]; then
        pass "X4  beide Zeitlimits werden an genau ihrem Schlüssel gespeichert"
    else
        bad "X4  beide Zeitlimits werden an genau ihrem Schlüssel gespeichert (Treffer: ${writes_ok:-0})"
    fi
    ban_tree '@AppStorage\("(chatStreamIdleTimeout|chatRestTimeout|chatHermesProfile|appAppearance)"\)' \
        "X5  kein @AppStorage-Bypass neben den Präferenz-Klassen" "Planer"
}

# ---------------------------------------------------------------------------
# (b) Stream-Session ohne 10-s-Deckel — §7.3.2
# ---------------------------------------------------------------------------
stream_section() {
    echo "--- (b) Stromfester Transport: kein 10-s-Deckel im Chat"

    file_required "$net"
    need_fixed "$net" 'static let defaultTimeout: TimeInterval = 10' \
        "S1  der 10-s-Deckel existiert weiter für REST"
    need "$net" 'private let streamingSession: URLSession' \
        "S2  eigener Strom-Session"
    need "$net" 'self\.streamingSession = timeout == NetworkClient\.defaultTimeout' \
        "S3  Strom-Session entsteht aus dem übergebenen Timeout"
    need "$net" 'private static func makeRedirectBlockingSession\(timeout: TimeInterval\) -> URLSession' \
        "S4  Session-Bauer nimmt den Timeout an"
    need "$net" 'configuration\.timeoutIntervalForRequest = timeout' \
        "S5  Session-Grenze kommt aus dem Timeout"
    need "$net" 'private static let redirectBlockingSession' \
        "S6  statische Session bleibt (Regression Hermes-Auth)"
    need "$net" 'let session = service == \.hermes \? streamingSession : urlSession\(for: service\)' \
        "S7  Hermes-Strom nutzt die Strom-Session"
    need "$net" 'session\.bytes\(for: urlRequest\)' \
        "S8  der Strom liest über diese Session"
    ban "$net" 'timeoutIntervalForRequest = 10' \
        "S9  keine fest verdrahtete 10-s-Grenze"
    need "$net" 'urlRequest\.timeoutInterval = timeout' \
        "S10 zweite Ebene (Request) trägt denselben Wert"
    at_least "$net" 'urlSession\(for:' 3 \
        "S11 die übrigen Dienst-Pfade bleiben"
    need "$net" 'return NetworkClient\.redirectBlockingSession' \
        "S12 statische Session bleibt unverändert"
    need "$sse" 'line\.hasPrefix\(":"\)' \
        "S13 Keepalive-Zeilen bleiben ignoriert"
    need "$vm" 'Der Turn kann auf dem Server weiterlaufen' \
        "S14 Timeout-Meldung nennt den weiterlaufenden Turn"
    need "$vm" 'offersHistoryReload = true' \
        "S15 Timeout bietet den Weg über den Verlauf"
    need "$vm" 'func reloadHistory\(\) async' \
        "S16 reloadHistory existiert"
    need "$view" 'viewModel\.offersHistoryReload' \
        "S17 die Leiste liest das Angebot"
    need_fixed "$view" 'Button("Verlauf neu laden")' \
        "S18 der Knopf heißt wörtlich „Verlauf neu laden“"
    need "$view" 'Task \{ await viewModel\.reloadHistory\(\) \}' \
        "S19 der Knopf lädt den Verlauf neu"

    # Zusatzauflage 3: im Chat baut niemand einen NetworkClient ohne Argument.
    ban_tree 'NetworkClient\(\)' \
        "X6  kein NetworkClient() ohne Argument im Chat"
    need "$prov" 'private let client: NetworkClient' \
        "X7  der Strom-Provider hält genau einen Client"
}

# ---------------------------------------------------------------------------
# (c) Automatisch sichtbares Denken — §7.3.3
# ---------------------------------------------------------------------------
thinking_section() {
    echo "--- (c) Live-Denken: Klappe öffnet beim ersten Reasoning"

    need "$vm" 'var reasoningAutoExpanded: Bool = false' \
        "D1  eigener Merker je Eintrag, Default false"
    need "$vm" 'private func autoExpandReasoning\(at index: Int\)' \
        "D2  Auto-Öffnen ist eine eigene Naht"
    section_has "$vm" 'case .reasoningDelta' 'case .textDelta' 'autoExpandReasoning\(at: index\)' \
        "D3  das erste Reasoning löst das Öffnen aus"
    need "$vm" 'guard !entries\[index\]\.reasoningAutoExpanded, entries\[index\]\.text\.isEmpty' \
        "D4  genau einmal und nur solange kein Text da ist"
    section_has "$vm" 'private func autoExpandReasoning' 'func toggleReasoning' 'reasoningDisclosure = \.expanded' \
        "D5  Auto-Öffnen setzt den Zustand auf expanded"
    need "$vm" 'var reasoningDisclosure: Disclosure = \.collapsed' \
        "D6  Default bleibt eingeklappt"
    need "$view" 'isExpanded: entry\.reasoningDisclosure == \.expanded' \
        "D7  die View rendert den gehaltenen Zustand"
    section_lacks "$vm" 'private func autoExpandReasoning' 'func toggleReasoning' 'reasoningDisclosure = \.collapsed' \
        "D8  die Automatik klappt nie wieder zu"
}

# ---------------------------------------------------------------------------
# (d) Arbeits-Animation mit Reduce-Motion — §7.3.4
# ---------------------------------------------------------------------------
working_section() {
    echo "--- (d) Arbeits-Animation: sichtbar nur während des Turns"

    file_required "$work"
    need "$work" 'struct WorkingIndicatorView: View' \
        "W1  eigene View"
    need "$work" 'let startedAt: Date' \
        "W2  Startzeit kommt von außen"
    need "$work" 'TimelineView\(\.periodic\(from: startedAt, by: 1\)\)' \
        "W3  Sekunden ohne eigenen Timer"
    need_fixed "$work" 'Text("Hermes arbeitet …")' \
        "W4  Text wörtlich"
    need "$work" 'ForEach\(0\.\.<3, id: \\.self\)' \
        "W5  drei Punkte"
    need "$work" 'accessibilityReduceMotion' \
        "W6  Reduce Motion wird gelesen"
    need "$work" 'repeatForever' \
        "W7  Puls läuft dauerhaft"
    need "$work" 'Hermes arbeitet seit' \
        "W8  Accessibility-Label nennt die Sekunden"
    need "$vm" 'var showsWorkingIndicator: Bool' \
        "W9  Sichtbarkeit ist eine eigene Prüfung"
    section_has "$vm" 'var showsWorkingIndicator' 'func reloadHistory' 'toolStatus == \.running' \
        "W10 laufende Werkzeugkarte hält die Animation"
    section_has "$vm" 'var showsWorkingIndicator' 'func reloadHistory' 'return lastAgent\.text\.isEmpty' \
        "W11 Agent ohne Text hält die Animation"
    need "$view" 'if viewModel\.showsWorkingIndicator, let startedAt = viewModel\.turnStartedAt \{' \
        "W12 die View baut die Animation nur bei Bedarf"
    need "$view" 'WorkingIndicatorView\(startedAt: startedAt\)' \
        "W13 die Animation bekommt die Startzeit"
    need "$vm" 'turnStartedAt = Date\(\)' \
        "W14 send() startet die Uhr"
    at_least "$vm" 'turnStartedAt = nil' 2 \
        "W15 defer und cancel beenden die Uhr"
    need "$vm" '@Published private\(set\) var turnStartedAt: Date\?' \
        "W16 Startzeit ist veröffentlicht"
    section_has "$vm" 'var showsWorkingIndicator' 'func reloadHistory' 'turnEntryIDs\.contains' \
        "W17 nur Einträge dieses Turns zählen"
}

# ---------------------------------------------------------------------------
# (e) Erscheinungsbild System/Hell/Dunkel an genau einer Stelle — §7.3.5
# ---------------------------------------------------------------------------
appearance_section() {
    echo "--- (e) Erscheinungsbild: System/Hell/Dunkel, genau eine Anwendung"

    file_required "$appearance"
    need "$appearance" 'enum AppAppearance: String, CaseIterable, Identifiable' \
        "A1  drei Fälle, aufzählbar"
    exactly "$appearance" '^[[:space:]]*case system$' 1 "A2  Fall System"
    exactly "$appearance" '^[[:space:]]*case light$' 1 "A3  Fall Hell"
    exactly "$appearance" '^[[:space:]]*case dark$' 1 "A4  Fall Dunkel"
    need "$appearance" 'var colorScheme: ColorScheme\?' \
        "A5  Übergang nach SwiftUI ist typisiert"
    need_fixed "$appearance" 'static let key = "appAppearance"' \
        "A6  gespeicherter Schlüssel"
    need "$appearance" 'final class AppearancePreferences: ObservableObject' \
        "A7  eine Präferenz-Klasse"
    need "$appearance" '@Published private\(set\) var appearance: AppAppearance' \
        "A8  Wert nur über den Setter"
    need "$appearance" 'func setAppearance\(_ value: AppAppearance\)' \
        "A9  einziger Schreibweg"
    need "$appearance" 'AppAppearance\(rawValue: .*\) \?\? \.system' \
        "A10 unbekannter Wert fällt auf System zurück"
    exactly "$appearance" 'return "System"' 1 "A11 Anzeige System"
    exactly "$appearance" 'return "Hell"' 1 "A12 Anzeige Hell"
    exactly "$appearance" 'return "Dunkel"' 1 "A13 Anzeige Dunkel"
    need "$planerapp" '@StateObject private var appearance = AppearancePreferences\.shared' \
        "A14 die Wurzel liest dieselbe Instanz"
    exactly "$planerapp" 'preferredColorScheme\(appearance\.colorScheme\)' 1 \
        "A15 genau eine Anwendung in PlanerApp"
    local total
    total="$(grep -rIE '^[[:space:]]*\.preferredColorScheme\(' Planer --include='*.swift' | wc -l | tr -d ' ' || true)"
    if [[ "${total:-0}" -eq 1 ]]; then
        pass "A16 app-weit genau eine Anwendung von preferredColorScheme"
    else
        bad "A16 app-weit genau eine Anwendung von preferredColorScheme (Treffer: ${total:-0})"
    fi
    ban_tree 'preferredColorScheme' "A17 kein Feature setzt das Schema selbst" "$chat"
    ban_tree 'preferredColorScheme' "A18 keine Einstellungs-Sektion setzt das Schema" "$settings"
    need "$appsec" 'struct AppearanceSettingsSection: View' \
        "A19 eigene Sektion"
    need_fixed "$appsec" 'Picker("Erscheinungsbild"' \
        "A20 Picker wörtlich"
    need "$appsec" 'ForEach\(AppAppearance\.allCases' \
        "A21 alle drei Fälle im Picker"
    need "$settingsview" 'AppearanceSettingsSection\(\)' \
        "A22 Sektion ist eingebunden"
    need "$planerapp" '@AppStorage\("appLockEnabled"\)' \
        "A23 Regression: Sperre bleibt unberührt"

    # Zusatzauflage 3: keine harte Kontrastfarbe in der Nutzerblase.
    ban "$bubble" '\.white' \
        "X8  kein hartes .white in der Blase"
    need "$bubble" 'case \.user: DesignTokens\.Palette\.userBubbleLabel' \
        "X9  die Kontrastfarbe kommt aus den Tokens"
    need "$tokens" 'static let userBubbleLabel' \
        "X10 der Token existiert"
}

# ---------------------------------------------------------------------------
# (f) Profilpfad /p/<profil> für alle Hermes-Pfade inkl. 404 — §7.3.6
# ---------------------------------------------------------------------------
profile_section() {
    echo "--- (f) Profilwahl: /p/<profil> an genau einer Stelle, 404 wird benannt"

    need "$cfg" 'var profile: String = ""' \
        "P1  leeres Profil ist der Default"
    need "$cfg" 'func scoped\(_ path: String\) -> String' \
        "P2  genau ein Bauplatz für das Präfix"
    need_fixed "$cfg" 'return "/p/" + encoded' \
        "P3  das Präfix ist wörtlich /p/"
    need "$cfg" 'var chatPath: String \{ scoped\("/v1/chat/completions"\) \}' \
        "P4  Chat-Pfad ist berechnet"
    need "$cfg" 'var sessionsPath: String \{ scoped\("/api/sessions"\) \}' \
        "P5  Sitzungspfad ist berechnet"
    need "$cfg" 'var approvalPath: String \{ scoped\("/v1/runs/%@/approval"\) \}' \
        "P6  Freigabepfad ist berechnet"
    need "$cfg" 'var healthPath: String \{ scoped\("/health"\) \}' \
        "P7  Health-Pfad ist berechnet"
    ban "$cfg" 'var (chatPath|sessionsPath|approvalPath|healthPath) = "' \
        "P8  kein gespeicherter Pfad ohne Präfix"
    need "$cfg" 'case profileNotServed\(String\)' \
        "P9  eigener Fehlerfall"
    need "$cfg" 'wird von diesem Server nicht ausgeliefert' \
        "P10 Meldung nennt den Grund"
    need "$cfg" 'hermes gateway migrate --multiplex' \
        "P11 Meldung nennt den Server-Schritt"
    need "$api" 'func probeProfile\(\) async throws' \
        "P12 Vorprüfung existiert"
    need "$api" 'path: configuration\.healthPath' \
        "P13 Vorprüfung geht über den Profilpfad"
    need "$api" 'guard !configuration\.profile\.isEmpty else \{ return \}' \
        "P14 ohne Profil kein Zusatz-Request"
    need "$api" 'result\.response\.statusCode == 404' \
        "P15 nur 404 wird ausgewertet"
    need "$api" 'throw HermesChatConfigurationError\.profileNotServed\(configuration\.profile\)' \
        "P16 404 wird zur benannten Meldung"
    need "$vm" 'try await api\.probeProfile\(\)' \
        "P17 jeder Turn prüft das Profil vorab"
    need "$pref" 'static func normalizeProfile\(_ raw: String\) -> String\?' \
        "P18 Namensprüfung existiert"
    need_fixed "$pref" '^[a-z0-9][a-z0-9_-]*$' \
        "P19 erlaubte Zeichen wörtlich"
    need "$pref" 'options: \.regularExpression' \
        "P20 die Regel wird als Regex angewandt"
    file_required "$dir"
    need "$dir" 'struct HermesProfileDirectory: Sendable' \
        "P21 Profilverzeichnis existiert"
    need "$dir" 'func profiles\(\) async throws -> \[HermesProfile\]' \
        "P22 Profilliste wird geladen"
    exactly "$dir" 'case displayName = "display_name"' 1 \
        "P23 Anzeigename folgt dem Wire-Feld"
    exactly "$dir" 'case isDefault = "is_default"' 1 \
        "P23b Default-Markierung folgt dem Wire-Feld"
    need_fixed "$dir" 'path: "/api/profiles"' \
        "P24 Route der Profilliste"
    need "$dir" 'for: \.dashboard' \
        "P25 Route gehört zur Dashboard-Oberfläche"
    need "$chatsec" 'struct ChatSettingsSection: View' \
        "P26 Einstellungs-Sektion existiert"
    exactly "$chatsec" 'preferences\.setStreamIdleTimeout\(' 1 \
        "P27 Strom-Zeitlimit wird über den Setter geschrieben"
    exactly "$chatsec" 'preferences\.setRestTimeout\(' 1 \
        "P28 REST-Zeitlimit wird über den Setter geschrieben"
    exactly "$chatsec" 'in: ChatPreferences\.streamIdleTimeoutRange' 1 \
        "P28b Stepper kennt den Strom-Bereich"
    exactly "$chatsec" 'in: ChatPreferences\.restTimeoutRange' 1 \
        "P28c Stepper kennt den REST-Bereich"
    need_fixed "$chatsec" 'Text("Zeitlimit Antwortstrom")' \
        "P29 Beschriftung Strom-Zeitlimit"
    need_fixed "$chatsec" 'Text("Zeitlimit Serveranfragen")' \
        "P29b Beschriftung REST-Zeitlimit"
    need "$chatsec" 'preferences\.setProfile\(' \
        "P30 Profilwahl schreibt über den Setter"
    need "$chatsec" 'HermesProfileDirectory\(' \
        "P31 Sektion liest die Profilliste"
    need_fixed "$chatsec" 'Text("Standard (ohne Profil)")' \
        "P32 Default-Eintrag wörtlich"
    need "$chatsec" 'nur a–z, 0–9, _ und -, 1–64 Zeichen' \
        "P33 Regeltext bei ungültigem Namen"
    need "$chatsec" 'Profilliste nicht erreichbar' \
        "P34 Handeingabe wird erklärt"
    need "$chatsec" 'hermes gateway migrate --multiplex' \
        "P35 Fußnote nennt den Server-Schritt"
    ban "$chatsec" '([Pp]assword|SecureField)' \
        "P36 kein Geheimnisfeld in der Chat-Sektion"
    need "$settingsview" 'ChatSettingsSection\(\)' \
        "P37 Sektion ist eingebunden"
    ban "$vm" 'URLQueryItem\(name: "profile"' \
        "P38 Profil ist ein Pfad, kein Query-Parameter"

    # „für alle Hermes-Pfade“: keine Methode der API baut einen Pfad am
    # Profil-Bauplatz vorbei.
    local hardcoded
    hardcoded="$(grep -nE 'path: "/' "$api" | grep -v 'path: "/api/profiles"' || true)"
    if [[ -z "$hardcoded" ]]; then
        pass "P39 kein Hermes-Pfad in der API ohne configuration.*Path"
    else
        bad "P39 kein Hermes-Pfad in der API ohne configuration.*Path (Treffer: $hardcoded)"
    fi
    need "$prov" 'path: configuration\.chatPath' \
        "P40 auch der Strom nutzt den berechneten Chat-Pfad"
}

# ---------------------------------------------------------------------------
# (g) Zeilenhöhen 56/76/56 — §7.3.7
# ---------------------------------------------------------------------------
rows_section() {
    echo "--- (g) Zeilenhöhen: 56 pt Einstellung, 76 pt Rezept, 56 pt Thumbnail"

    need "$tokens" 'enum Size' "H1  eigener Größen-Block"
    need "$tokens" 'static let settingsRow: CGFloat = 56' \
        "H2  Einstellungszeile 56 pt"
    need "$tokens" 'static let recipeRow: CGFloat = 76' \
        "H3  Rezeptzeile 76 pt"
    need "$tokens" 'static let thumbnail: CGFloat = 56' \
        "H4  Thumbnail 56 pt"
    need "$row" 'minHeight: DesignTokens\.Size\.settingsRow' \
        "H5  Einstellungszeile nutzt minHeight"
    section_has "$mealie" 'private func recipeRow' 'private func thumbnail' 'minHeight: DesignTokens\.Size\.recipeRow' \
        "H6  Rezeptzeile nutzt minHeight"
    section_has "$mealie" 'private func recipeRow' 'private func thumbnail' 'padding\(DesignTokens\.Spacing\.l\)' \
        "H7  Rezeptzeile hat 16 pt Innenabstand"
    section_lacks "$mealie" 'private func recipeRow' 'private func thumbnail' 'padding\(DesignTokens\.Spacing\.m\)' \
        "H8  der alte 12-pt-Abstand ist weg"
    exactly "$image" 'width: DesignTokens\.Size\.thumbnail' 1 \
        "H9  Thumbnail-Breite aus dem Token"
    exactly "$image" 'height: DesignTokens\.Size\.thumbnail' 1 \
        "H9b Thumbnail-Höhe aus dem Token"
    need_fixed "$jsontokens" '"settingsRow": 56' \
        "H10 Doku spiegelt 56 pt der Einstellungszeile"
    need_fixed "$jsontokens" '"recipeRow": 76' \
        "H10b Doku spiegelt 76 pt der Rezeptzeile"
    need_fixed "$jsontokens" '"thumbnail": 56' \
        "H10c Doku spiegelt 56 pt des Thumbnails"
    need "$mealie" 'MealieImageView\(' \
        "H11 Regression: die Zeile nutzt den authentifizierten Loader"
    need "$mealie" 'repository: model\.imageRepository' \
        "H11b Regression: der Loader bekommt das Repository"
    need "$mealie" 'imageURL: row\.imageURL' \
        "H11c Regression: der Loader bekommt die damalige Basis"
}

case "${1:-all}" in
    timeouts)   timeouts_section ;;
    stream)     stream_section ;;
    thinking)   thinking_section ;;
    working)    working_section ;;
    appearance) appearance_section ;;
    profile)    profile_section ;;
    rows)       rows_section ;;
    all)
        timeouts_section
        stream_section
        thinking_section
        working_section
        appearance_section
        profile_section
        rows_section
        ;;
    *)
        echo "Aufruf: $0 [timeouts|stream|thinking|working|appearance|profile|rows|all]"
        exit 2
        ;;
esac

if [[ "$fail" -ne 0 ]]; then
    echo "Ergebnis: FEHLGESCHLAGEN (chat-ux)"
    exit 1
fi
echo "Ergebnis: OK (chat-ux)"
