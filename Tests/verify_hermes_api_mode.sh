#!/usr/bin/env bash
#
# Statischer Regressionstest für die zweite Hermes-Betriebsart (API-Server):
#   (1) `ServiceConfiguration.hermesUsesAPIToken` existiert und hängt an einem
#       hinterlegten `.apiToken`.
#   (2) `injectHeaders` setzt im Token-Modus `Authorization: Bearer`, aber
#       keinen `Cookie`-Header; der Cookie-Modus bleibt der else-Zweig.
#   (3) `loginHermes` bricht im Token-Modus sofort ab — kein Password-Login
#       gegen den API-Server (dort fehlt `/auth/password-login`).
#   (4) Der Re-Login ist im Token-Modus auf beiden Wegen ausgeschlossen
#       (`performRaw`, `performStream`); 401 kommt als `.unauthorized`, ein 3xx
#       bleibt ein Redirect-Fehler.
#   (5) `APIError.methodNotAllowed` existiert, wird auf 405 abgebildet und
#       nennt Dashboard und Port 8642.
#   (6) Einstellungen: eigenes SecureField für den API-Schlüssel, Persistenz
#       auf `.apiToken`, Verbindungstest gegen `/v1/models`.
#   (7) Die 405-Meldung des Verbindungstests nennt Dashboard und Port 8642.
#   (8) Das README dokumentiert `API_SERVER_KEY` und den 405-Zusammenhang.
#   (9) Jeder Hermes-Request trägt `X-Hermes-Client: planer`: die Zuweisung
#       steht im Hermes-Zweig von `injectHeaders` und **vor** der
#       `hermesUsesAPIToken`-Verzweigung, wirkt also im Token- und im
#       Cookie-Modus. Mealie, Grocy und Dashboard senden den Header nicht.
#   (10) Ein 401 des Hermes-API-Servers (`gateway_auth_failed`) wird zu
#       `APIError.hermesAPIServerKeyRequired` (Status 401, nicht
#       wiederholbar), nennt `API_SERVER_KEY` und wird in `ChatViewModel.describe`
#       vor dem allgemeinen `unauthorized`-Fall mit eigener Meldung behandelt.
#
# Warum statisch: Auf diesem Prüfstand gibt es keine Swift-Toolchain; die
# übrigen Abnahmen laufen ebenfalls über grep-/Schema-Prüfungen.
#
# Grenze der Prüfung: geprüft wird die Struktur der Zweige, nicht das
# Laufzeitverhalten. Abschnitte werden vor dem Match um reine Kommentarzeilen
# bereinigt, damit ein auskommentierter Aufruf keine Prüfung erfüllt.
#
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$root"

fail=0

pass() { echo "ok:   $1"; }
fail_check() { echo "FAIL: $1"; fail=1; }

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

# Zeilen eines Abschnitts: ab der Startzeile bis ausschließlich zur Stopzeile.
section_between() {
    local start="$1"
    local stop="$2"
    local file="$3"
    awk -v start="$start" -v stop="$stop" '
        $0 ~ start { flag = 1 }
        flag && $0 ~ stop { exit }
        flag { print }
    ' "$file"
}

# Derselbe Abschnitt, aber aus einer bereits eingelesenen Zeichenkette.
section_text() {
    local start="$1"
    local stop="$2"
    awk -v start="$start" -v stop="$stop" '
        $0 ~ start { flag = 1 }
        flag && $0 ~ stop { exit }
        flag { print }
    '
}

# Abschnitt ohne reine Kommentarzeilen.
strip_comments() {
    grep -v '^[[:space:]]*//' <<<"$1" || true
}

# Abschnitt ohne jeglichen Leerraum — für Prüfungen auf mehrzeilige Formen.
compact() {
    tr -d '[:space:]' <<<"$1"
}

client="Planer/Networking/NetworkClient.swift"
configuration="Planer/Networking/ServiceConfiguration.swift"
api_error="Planer/Networking/APIError.swift"
settings="Planer/Settings/ServiceSettingsSection.swift"
readme="README.md"

# --- (1) Schalter in der Konfiguration ------------------------------------

require_fixed "ServiceConfiguration liest den Hermes-API-Schlüssel" \
    'account: .apiToken' "$configuration"
config_hermes="$(strip_comments "$(section_between 'case .hermes:' 'case .dashboard:' "$configuration")")"
if grep -qF 'apiToken = normalized(try keychain.value(for: service, account: .apiToken))' <<<"$config_hermes"; then
    pass "Hermes-Zweig befüllt apiToken aus der Keychain"
else
    fail_check "Hermes-Zweig befüllt apiToken aus der Keychain ($configuration)"
fi
if grep -qF 'service == .hermes && apiToken != nil' "$configuration"; then
    pass "hermesUsesAPIToken hängt an Dienst und apiToken"
else
    fail_check "hermesUsesAPIToken hängt an Dienst und apiToken ($configuration)"
fi

# --- (2) Bearer-Zweig in injectHeaders ------------------------------------

inject_code="$(strip_comments "$(section_between 'private func injectHeaders' 'private func injectHermesCookies' "$client")")"
hermes_branch="$(section_text 'case [.]hermes:' 'case [.]grocy:' <<<"$inject_code")"
if [[ -n "$hermes_branch" ]] \
    && grep -qF 'configuration.hermesUsesAPIToken' <<<"$hermes_branch" \
    && grep -qF 'Bearer \(token)' <<<"$hermes_branch"; then
    pass "Hermes-Bearer-Zweig ist an hermesUsesAPIToken gebunden"
else
    fail_check "Hermes-Bearer-Zweig ist an hermesUsesAPIToken gebunden ($client)"
fi

token_branch="$(section_text 'if configuration.hermesUsesAPIToken' '} else [{]' <<<"$hermes_branch")"
if [[ -n "$token_branch" ]] \
    && grep -qF 'request.setValue(nil, forHTTPHeaderField: "Cookie")' <<<"$token_branch"; then
    pass "Token-Modus setzt keinen Cookie-Header"
else
    fail_check "Token-Modus setzt keinen Cookie-Header ($client)"
fi
if grep -qF 'injectHermesCookies' <<<"$token_branch"; then
    fail_check "Token-Modus ruft injectHermesCookies nicht auf ($client)"
else
    pass "Token-Modus ruft injectHermesCookies nicht auf"
fi
if grep -qE '^[[:space:]]*\} else \{' <<<"$hermes_branch" \
    && grep -qF 'injectHermesCookies(into: &request)' <<<"$hermes_branch"; then
    pass "Cookie-Modus bleibt der else-Zweig"
else
    fail_check "Cookie-Modus bleibt der else-Zweig ($client)"
fi

# --- (3) Kein Password-Login im Token-Modus -------------------------------

login_code="$(strip_comments "$(section_between 'private func loginHermes' 'private static func makeLoginBody' "$client")")"
login_guard='guard!configuration.hermesUsesAPITokenelse{return}'
if [[ "$(compact "$login_code")" == *"$login_guard"* ]]; then
    pass "loginHermes bricht im Token-Modus sofort ab"
else
    fail_check "loginHermes bricht im Token-Modus sofort ab ($client)"
fi

# --- (4) Kein Re-Login im Token-Modus -------------------------------------

perform_code="$(strip_comments "$(section_between 'private func performRaw' '// MARK: - Hermes-Anmeldung' "$client")")"
stream_code="$(strip_comments "$(section_between 'private func performStream' '// MARK: - Request-Aufbau' "$client")")"
relogin_guard='if!didRelogin,!configuration.hermesUsesAPIToken,expired||redirect'
if [[ "$(compact "$perform_code")" == *"$relogin_guard"* ]]; then
    pass "performRaw schließt den Re-Login im Token-Modus aus"
else
    fail_check "performRaw schließt den Re-Login im Token-Modus aus ($client)"
fi
if [[ "$(compact "$stream_code")" == *"$relogin_guard"* ]]; then
    pass "performStream schließt den Re-Login im Token-Modus aus"
else
    fail_check "performStream schließt den Re-Login im Token-Modus aus ($client)"
fi
if [[ "$(compact "$perform_code")" == *'ifredirect{throwSelf.hermesRedirectError(http)}'* ]] \
    && [[ "$(compact "$stream_code")" == *'ifredirect{throwSelf.hermesRedirectError(http)}'* ]]; then
    pass "ein 302 bleibt im Token-Modus ein Redirect-Fehler"
else
    fail_check "ein 302 bleibt im Token-Modus ein Redirect-Fehler ($client)"
fi
if grep -qF 'case 401:' "$api_error" && grep -qF 'return .unauthorized' "$api_error"; then
    pass "ein 401 wird weiterhin als unauthorized abgebildet"
else
    fail_check "ein 401 wird weiterhin als unauthorized abgebildet ($api_error)"
fi

# --- (5) APIError.methodNotAllowed ---------------------------------------

require_fixed "APIError hat den Fall methodNotAllowed" \
    'case methodNotAllowed' "$api_error"
require_fixed "405 wird auf methodNotAllowed abgebildet" \
    'case 405:' "$api_error"
if grep -qF 'return .methodNotAllowed' "$api_error"; then
    pass "der 405-Zweig liefert methodNotAllowed"
else
    fail_check "der 405-Zweig liefert methodNotAllowed ($api_error)"
fi
status_code="$(strip_comments "$(section_between 'var httpStatus' 'var isRetryable' "$api_error")")"
if [[ -n "$status_code" ]] && grep -qF 'return 405' <<<"$status_code"; then
    pass "methodNotAllowed trägt den Status 405"
else
    fail_check "methodNotAllowed trägt den Status 405 ($api_error)"
fi
error_text="$(strip_comments "$(section_between 'var errorDescription' 'extension APIError' "$api_error")")"
method_text="$(section_text 'case [.]methodNotAllowed:' 'case [.]conflict' <<<"$error_text")"
if [[ -n "$method_text" ]] \
    && grep -qF 'Dashboard' <<<"$method_text" \
    && grep -qF '8642' <<<"$method_text"; then
    pass "405-Text nennt Dashboard und Port 8642"
else
    fail_check "405-Text nennt Dashboard und Port 8642 ($api_error)"
fi

# --- (6) Einstellungen ----------------------------------------------------

require_fixed "Hermes zeigt das API-Schlüssel-Feld" \
    'SecureField("API-Schlüssel (API-Server, optional)", text: $hermesAPIToken)' "$settings"
require_fixed "API-Schlüssel wird getrimmt gespeichert" \
    'try persist(hermesAPIToken, account: .apiToken)' "$settings"
require_fixed "API-Schlüssel wird aus der Keychain geladen" \
    'hermesAPIToken = try keychain.value(for: service, account: .apiToken) ?? ""' "$settings"
require_fixed "Hermes-Verbindungstest nutzt /v1/models" \
    'path: "/v1/models"' "$settings"
if grep -qF 'path: "/api/sessions"' "$settings"; then
    fail_check "Hermes-Verbindungstest fragt nicht mehr /api/sessions ($settings)"
else
    pass "Hermes-Verbindungstest fragt nicht mehr /api/sessions"
fi

# --- (7) 405-Meldung des Verbindungstests ---------------------------------

message_code="$(strip_comments "$(section_between 'private static func connectionMessage' 'private static func tokenName' "$settings")")"
message_405="$(section_text 'status == 405' 'status == 404' <<<"$message_code")"
if [[ -n "$message_405" ]] \
    && grep -qF 'Dashboard' <<<"$message_405" \
    && grep -qF '8642' <<<"$message_405"; then
    pass "405-Meldung des Verbindungstests nennt Dashboard und 8642"
else
    fail_check "405-Meldung des Verbindungstests nennt Dashboard und 8642 ($settings)"
fi
require_fixed "Hermes-Erfolgstext nennt den API-Server" \
    'Verbindung erfolgreich (Hermes-API-Server).' "$settings"
require_fixed "Hermes-3xx verweist auf die API-Server-URL" \
    'Chat braucht die API-Server-URL (Port 8642).' "$settings"

# --- (8) README -----------------------------------------------------------

require_fixed "README dokumentiert API_SERVER_KEY" \
    'API_SERVER_KEY' "$readme"
require_fixed "README nennt den 405-Zusammenhang" \
    '405' "$readme"
require_fixed "README nennt den Port des API-Servers" \
    '8642' "$readme"

# --- (9) App-Marker für den vorgeschalteten Proxy -------------------------

marker_assignment='request.setValue("planer", forHTTPHeaderField: "X-Hermes-Client")'
if grep -qF "$marker_assignment" <<<"$hermes_branch"; then
    pass "Hermes-Zweig setzt X-Hermes-Client auf planer"
else
    fail_check "Hermes-Zweig setzt X-Hermes-Client auf planer ($client)"
fi

marker_line="$(grep -nF 'X-Hermes-Client' <<<"$hermes_branch" | head -n 1 | cut -d: -f1 || true)"
switch_line="$(grep -nF 'if configuration.hermesUsesAPIToken' <<<"$hermes_branch" | head -n 1 | cut -d: -f1 || true)"
if [[ -n "$marker_line" && -n "$switch_line" && "$marker_line" -lt "$switch_line" ]]; then
    pass "X-Hermes-Client steht vor der hermesUsesAPIToken-Verzweigung"
else
    fail_check "X-Hermes-Client steht vor der hermesUsesAPIToken-Verzweigung ($client)"
fi

mealie_branch="$(section_text 'case [.]mealie:' 'case [.]hermes:' <<<"$inject_code")"
grocy_branch="$(section_text 'case [.]grocy:' 'case [.]dashboard:' <<<"$inject_code")"
dashboard_branch="$(section_text 'case [.]dashboard:' '^[[:space:]]*}$' <<<"$inject_code")"
unmarked=1
for branch in "$mealie_branch" "$grocy_branch" "$dashboard_branch"; do
    [[ -n "$branch" ]] || continue
    if grep -qF 'X-Hermes-Client' <<<"$branch"; then
        unmarked=0
    fi
done
if [[ "$unmarked" -eq 1 && -n "$mealie_branch" && -n "$grocy_branch" && -n "$dashboard_branch" ]]; then
    pass "Mealie, Grocy und Dashboard senden X-Hermes-Client nicht"
else
    fail_check "Mealie, Grocy und Dashboard senden X-Hermes-Client nicht ($client)"
fi

# --- (10) 401 des API-Servers: Schlüssel statt Passwort -------------------

chat="Planer/Features/Chat/ChatViewModel.swift"

require_fixed "APIError hat den Fall hermesAPIServerKeyRequired" \
    'case hermesAPIServerKeyRequired' "$api_error"
status_code="$(strip_comments "$(section_between 'var httpStatus' 'var isRetryable' "$api_error")")"
if [[ "$(compact "$status_code")" == *'case.hermesAPIServerKeyRequired:return401'* ]]; then
    pass "hermesAPIServerKeyRequired trägt den Status 401"
else
    fail_check "hermesAPIServerKeyRequired trägt den Status 401 ($api_error)"
fi
retry_code="$(strip_comments "$(section_between 'var isRetryable' 'var retryAfter' "$api_error")")"
retry_key_line="$(grep -nF '.hermesAPIServerKeyRequired' <<<"$retry_code" | head -n 1 | cut -d: -f1 || true)"
retry_false_line="$(grep -nF 'case .conflict, .invalidConfiguration' <<<"$retry_code" | head -n 1 | cut -d: -f1 || true)"
if [[ -n "$retry_key_line" && -n "$retry_false_line" && "$retry_key_line" -gt "$retry_false_line" ]]; then
    pass "hermesAPIServerKeyRequired ist nicht wiederholbar"
else
    fail_check "hermesAPIServerKeyRequired ist nicht wiederholbar ($api_error)"
fi

from_code="$(strip_comments "$(section_between 'static func from' 'private static func decodePayload' "$api_error")")"
status_401="$(section_text 'case 401:' 'case 403:' <<<"$from_code")"
if [[ -n "$status_401" ]] \
    && grep -qF 'gateway_auth_failed' <<<"$status_401" \
    && grep -qF 'return .hermesAPIServerKeyRequired' <<<"$status_401" \
    && grep -qF 'return .unauthorized' <<<"$status_401"; then
    pass "401 mit gateway_auth_failed wird zu hermesAPIServerKeyRequired"
else
    fail_check "401 mit gateway_auth_failed wird zu hermesAPIServerKeyRequired ($api_error)"
fi

description_code="$(strip_comments "$(section_between 'var errorDescription' 'extension APIError' "$api_error")")"
key_text="$(section_text 'case [.]hermesAPIServerKeyRequired:' 'case [.]notFound:' <<<"$description_code")"
if [[ -n "$key_text" ]] \
    && grep -qF 'Hermes-API-Server: API-Schlüssel fehlt oder ist ungültig (API_SERVER_KEY).' <<<"$key_text" \
    && grep -qF 'Der Password-Login gilt nur für das Dashboard.' <<<"$key_text"; then
    pass "der Fehlertext nennt API_SERVER_KEY und die Dashboard-Grenze"
else
    fail_check "der Fehlertext nennt API_SERVER_KEY und die Dashboard-Grenze ($api_error)"
fi

describe_code="$(strip_comments "$(section_between 'private static func describe[(]_ error: APIError[)]' 'private func isCancellation' "$chat")")"
key_line="$(grep -nF 'case .hermesAPIServerKeyRequired' <<<"$describe_code" | head -n 1 | cut -d: -f1 || true)"
unauthorized_line="$(grep -nF 'case .unauthorized' <<<"$describe_code" | head -n 1 | cut -d: -f1 || true)"
if [[ -n "$key_line" && -n "$unauthorized_line" && "$key_line" -lt "$unauthorized_line" ]] \
    && grep -qF 'error.errorDescription' <<<"$(section_text 'case [.]hermesAPIServerKeyRequired:' 'case [.]unauthorized' <<<"$describe_code")"; then
    pass "ChatViewModel.describe behandelt den Fall vor unauthorized"
else
    fail_check "ChatViewModel.describe behandelt den Fall vor unauthorized ($chat)"
fi

create_code="$(strip_comments "$(section_between 'private static func isCreateFailure' 'private func streamTurn' "$chat")")"
create_own="$(section_text 'case [.]unauthorized, .forbidden' 'case [.]validation:' <<<"$create_code")"
if grep -qF '.hermesAPIServerKeyRequired' <<<"$create_own"; then
    pass "isCreateFailure behält die Meldung des API-Schlüssel-Fehlers"
else
    fail_check "isCreateFailure behält die Meldung des API-Schlüssel-Fehlers ($chat)"
fi

if [[ "$fail" -ne 0 ]]; then
    echo "Ergebnis: FEHLGESCHLAGEN"
    exit 1
fi

echo "Ergebnis: OK"
