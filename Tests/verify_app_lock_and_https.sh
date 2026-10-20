#!/usr/bin/env bash
#
# Statischer Regressionstest für MARAAA-98 (Review-Befunde N4 und N9):
#   (a) `appLockEnabled` wird im Einstiegspunkt ausgewertet: das Gate sperrt den
#       Start und den Rückwechsel in den Vordergrund.
#   (b) Basis-URLs sind ausschließlich https (Ausnahme: localhost/127.0.0.1);
#       eine http-Fremd-URL scheitert sichtbar bei der Eingabe, nicht als
#       Laufzeit-„offline“. Keine ATS-Ausnahme nötig.
#
# Warum statisch: Auf diesem Prüfstand gibt es keine Swift-Toolchain; die
# übrigen WP-Abnahmen laufen ebenfalls über grep-/Schema-Prüfungen.
#
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$root"

fail=0

pass() { echo "ok:   $1"; }
fail_check() { echo "FAIL: $1"; fail=1; }

require() {
    local description="$1"
    local pattern="$2"
    local file="$3"
    if grep -qE "$pattern" "$file"; then
        pass "$description"
    else
        fail_check "$description ($file)"
    fi
}

forbid() {
    local description="$1"
    local pattern="$2"
    local file="$3"
    if grep -qE "$pattern" "$file"; then
        fail_check "$description ($file)"
    else
        pass "$description"
    fi
}

app="Planer/App/PlanerApp.swift"
section="Planer/Settings/AppLockSection.swift"
configuration="Planer/Networking/ServiceConfiguration.swift"
settings="Planer/Settings/ServiceSettingsSection.swift"
pbx="Planer.xcodeproj/project.pbxproj"

# --- (a) App-Lock-Gate im Einstiegspunkt -----------------------------------

require "PlanerApp liest denselben UserDefaults-Schlüssel wie der Schalter" \
    '@AppStorage\("appLockEnabled"\)' "$app"
require "PlanerApp wertet appLockEnabled vor dem App-Inhalt aus" \
    'if appLockEnabled && !isUnlocked' "$app"
require "gesperrter Zustand zeigt eine Sperr-Oberfläche" \
    'Planer ist gesperrt' "$app"
require "Sperr-Oberfläche bietet einen erneuten Versuch" \
    'Task \{ await authenticate\(\) \}' "$app"

lock_line="$(grep -n 'if appLockEnabled && !isUnlocked' "$app" | head -1 | cut -d: -f1)" || true
root_line="$(grep -n 'AppRootView()' "$app" | head -1 | cut -d: -f1)" || true
if [[ -n "$lock_line" && -n "$root_line" && "$lock_line" -lt "$root_line" ]]; then
    pass "Gate umschließt den Root-View"
else
    fail_check "Gate umschließt den Root-View (gate=$lock_line, root=$root_line)"
fi

require "PlanerApp beobachtet den App-Lebenszyklus" \
    '@Environment\(\\\.scenePhase\)' "$app"
require "Gate nutzt Biometrie mit Gerätecode-Fallback" \
    '\.deviceOwnerAuthentication' "$app"
require "Erfolg entsperrt nur bei true" \
    'isUnlocked = success' "$app"
forbid "kein unbedingtes Entsperren im Fehlerpfad" \
    'catch \{[^}]*isUnlocked = true' "$app"

# Beim Verlassen der App muss der Sperrzustand zurückgesetzt werden.
background_line="$(grep -n 'case \.background:' "$app" | head -1 | cut -d: -f1)" || true
relock_line="$(awk -v start="${background_line:-0}" 'NR > start && /isUnlocked = false/ { print NR; exit }' "$app")" || true
if [[ -n "$background_line" && -n "$relock_line" && "$background_line" -lt "$relock_line" ]]; then
    pass "Hintergrundwechsel sperrt wieder"
else
    fail_check "Hintergrundwechsel sperrt wieder (background=$background_line, relock=$relock_line)"
fi

active_line="$(grep -n 'case \.active:' "$app" | head -1 | cut -d: -f1)" || true
unlock_line="$(grep -n 'await unlockIfNeeded()' "$app" | tail -1 | cut -d: -f1)" || true
if [[ -n "$active_line" && -n "$unlock_line" && "$active_line" -lt "$unlock_line" ]]; then
    pass "Rückkehr in den Vordergrund verlangt erneut die Prüfung"
else
    fail_check "Rückkehr in den Vordergrund verlangt erneut die Prüfung (active=$active_line, unlock=$unlock_line)"
fi

if [[ -f "Planer/Settings/AppLockGate.swift" ]]; then
    fail_check "kein zweites Gate neben PlanerApp (Planer/Settings/AppLockGate.swift)"
else
    pass "kein zweites Gate neben PlanerApp"
fi

require "Schalter prüft beim Einschalten weiterhin den Eigentümer" \
    'await verifyOwner\(\)' "$section"

# --- (b) Nur https, localhost-Ausnahme, keine ATS-Ausnahme ------------------

forbid "ServiceConfiguration akzeptiert kein http ohne Host-Prüfung" \
    'scheme == "http"' "$configuration"
require "ServiceConfiguration verlangt https" \
    'case "https":' "$configuration"
require "http ist nur für localhost vorgesehen" \
    'case "http" where host == "localhost"' "$configuration"
require "http ist nur für 127.0.0.1 vorgesehen" \
    'host == "127\.0\.0\.1"' "$configuration"
forbid "keine pauschale http-Freigabe" \
    'case "http":' "$configuration"
require "eine gemeinsame URL-Prüfung existiert" \
    'static func validateBaseURL' "$configuration"
require "Laden nutzt die gemeinsame URL-Prüfung" \
    'validateBaseURL\(rawBaseURL' "$configuration"
require "Ablehnung nennt die Transport-Regel" \
    'muss eine gültige https-Adresse sein' "$configuration"
require "Eingabe zeigt den Fehler sichtbar an" \
    'message = error\.localizedDescription' "$settings"
require "Eingabe prüft die Basis-URL vor dem Ablegen" \
    'ServiceConfiguration\.validateBaseURL' "$settings"

validate_line="$(grep -n 'ServiceConfiguration.validateBaseURL' "$settings" | head -1 | cut -d: -f1)" || true
persist_line="$(grep -n 'persist(baseURL' "$settings" | head -1 | cut -d: -f1)" || true
if [[ -n "$validate_line" && -n "$persist_line" && "$validate_line" -lt "$persist_line" ]]; then
    pass "Prüfung liegt im gemeinsamen Speicherpfad (auch „Test Verbindung“)"
else
    fail_check "Prüfung liegt im gemeinsamen Speicherpfad (validate=$validate_line, persist=$persist_line)"
fi

forbid "keine ATS-Ausnahme in der generierten Info.plist" \
    'NSAllowsArbitraryLoads|NSExceptionDomains|NSAllowsLocalNetworking' "$pbx"

if [[ "$fail" -ne 0 ]]; then
    echo "Ergebnis: FEHLGESCHLAGEN"
    exit 1
fi

echo "Ergebnis: OK"
