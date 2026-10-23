#!/usr/bin/env bash
#
# Statischer Prüfstand für MARAAA-190: Tabs in den Einstellungen ausblendbar.
#
# Belegt am Code, ohne Swift-Toolchain:
#   1. eine eigene Sektion „Tab-Bar“ mit je einem Schalter für To-Dos,
#      Einkauf und Rezepte,
#   2. die Auswahl liegt in `UserDefaults` (kein flüchtiger `@State`),
#   3. Chat und Einstellungen sind nicht abwählbar,
#   4. beide Tab-Bar-Zweige (iOS 18 `Tab` und Legacy `.tabItem`) rendern
#      dieselbe Liste sichtbarer Tabs,
#   5. ein ausgeblendeter ausgewählter Tab fällt auf Chat zurück.
#
#   bash Tests/verify_tab_visibility.sh
#
# Exit-Status: 0 = alle Invarianten grün, 1 = mindestens eine rot.
#
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$root"

view="Planer/App/AppRootView.swift"
registry="Planer/App/TabRegistry.swift"
prefs="Planer/App/TabVisibilityPreferences.swift"
section="Planer/Settings/TabBarSettingsSection.swift"
settings="Planer/Settings/SettingsView.swift"

fail=0

pass() { echo "ok:   $1"; }
bad()  { echo "FAIL: $1"; fail=1; }

require() {
    local description="$1"
    local pattern="$2"
    local file="$3"
    if [[ ! -f "$file" ]]; then
        bad "$description (Datei fehlt: $file)"
    elif grep -qE "$pattern" "$file"; then
        pass "$description"
    else
        bad "$description ($file)"
    fi
}

forbid() {
    local description="$1"
    local pattern="$2"
    local file="$3"
    if [[ ! -f "$file" ]]; then
        bad "$description (Datei fehlt: $file)"
    elif grep -qE "$pattern" "$file"; then
        bad "$description ($file)"
    else
        pass "$description"
    fi
}

# Gibt den Rumpf des Members aus, dessen Deklaration `name` enthält. Die
# Klammer-Bilanz bestimmt das Ende; so bleibt die Prüfung an der Funktion und
# nicht an einer zufälligen Zeilennummer.
member_body() {
    local file="$1" name="$2"
    awk -v name="$name" '
        !started && index($0, name) { started = 1 }
        !started { next }
        {
            print
            depth += gsub(/\{/, "{") - gsub(/\}/, "}")
            if (depth > 0) opened = 1
            if (opened && depth == 0) exit
        }
    ' "$file"
}

# --- 1. Sektion und Schalter ------------------------------------------------

require "SettingsView zeigt die Sektion Tab-Bar" \
    'TabBarSettingsSection\(\)' "$settings"

require "Sektion hat den Titel „Tab-Bar“" \
    'Text\("Tab-Bar"\)' "$section"

require "Sektion bietet Schalter" \
    'Toggle\(' "$section"

require "Schalter stammen aus der Liste der abwählbaren Tabs" \
    'ForEach\(AppTab\.hideableTabs' "$section"

require "Schalter schreiben über die Präferenz" \
    'preferences\.setVisible' "$section"

for title in 'To-Dos' 'Einkauf' 'Rezepte'; do
    require "Titel „$title“ ist als Tab-Titel definiert" \
        "return \"$title\"" "$registry"
done

forbid "kein Schalter für Chat" \
    'Toggle\("Chat' "$section"
forbid "kein Schalter für Einstellungen" \
    'Toggle\("Einstellungen' "$section"
forbid "Sektion zählt nicht alle Tabs auf" \
    'AppTab\.allCases' "$section"

# --- 2. Dauerhafte Speicherung ----------------------------------------------

require "Präferenz-Klasse existiert" \
    'final class TabVisibilityPreferences' "$prefs"
require "Wert liegt in UserDefaults" \
    'UserDefaults' "$prefs"
require "fester Schlüssel für die Auswahl" \
    'static let key = "hiddenAppTabs"' "$prefs"
require "Lesen aus UserDefaults" \
    'stringArray\(forKey: Self\.key\)' "$prefs"
require "Schreiben in UserDefaults" \
    'defaults\.set\(' "$prefs"
forbid "kein flüchtiger @State in der Präferenz" \
    '@State[[:space:]]' "$prefs"
forbid "kein zweiter Speicherweg über @AppStorage" \
    '@AppStorage' "$prefs"

require "AppRootView beobachtet die gespeicherte Auswahl" \
    '@ObservedObject private var tabVisibility = TabVisibilityPreferences\.shared' "$view"

# --- 3. Chat und Einstellungen bleiben --------------------------------------

require "To-Dos, Einkauf und Rezepte sind abwählbar" \
    'case \.todos, \.grocery, \.recipes: return true' "$registry"
require "Chat und Einstellungen sind nicht abwählbar" \
    'case \.chat, \.settings: return false' "$registry"
require "abwählbare Liste filtert über isHideable" \
    'allCases\.filter\(\\\.isHideable\)' "$registry"

# --- 4. Beide Tab-Bar-Zweige ------------------------------------------------

modern="$(member_body "$view" 'private var modernTabs')"
legacy="$(member_body "$view" 'private var legacyTabs')"

if [[ -z "$modern" ]]; then
    bad "iOS-18-Zweig modernTabs gefunden"
else
    pass "iOS-18-Zweig modernTabs gefunden"
    if grep -qE 'tabVisibility\.visibleTabs' <<<"$modern"; then
        pass "iOS-18-Zweig rendert die sichtbaren Tabs"
    else
        bad "iOS-18-Zweig rendert die sichtbaren Tabs"
    fi
    if grep -qE 'Tab\(value: tab\)' <<<"$modern"; then
        pass "iOS-18-Zweig nutzt die Tab-API"
    else
        bad "iOS-18-Zweig nutzt die Tab-API"
    fi
fi

if [[ -z "$legacy" ]]; then
    bad "Legacy-Zweig legacyTabs gefunden"
else
    pass "Legacy-Zweig legacyTabs gefunden"
    if grep -qE 'tabVisibility\.visibleTabs' <<<"$legacy"; then
        pass "Legacy-Zweig rendert die sichtbaren Tabs"
    else
        bad "Legacy-Zweig rendert die sichtbaren Tabs"
    fi
    if grep -qE '\.tabItem' <<<"$legacy" && grep -qE '\.tag\(tab\)' <<<"$legacy"; then
        pass "Legacy-Zweig nutzt .tabItem und .tag"
    else
        bad "Legacy-Zweig nutzt .tabItem und .tag"
    fi
fi

forbid "AppRootView zählt nicht alle Tabs auf" \
    'AppTab\.allCases' "$view"
forbid "kein fest verdrahteter Tab mit Titel" \
    'Tab\("' "$view"

# --- 5. Rückfall der Auswahl ------------------------------------------------

fallback="$(member_body "$view" 'private func reconcileSelection')"

if [[ -z "$fallback" ]]; then
    bad "Rückfall-Funktion reconcileSelection gefunden"
else
    pass "Rückfall-Funktion reconcileSelection gefunden"
    if grep -qE 'tabVisibility\.isVisible\(selection\)' <<<"$fallback"; then
        pass "Rückfall prüft den ausgewählten Tab"
    else
        bad "Rückfall prüft den ausgewählten Tab"
    fi
    if grep -qE 'selection = \.chat' <<<"$fallback"; then
        pass "Rückfall wechselt auf Chat"
    else
        bad "Rückfall wechselt auf Chat"
    fi
fi

require "Rückfall läuft beim Erscheinen" \
    '\.onAppear\(perform: reconcileSelection\)' "$view"
require "Rückfall läuft bei geänderter Auswahl" \
    '\.onChange\(of: tabVisibility\.hiddenTabs\)' "$view"

# ---------------------------------------------------------------------------
if [[ "$fail" -ne 0 ]]; then
    echo "Ergebnis: FEHLGESCHLAGEN"
    exit 1
fi
echo "Ergebnis: OK"
