#!/usr/bin/env bash
#
# Statischer Regressionstest für MARAAA-92 (Review-Befunde 4 und 9):
#   (a) `appLockEnabled` wird ausgewertet: ein Gate sperrt Start und Vordergrund.
#   (b) Basis-URLs sind ausschließlich https; keine ATS-Ausnahme nötig.
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
gate="Planer/Settings/AppLockGate.swift"
section="Planer/Settings/AppLockSection.swift"
configuration="Planer/Networking/ServiceConfiguration.swift"
settings="Planer/Settings/ServiceSettingsSection.swift"
pbx="Planer.xcodeproj/project.pbxproj"

# --- (a) App-Lock-Gate ------------------------------------------------------

require "PlanerApp hängt den Root-View hinter AppLockGate" \
    'AppLockGate \{' "$app"
require "AppRootView wird nur noch innerhalb des Gates erzeugt" \
    '^[[:space:]]+AppRootView\(\)' "$app"

gate_line="$(grep -n 'AppLockGate {' "$app" | head -1 | cut -d: -f1)" || true
root_line="$(grep -n 'AppRootView()' "$app" | head -1 | cut -d: -f1)" || true
if [[ -n "$gate_line" && -n "$root_line" && "$gate_line" -lt "$root_line" ]]; then
    pass "Gate umschließt den Root-View"
else
    fail_check "Gate umschließt den Root-View (gate=$gate_line, root=$root_line)"
fi

require "Gate liest denselben UserDefaults-Schlüssel wie der Schalter" \
    '@AppStorage\("appLockEnabled"\)' "$gate"
require "gesperrter Zustand verdeckt den Inhalt" \
    'if appLockEnabled && !isUnlocked' "$gate"
require "Gate beobachtet den App-Lebenszyklus" \
    '@Environment\(\\\.scenePhase\)' "$gate"

# Beim Verlassen der App muss der Sperrzustand zurückgesetzt werden.
background_line="$(grep -n 'case \.background:' "$gate" | head -1 | cut -d: -f1)" || true
relock_line="$(awk -v start="${background_line:-0}" 'NR > start && /isUnlocked = false/ { print NR; exit }' "$gate")" || true
if [[ -n "$background_line" && -n "$relock_line" && "$background_line" -lt "$relock_line" ]]; then
    pass "Hintergrundwechsel sperrt wieder"
else
    fail_check "Hintergrundwechsel sperrt wieder (background=$background_line, relock=$relock_line)"
fi

active_line="$(grep -n 'case \.active:' "$gate" | head -1 | cut -d: -f1)" || true
unlock_line="$(grep -n 'await unlockIfNeeded()' "$gate" | tail -1 | cut -d: -f1)" || true
if [[ -n "$active_line" && -n "$unlock_line" && "$active_line" -lt "$unlock_line" ]]; then
    pass "Rückkehr in den Vordergrund verlangt erneut die Prüfung"
else
    fail_check "Rückkehr in den Vordergrund verlangt erneut die Prüfung (active=$active_line, unlock=$unlock_line)"
fi

require "Gate nutzt Biometrie mit Gerätecode-Fallback" \
    '\.deviceOwnerAuthentication' "$gate"
require "Erfolg entsperrt nur bei true" \
    'isUnlocked = success' "$gate"
forbid "kein unbedingtes Entsperren im Fehlerpfad" \
    'catch \{[^}]*isUnlocked = true' "$gate"
require "Sperrbildschirm bietet einen erneuten Versuch" \
    'Task \{ await authenticate\(\) \}' "$gate"
require "Schalter prüft beim Einschalten weiterhin den Eigentümer" \
    'await verifyOwner\(\)' "$section"

# --- (b) Nur https, keine ATS-Ausnahme -------------------------------------

forbid "ServiceConfiguration akzeptiert kein http mehr" \
    'scheme == "http"' "$configuration"
require "ServiceConfiguration verlangt https" \
    'scheme == "https"' "$configuration"
forbid "kein http-oder-https-Zweig" \
    'scheme == "https" \|\| scheme == "http"' "$configuration"
require "eine gemeinsame URL-Prüfung existiert" \
    'static func validateBaseURL' "$configuration"
require "Laden nutzt die gemeinsame URL-Prüfung" \
    'validateBaseURL\(rawBaseURL' "$configuration"
require "Speichern prüft die Basis-URL vor dem Ablegen" \
    'ServiceConfiguration\.validateBaseURL' "$settings"

forbid "keine ATS-Ausnahme in der generierten Info.plist" \
    'NSAllowsArbitraryLoads|NSExceptionDomains|NSAllowsLocalNetworking' "$pbx"

if [[ "$fail" -ne 0 ]]; then
    echo "Ergebnis: FEHLGESCHLAGEN"
    exit 1
fi

echo "Ergebnis: OK"
