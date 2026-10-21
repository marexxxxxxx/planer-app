#!/usr/bin/env bash
#
# Statischer Regressionstest für MARAAA-133 (Diagnose MARAAA-132, §5 B1/B2/B9,
# §8 F1/F6, §10):
#   (1) Ein Helper normalisiert die Basis-URL: Mealie/Grocy/Dashboard bekommen
#       `/api`, Hermes verliert nur ein abschließendes `/api` und lehnt jeden
#       anderen Pfad sichtbar ab (MARAAA-142); gespeicherte URLs werden beim
#       Laden normalisiert.
#   (2) Die Einstellungs-Sektion nennt je Dienst ein Beispiel.
#   (3) „Test Verbindung“ ruft je Dienst einen fachlichen Endpunkt ab; Erfolg
#       nur bei 2xx **und** JSON, sonst konkreter Token-/CF-/Pfad-Hinweis.
#   (4) `NetworkClient` wiederholt ausschließlich GET (F6).
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

require_fixed() {
    local description="$1"
    local needle="$2"
    local file="$3"
    if grep -qF -- "$needle" "$file"; then
        pass "$description"
    else
        fail_check "$description ($file)"
    fi
}

line_of() {
    grep -nE "$1" "$2" | head -1 | cut -d: -f1
}

configuration="Planer/Networking/ServiceConfiguration.swift"
settings="Planer/Settings/ServiceSettingsSection.swift"
client="Planer/Networking/NetworkClient.swift"
retry="Planer/Networking/RetryPolicy.swift"
api_error="Planer/Networking/APIError.swift"
service_type="Planer/Networking/ServiceType.swift"

# --- (1) Basis-URL normalisieren -------------------------------------------

require "ein gemeinsamer Normalisierungs-Helper existiert" \
    'static func normalizeBaseURL' "$configuration"
require "Laden aus der Keychain normalisiert" \
    'normalizeBaseURL\(rawBaseURL' "$configuration"
require "Normalisierung prüft zuerst die Transport-Regel" \
    'validateBaseURL\(rawValue, for: service\)' "$configuration"
require "abschließende Schrägstriche werden entfernt" \
    'path\.hasSuffix\("/"\)' "$configuration"
require "Mealie/Grocy/Dashboard hängen /api an" \
    'path \+= "/api"' "$configuration"
require "das Anhängen prüft das /api-Ende" \
    'hasSuffix\("/api"\)' "$configuration"

# Der Hermes-Zweig darf den Pfad nicht mehr pauschal leeren (MARAAA-142):
# ein abschließendes `/api` wird entfernt, jeder andere Pfad abgelehnt. Der
# Ausschnitt reicht vom `case .hermes:` bis zum Ende des switch-Blocks.
hermes_branch="$(awk '/case \.hermes:/{flag=1} flag{print} flag && /^        }/{exit}' \
    "$configuration")" || true
if [[ -n "$hermes_branch" ]] && grep -qE 'if path == "/api" \{' <<<"$hermes_branch"; then
    pass "Hermes entfernt nur ein abschließendes /api"
else
    fail_check "Hermes entfernt nur ein abschließendes /api"
fi
if grep -qE 'throw ServiceConfigurationError\.unexpectedPath' <<<"$hermes_branch"; then
    pass "Hermes lehnt einen fremden Pfad sichtbar ab"
else
    fail_check "Hermes lehnt einen fremden Pfad sichtbar ab"
fi
api_guard_line="$(grep -nE 'if path == "/api" \{' <<<"$hermes_branch" | head -1 | cut -d: -f1)" || true
wipe_line="$(grep -nE 'path = ""' <<<"$hermes_branch" | head -1 | cut -d: -f1)" || true
if [[ -n "$api_guard_line" && -n "$wipe_line" && "$api_guard_line" -lt "$wipe_line" ]]; then
    pass "Leeren des Pfads steht hinter der /api-Prüfung"
else
    fail_check "Leeren des Pfads steht hinter der /api-Prüfung (api=$api_guard_line, wipe=$wipe_line)"
fi
if grep -qE 'path \+= "/api"' <<<"$hermes_branch"; then
    fail_check "Hermes bekommt kein /api angehängt"
else
    pass "Hermes bekommt kein /api angehängt"
fi
require_fixed "Pfad-Ablehnung ist als Fehlertext formuliert" \
    "erwartet den Origin ohne Pfad" "$configuration"

require "Einstellungen normalisieren die gespeicherte URL beim Laden" \
    'normalizeBaseURL\(storedBaseURL' "$settings"
require "ungültige gespeicherte URL bleibt zur Korrektur sichtbar" \
    'baseURL = storedBaseURL' "$settings"
require "Speichern legt die normalisierte URL ab" \
    'keychain\.set\(normalized\.absoluteString' "$settings"
forbid "kein Ablegen der rohen Basis-URL mehr" \
    'persist\(baseURL' "$settings"

normalize_line="$(line_of 'normalizeBaseURL\(trimmedBaseURL' "$settings")" || true
set_line="$(awk -v start="${normalize_line:-0}" \
    'NR > start && /keychain\.set\(normalized\.absoluteString/ { print NR; exit }' \
    "$settings")" || true
if [[ -n "$normalize_line" && -n "$set_line" && "$normalize_line" -lt "$set_line" ]]; then
    pass "Normalisierung liegt vor dem Schreiben"
else
    fail_check "Normalisierung liegt vor dem Schreiben (normalize=$normalize_line, set=$set_line)"
fi

# --- (2) Beispiele je Dienst ------------------------------------------------

require_fixed "Beispiel für Mealie/Grocy/Dashboard: https://host" \
    "https://host" "$settings"
require_fixed "Beispiel nennt automatisches /api" \
    "/api automatisch" "$settings"
require_fixed "Beispiel für Hermes: https://hermes.example.com" \
    "https://hermes.example.com" "$settings"
require_fixed "Hermes-Beispiel verlangt den Origin ohne Pfad" \
    "ohne Pfad" "$settings"

# --- (3) Fachlicher Verbindungstest ---------------------------------------

require "Test Verbindung nutzt den Roh-Response" \
    'client\.sendRaw\(connectionTestRequest' "$settings"
require "Mealie fragt /recipes ab" \
    'path: "/recipes"' "$settings"
require "Mealie begrenzt auf ein Rezept" \
    'name: "perPage", value: "1"' "$settings"
require "Grocy fragt /objects/products ab" \
    'path: "/objects/products"' "$settings"
require "Dashboard fragt /tasks ab" \
    'path: "/tasks"' "$settings"
require "Dashboard begrenzt auf eine Aufgabe" \
    'name: "limit", value: "1"' "$settings"
require "Hermes fragt /api/sessions ab" \
    'path: "/api/sessions"' "$settings"

require "Erfolg verlangt 2xx" \
    '\(200\.\.<300\)\.contains\(status\)' "$settings"
require "Erfolg verlangt JSON" \
    'JSONSerialization\.jsonObject\(with: data\)' "$settings"
require "Erfolg wird erst nach der JSON-Prüfung gemeldet" \
    'guard isJSON\(data\)' "$settings"

json_line="$(line_of 'guard isJSON\(data\)' "$settings")" || true
success_line="$(line_of 'Verbindung erfolgreich\.' "$settings")" || true
if [[ -n "$json_line" && -n "$success_line" && "$json_line" -lt "$success_line" ]]; then
    pass "„Verbindung erfolgreich“ liegt hinter der JSON-Prüfung"
else
    fail_check "„Verbindung erfolgreich“ liegt hinter der JSON-Prüfung (json=$json_line, success=$success_line)"
fi

html_line="$(line_of 'guard !looksLikeHTML\(data, response: response\)' "$settings")" || true
if [[ -n "$html_line" && -n "$success_line" && "$html_line" -lt "$success_line" ]]; then
    pass "HTML kann nicht als Erfolg durchgehen"
else
    fail_check "HTML kann nicht als Erfolg durchgehen (html=$html_line, success=$success_line)"
fi

require "401 nennt das Token" \
    'status == 401' "$settings"
require "401 nennt fehlendes/ungültiges Token" \
    'fehlt oder ist ungültig' "$settings"
require "403 wird als Cloudflare Access gemeldet" \
    'status == 403' "$settings"
require "HTML wird als Cloudflare Access gemeldet" \
    'looksLikeHTML\(data, response: response\)' "$settings"
require_fixed "CF-Hinweis ist eindeutig formuliert" \
    "Cloudflare Access: Service-Token fehlt oder ungültig." "$settings"
require "302 auf cloudflareaccess.com wird erkannt" \
    'location\.contains\("cloudflareaccess\.com"\)' "$settings"
require "404 nennt den Pfad-Hinweis" \
    'status == 404' "$settings"
# Die 404-Antwort ist dienstspezifisch (MARAAA-142): Hermes erwartet den
# Origin, die übrigen Dienste enden auf `/api`. Der Ausschnitt reicht vom
# 404-Zweig bis zu dessen schließender Klammer.
path_hint_branch="$(awk '/if status == 404 \{/{flag=1} flag{print} flag && /^        \}/{exit}' \
    "$settings")" || true
if [[ -n "$path_hint_branch" ]] \
    && grep -qF 'case .hermes:' <<<"$path_hint_branch" \
    && grep -qF 'Pfad falsch — Hermes erwartet den Origin ohne Pfad.' <<<"$path_hint_branch"; then
    pass "Hermes-404 nennt den Origin ohne Pfad"
else
    fail_check "Hermes-404 nennt den Origin ohne Pfad"
fi
if [[ -n "$path_hint_branch" ]] \
    && grep -qF 'case .mealie, .grocy, .dashboard:' <<<"$path_hint_branch" \
    && grep -qF 'Pfad falsch, /api prüfen.' <<<"$path_hint_branch"; then
    pass "404 der übrigen Dienste nennt /api"
else
    fail_check "404 der übrigen Dienste nennt /api"
fi
hermes_hint_line="$(grep -nF 'Pfad falsch — Hermes erwartet den Origin ohne Pfad.' <<<"$path_hint_branch" | head -1 | cut -d: -f1)" || true
api_hint_line="$(grep -nF 'Pfad falsch, /api prüfen.' <<<"$path_hint_branch" | head -1 | cut -d: -f1)" || true
if [[ -n "$hermes_hint_line" && -n "$api_hint_line" && "$hermes_hint_line" -lt "$api_hint_line" ]]; then
    pass "Hermes-404 liegt im Hermes-Zweig vor dem /api-Hinweis"
else
    fail_check "Hermes-404 liegt im Hermes-Zweig vor dem /api-Hinweis (hermes=$hermes_hint_line, api=$api_hint_line)"
fi

require "Redirects werden nicht verfolgt" \
    'willPerformHTTPRedirection' "$client"
require "Redirect-Antwort erreicht den Aufrufer" \
    'completionHandler\(nil\)' "$client"
require "Roh-Response liefert Status und Body" \
    'func sendRaw' "$client"

# Die URL darf erst nach der Normalisierung gespeichert werden: `persistFields`
# normalisiert intern, `testConnection` ruft es vor `sendRaw` auf.
test_line="$(line_of 'private func testConnection\(\) async' "$settings")" || true
persist_line="$(awk -v start="${test_line:-0}" \
    'NR > start && /try persistFields\(\)/ { print NR; exit }' "$settings")" || true
send_line="$(line_of 'client\.sendRaw\(connectionTestRequest' "$settings")" || true
if [[ -n "$persist_line" && -n "$send_line" && "$persist_line" -lt "$send_line" ]]; then
    pass "Speichern der normalisierten URL liegt vor dem Verbindungstest"
else
    fail_check "Speichern der normalisierten URL liegt vor dem Verbindungstest (persist=$persist_line, send=$send_line)"
fi

# --- (4) Retry nur für GET -------------------------------------------------

require "Retry prüft die HTTP-Methode" \
    'request\.httpMethod == HTTPMethod\.get\.rawValue' "$client"
require "Retry-Regel bleibt in RetryPolicy" \
    'func shouldRetry' "$retry"

retry_calls="$(grep -cE 'retryPolicy\.shouldRetry' "$client")" || true
if [[ "$retry_calls" -eq 1 ]]; then
    pass "genau eine Retry-Entscheidung im NetworkClient"
else
    fail_check "genau eine Retry-Entscheidung im NetworkClient (gefunden: $retry_calls)"
fi

wait_calls="$(grep -cE 'waitBeforeRetry\(' "$client")" || true
if [[ "$wait_calls" -ge 3 ]]; then
    pass "Transportfehler und Fehlerstatus laufen beide über die GET-Prüfung"
else
    fail_check "Transportfehler und Fehlerstatus laufen beide über die GET-Prüfung (Aufrufe: $wait_calls)"
fi
require "5xx laufen durch dieselbe Retry-Entscheidung" \
    'retryAfter: Self\.retryAfter\(from: http\)' "$client"
forbid "kein alter Retry-Helfer ohne Methodenprüfung" \
    'func retry\(' "$client"

# Die Fehlerpfade des Verbindungstests dürfen nicht als Erfolg enden.
forbid "kein pauschales „erreichbar“ mehr" \
    'Dienst erreichbar' "$settings"

if [[ "$fail" -ne 0 ]]; then
    echo "Ergebnis: FEHLGESCHLAGEN"
    exit 1
fi

echo "Ergebnis: OK"
