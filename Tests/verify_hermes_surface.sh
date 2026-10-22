#!/usr/bin/env bash
#
# Statischer Regressionstest für MARAAA-159 (Hermes-Oberflächen-Diagnose):
#   (1) `Planer/Networking/HermesSurface.swift` existiert, dekodiert
#       `/api/status` (`HermesDashboardStatus`, `listener_base`) und bietet die
#       reinen Funktionen `isLoopbackListener`/`classify`.
#   (2) Die Bindungserkennung behandelt `127.0.0.1`, `localhost` und `::1` als
#       Loopback; `0.0.0.0` ist **nicht** Loopback, sondern „alle Interfaces“
#       (`HermesListenerScope.allInterfaces`).
#   (3) Der Hermes-Verbindungstest hat einen eigenen Pfad: `/v1/models` wird
#       vor `/api/status` gesendet, der erste Request lokal in `do/catch`
#       abgefangen, und die Diagnose **ersetzt** die Meldung, statt an
#       `connectionMessage` zu hängen. Andere Dienste senden keinen zweiten
#       Request.
#   (4) Die sechs Diagnosemeldungen stehen wörtlich im Code und sind ihren
#       Zweigen zugeordnet. Keine Meldung bietet `0.0.0.0` oder eine
#       `http://`-Adresse zum Eintragen an; `listener_base` wird interpoliert,
#       `state` nur über `lowercased()` verglichen.
#   (5) `ServiceConfiguration` erlaubt weiterhin nur `https` (Ausnahme:
#       `http` auf localhost/127.0.0.1) und hat kein pauschales `case "http":`.
#   (6) Die pbxproj enthält keinen ATS-Ausnahme-Schlüssel (MARAAA-98).
#   (7) Die Diagnose-Doku erklärt die curl-Ausgaben und die zwei zulässigen
#       Betriebsarten; der Schlüssel wird über `~/.hermes/.env` gelesen.
#
# Warum statisch: Auf diesem Prüfstand gibt es keine Swift-Toolchain; die
# übrigen WP-Abnahmen laufen ebenfalls über grep-/Schema-Prüfungen.
#
# Grenze der Prüfung: geprüft wird die Struktur (Reihenfolge der Aufrufe,
# Zweigbindung, Texte), nicht das Laufzeitverhalten. Ein echter Swift-Lauf für
# „0.0.0.0 ist nicht Loopback“ und für die drei Antwortfälle fehlt weiterhin.
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

forbid_fixed() {
    local description="$1"
    local needle="$2"
    local file="$3"
    if grep -qF -- "$needle" "$file"; then
        fail_check "$description ($file)"
    else
        pass "$description"
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

# Abschnitt ohne reine Kommentarzeilen.
strip_comments() {
    grep -v '^[[:space:]]*//' <<<"$1" || true
}

# Abschnitt ohne jeglichen Leerraum — für Prüfungen auf mehrzeilige Formen.
compact() {
    tr -d '[:space:]' <<<"$1"
}

# Die erste `return`-Zeile nach einem `case`-Label. Bindet die Meldung an genau
# ihren Zweig, auch wenn die Labels vertauscht wurden (Mutationsprobe b).
branch_return() {
    local label="$1"
    local file="$2"
    awk -v label="$label" '
        $0 ~ label { flag = 1; next }
        flag && /^[[:space:]]*return / { print; exit }
    ' "$file"
}

# Die erste `return`-Zeile nach einem `case`-Label, aber nur bis zum nächsten
# `case`. Damit prüft der Test die Zuordnung Case → Rückgabe selbst und nicht
# nur die Existenz beider Strings (Mutationsprobe: Rückgaben vertauscht).
case_return() {
    local label="$1"
    local file="$2"
    awk -v label="$label" '
        $0 ~ label { flag = 1; next }
        flag && /^[[:space:]]*case / { exit }
        flag && /^[[:space:]]*return / { print; exit }
    ' "$file"
}

# Eine mehrzeilige `if`-Bedingung ab der Startzeile bis einschließlich `{`.
condition_from() {
    local start="$1"
    local file="$2"
    awk -v start="$start" '
        $0 ~ start { flag = 1 }
        flag { printf "%s ", $0 }
        flag && /\{/ { exit }
    ' "$file"
}

surface="Planer/Networking/HermesSurface.swift"
settings="Planer/Settings/ServiceSettingsSection.swift"
configuration="Planer/Networking/ServiceConfiguration.swift"
pbx="Planer.xcodeproj/project.pbxproj"
docs="docs/hermes-405-diagnose.md"
readme="README.md"

# --- (1) Neue Datei und ihre Bestandteile ---------------------------------

if [[ -f "$surface" ]]; then
    pass "HermesSurface.swift existiert"
else
    fail_check "HermesSurface.swift existiert ($surface)"
fi

require "Status-Typ ist Decodable" \
    'struct HermesDashboardStatus: Decodable' "$surface"
require "Status-Typ ist Equatable und Sendable" \
    'struct HermesDashboardStatus: Decodable, Equatable, Sendable' "$surface"
require_fixed "Status liest listener_base" \
    'case listenerBase = "listener_base"' "$surface"
require_fixed "Status liest gateway_running" \
    'case gatewayRunning = "gateway_running"' "$surface"
require_fixed "Status liest gateway_platforms" \
    'case gatewayPlatforms = "gateway_platforms"' "$surface"
require "Oberflächen-Enum ist Equatable/Sendable" \
    'enum HermesSurface: Equatable, Sendable' "$surface"
require_fixed "Oberflächen-Fall apiServer" \
    'case apiServer' "$surface"
require_fixed "Oberflächen-Fall unreachable" \
    'case unreachable' "$surface"
surface_code="$(strip_comments "$(cat "$surface" 2>/dev/null || true)")"
expected_dashboard_case='casedashboard(apiServerState:String?,listenerBase:String?,listenerIsLoopback:Bool,listenerIsAllInterfaces:Bool)'
if [[ "$(compact "$surface_code")" == *"$expected_dashboard_case"* ]]; then
    pass "Oberflächen-Fall dashboard trägt Listener-Merkmale"
else
    fail_check "Oberflächen-Fall dashboard trägt Listener-Merkmale ($surface)"
fi
require_fixed "reine Funktion isLoopbackListener" \
    'static func isLoopbackListener(_ raw: String?) -> Bool' "$surface"
require_fixed "reine Funktion classify" \
    'static func classify(' "$surface"
require_fixed "classify nimmt den /v1/models-Status" \
    'v1ModelsStatus: Int?,' "$surface"
# Keine UI in dieser Datei: die Diagnose bleibt Foundation-only.
require_fixed "HermesSurface importiert Foundation" \
    'import Foundation' "$surface"
forbid "HermesSurface hat keine SwiftUI-Abhängigkeit" \
    '^import SwiftUI' "$surface"
forbid "HermesSurface macht keine Netzaufrufe" \
    'URLSession|sendRaw' "$surface"

# --- (2) Loopback vs. alle Interfaces -------------------------------------

scope_section="$(section_between 'static func listenerScope' 'static func classify' "$surface")"
scope_code="$(strip_comments "$scope_section")"
loopback_case="$(grep -F 'case "127.0.0.1"' <<<"$scope_code" || true)"
loopback_line="$(grep -F 'return .loopback' <<<"$scope_code" || true)"
all_case="$(grep -F 'case "0.0.0.0"' <<<"$scope_code" || true)"
all_line="$(grep -F 'return .allInterfaces' <<<"$scope_code" || true)"

if [[ -n "$loopback_case" ]] \
    && grep -qF '"127.0.0.1"' <<<"$loopback_case" \
    && grep -qF '"localhost"' <<<"$loopback_case" \
    && grep -qF '"::1"' <<<"$loopback_case" \
    && [[ -n "$loopback_line" ]]; then
    pass "Loopback umfasst 127.0.0.1, localhost und ::1"
else
    fail_check "Loopback umfasst 127.0.0.1, localhost und ::1"
fi
if [[ -n "$loopback_case" ]] && ! grep -qF '0.0.0.0' <<<"$loopback_case"; then
    pass "0.0.0.0 wird nicht als Loopback behandelt"
else
    fail_check "0.0.0.0 wird nicht als Loopback behandelt"
fi
if [[ -n "$all_case" ]] && grep -qF '0.0.0.0' <<<"$all_case" && [[ -n "$all_line" ]]; then
    pass "0.0.0.0 ist als „alle Interfaces“ erkannt"
else
    fail_check "0.0.0.0 ist als „alle Interfaces“ erkannt"
fi
# Zuordnung Case → Rückgabe, nicht nur Existenz: ein vertauschtes
# `return .loopback`/`return .allInterfaces` fällt hier auf.
loopback_scope_return="$(case_return 'case "127[.]0[.]0[.]1", "localhost", "::1":' "$surface")"
all_scope_return="$(case_return 'case "0[.]0[.]0[.]0", "::":' "$surface")"
if [[ "$(compact "$loopback_scope_return")" == 'return.loopback' ]]; then
    pass "der Loopback-Case liefert .loopback"
else
    fail_check "der Loopback-Case liefert .loopback (gefunden: ${loopback_scope_return:-nichts})"
fi
if [[ "$(compact "$all_scope_return")" == 'return.allInterfaces' ]]; then
    pass "der 0.0.0.0-Case liefert .allInterfaces"
else
    fail_check "der 0.0.0.0-Case liefert .allInterfaces (gefunden: ${all_scope_return:-nichts})"
fi
if grep -qE '^[[:space:]]*//.*0\.0\.0\.0.*nicht' <<<"$scope_section"; then
    pass "der Quelltext kommentiert 0.0.0.0 als nicht-lokal"
else
    fail_check "der Quelltext kommentiert 0.0.0.0 als nicht-lokal"
fi
if [[ "$(compact "$surface_code")" == *'staticfuncisLoopbackListener(_raw:String?)->Bool{listenerScope(raw)==.loopback}'* ]]; then
    pass "isLoopbackListener entscheidet über listenerScope"
else
    fail_check "isLoopbackListener entscheidet über listenerScope"
fi
require_fixed "eigener Fall für alle Interfaces" \
    'case allInterfaces' "$surface"

classify_section="$(section_between 'static func classify' 'private static func host' "$surface")"
classify_code="$(strip_comments "$classify_section")"
# Wirkungsvolle Assertion: die positive 2xx-Form als zusammenhängender Block.
# `!(200..<300)` oder ein invertiertes `if` erfüllt sie nicht (Review-Befund 5).
classify_api_case='ifletstatus=v1ModelsStatus,(200..<300).contains(status){return.apiServer}'
if [[ "$(compact "$classify_code")" == *"$classify_api_case"* ]]; then
    pass "classify liefert .apiServer nur bei 2xx von /v1/models"
else
    fail_check "classify liefert .apiServer nur bei 2xx von /v1/models"
fi
if grep -qF 'return .unreachable' <<<"$classify_code" \
    && grep -qF 'listenerIsLoopback: isLoopbackListener(dashboard.listenerBase)' <<<"$classify_code"; then
    pass "classify meldet dashboard/unreachable mit Listener-Merkmal"
else
    fail_check "classify meldet dashboard/unreachable mit Listener-Merkmal"
fi
if grep -qF 'isLoopbackListener' <<<"$classify_code" \
    && grep -qF 'isAllInterfacesListener' <<<"$classify_code"; then
    pass "classify nutzt beide Listener-Prüfungen"
else
    fail_check "classify nutzt beide Listener-Prüfungen"
fi

# --- (3) Eigener Hermes-Pfad: /v1/models vor /api/status ------------------

status_count="$(grep -rF '"/api/status"' Planer | wc -l | tr -d ' ')"
if [[ "$status_count" -eq 1 ]]; then
    pass "genau ein /api/status-Aufruf im App-Code"
else
    fail_check "genau ein /api/status-Aufruf im App-Code (gefunden: $status_count)"
fi

test_start="$(grep -n 'private func testConnection() async' "$settings" | head -1 | cut -d: -f1)"
if [[ -z "$test_start" ]]; then
    fail_check "testConnection ist auffindbar ($settings)"
    send_line=""
    diagnose_line=""
else
    # Erster Aufruf in testConnection ist der Hermes-Zweig; der /v1/models-Aufruf
    # muss in testHermesConnection davor liegen.
    hermes_start="$(grep -n 'private func testHermesConnection() async' "$settings" | head -1 | cut -d: -f1)"
    send_line="$(awk -v start="${hermes_start:-0}" \
        'NR >= start && /client\.sendRaw\(connectionTestRequest/ { print NR; exit }' "$settings")"
    diagnose_line="$(awk -v start="${hermes_start:-0}" \
        'NR >= start && /await hermesDashboardDiagnosis\(/ { print NR; exit }' "$settings")"
fi
if [[ -n "$send_line" && -n "$diagnose_line" && "$send_line" -lt "$diagnose_line" ]]; then
    pass "/v1/models wird vor dem /api/status-Zweig gesendet"
else
    fail_check "/v1/models wird vor dem /api/status-Zweig gesendet (send=$send_line, diagnose=$diagnose_line)"
fi
status_line="$(grep -nF 'path: "/api/status"' "$settings" | head -1 | cut -d: -f1)"
if [[ -n "$diagnose_line" && -n "$status_line" && "$diagnose_line" -lt "$status_line" ]]; then
    pass "die Diagnose ruft /api/status erst im eigenen Zweig ab"
else
    fail_check "die Diagnose ruft /api/status erst im eigenen Zweig ab (diagnose=$diagnose_line, status=$status_line)"
fi

require_fixed "eigene Funktion testHermesConnection" \
    'private func testHermesConnection() async {' "$settings"
hermes_section="$(section_between 'private func testHermesConnection' 'private func hermesDashboardDiagnosis' "$settings")"
hermes_code="$(strip_comments "$hermes_section")"
if [[ "$(compact "$hermes_code")" == *'do{letresult=tryawaitclient.sendRaw(connectionTestRequest,for:service)'* ]] \
    && [[ "$(compact "$hermes_code")" == *'catch{transportError=error}'* ]]; then
    pass "der erste Request wird lokal in do/catch abgefangen"
else
    fail_check "der erste Request wird lokal in do/catch abgefangen"
fi
if [[ "$(compact "$hermes_code")" == *'ifletdiagnosis=awaithermesDashboardDiagnosis(){message=diagnosisreturn}'* ]]; then
    pass "die Diagnose ersetzt die Meldung und kehrt vor dem Rückfall zurück"
else
    fail_check "die Diagnose ersetzt die Meldung und kehrt vor dem Rückfall zurück"
fi
forbid_fixed "die Diagnose hängt nichts an die erste Meldung an" \
    'text += " " + diagnosis' "$settings"
forbid_fixed "die Diagnose kennt keinen /v1/models-Status als Argument" \
    'hermesDashboardDiagnosis(v1ModelsStatus' "$settings"

test_section="$(section_between 'private func testConnection' 'private func testHermesConnection' "$settings")"
test_code="$(strip_comments "$test_section")"
if [[ "$(compact "$test_code")" == *'ifservice==.hermes{awaittestHermesConnection()return}'* ]]; then
    pass "nur Hermes nimmt den eigenen Verbindungspfad"
else
    fail_check "nur Hermes nimmt den eigenen Verbindungspfad"
fi
hermes_calls="$(grep -cF 'testHermesConnection()' "$settings" || true)"
if [[ "$hermes_calls" -eq 2 ]]; then
    pass "testHermesConnection wird genau einmal aufgerufen"
else
    fail_check "testHermesConnection wird genau einmal aufgerufen (Vorkommen: $hermes_calls)"
fi

diagnosis_section="$(section_between 'private func hermesDashboardDiagnosis' 'private static func dashboardMessage' "$settings")"
diagnosis_code="$(strip_comments "$diagnosis_section")"
if [[ -n "$diagnosis_code" ]] \
    && grep -qF 'path: "/api/status"' <<<"$diagnosis_code" \
    && grep -qF 'client.sendRaw(request, for: .hermes)' <<<"$diagnosis_code" \
    && grep -qF 'try? await client.sendRaw' <<<"$diagnosis_code"; then
    pass "Diagnose fragt /api/status über NetworkClient.connectionTest"
else
    fail_check "Diagnose fragt /api/status über NetworkClient.connectionTest"
fi
if grep -qF '(200..<300).contains(response.statusCode)' <<<"$diagnosis_code" \
    && grep -qF 'JSONDecoder().decode(HermesDashboardStatus.self' <<<"$diagnosis_code" \
    && grep -qF 'HermesSurface.classify(v1ModelsStatus: nil, dashboard: dashboard)' <<<"$diagnosis_code"; then
    pass "Diagnose verlangt 2xx + JSON und wertet classify aus"
else
    fail_check "Diagnose verlangt 2xx + JSON und wertet classify aus"
fi

success_section="$(section_between 'if let status, .200' 'if let status, status == 401' "$settings")"
if [[ -n "$success_section" ]] && grep -qF 'message = "Verbindung erfolgreich (Hermes-API-Server)."' <<<"$success_section"; then
    pass "Erfolg verlangt 2xx mit API-Server-JSON"
else
    fail_check "Erfolg verlangt 2xx mit API-Server-JSON"
fi
# Beide Prüfungen müssen in **derselben** `if`-Bedingung stehen. Ein entferntes
# Payload-Argument (2xx-HTML gälte dann als Erfolg) fällt hier auf.
success_condition="$(compact "$(condition_from 'if let status, .200' "$settings")")"
if [[ "$success_condition" == *'ifletstatus,'* ]] \
    && [[ "$success_condition" == *'(200..<300).contains(status)'* ]] \
    && [[ "$success_condition" == *'Self.isHermesAPIServerPayload(responseBody)'* ]]; then
    pass "Erfolgsbedingung verlangt 2xx und API-Server-JSON in derselben Bedingung"
else
    fail_check "Erfolgsbedingung verlangt 2xx und API-Server-JSON in derselben Bedingung"
fi
auth_condition="$(compact "$(condition_from 'status == 401' "$settings")")"
if [[ "$auth_condition" == *'status==401'* ]] \
    && [[ "$auth_condition" == *'Self.isGatewayAuthFailure(responseBody)'* ]]; then
    pass "401-Bedingung verlangt gateway_auth_failed in derselben Bedingung"
else
    fail_check "401-Bedingung verlangt gateway_auth_failed in derselben Bedingung"
fi
if grep -qF 'guard dashboard.gatewayPlatforms != nil || dashboard.gatewayRunning != nil else {' <<<"$diagnosis_code"; then
    pass "leerer Status-Payload ({}) wird verworfen"
else
    fail_check "leerer Status-Payload ({}) wird verworfen"
fi
require_fixed "Diagnose-Body heißt responseBody (kein Shadowing von body)" \
    'var responseBody = Data()' "$settings"
forbid_fixed "kein lokales var body in den Einstellungen" \
    'var body = Data()' "$settings"
require_fixed "API-Server-JSON wird über object/data erkannt" \
    'return object["object"] != nil || object["data"] != nil' "$settings"
require_fixed "401 gateway_auth_failed wird erkannt" \
    'text.contains("gateway_auth_failed")' "$settings"
require_fixed "401 behält die APIError-Meldung" \
    'message = APIError.hermesAPIServerKeyRequired.localizedDescription' "$settings"
require_fixed "403-Zweig der ersten Antwort" \
    'if let status, let response, status == 403 {' "$settings"
cf_section="$(section_between 'status == 403' 'if let diagnosis' "$settings")"
if [[ -n "$cf_section" ]] && grep -qF 'Self.connectionMessage(' <<<"$cf_section"; then
    pass "403 behält die Cloudflare-Meldung aus connectionMessage"
else
    fail_check "403 behält die Cloudflare-Meldung aus connectionMessage"
fi
fallback_section="$(section_between 'if let diagnosis' 'private func hermesDashboardDiagnosis' "$settings")"
if [[ -n "$fallback_section" ]] \
    && grep -qF 'Self.connectionMessage(' <<<"$fallback_section" \
    && grep -qF 'transportError?.localizedDescription' <<<"$fallback_section"; then
    pass "ohne verwertbaren Status bleibt die bisherige Meldung erhalten"
else
    fail_check "ohne verwertbaren Status bleibt die bisherige Meldung erhalten"
fi
# Nur lesend: die Auth-Logik des NetworkClient wird nicht verändert.
forbid "kein zweiter Auth-Pfad in den Einstellungen" \
    'setValue\("Bearer' "$settings"
forbid_fixed "keine zweite Keychain-Abfrage für den Diagnose-Request" \
    'keychain.value(for: .hermes' "$settings"

# --- (4) Meldungen und ihre Zweige ---------------------------------------

msg_section="$(section_between 'private static func dashboardMessage' 'private static func connectionMessage' "$settings")"
msg_code="$(strip_comments "$msg_section")"

require_fixed "Meldung: Loopback-Listener" \
    'return "Das ist das Hermes-Dashboard. Der API-Server läuft laut Status auf \(listenerBase) und ist nur auf dem Server selbst erreichbar. Die App braucht eine gemeinsame HTTPS-Adresse (hermes-front hinter dem Tunnel); Einzelheiten in docs/hermes-405-diagnose.md."' "$settings"
require_fixed "Meldung: alle Interfaces" \
    'return "Das ist das Hermes-Dashboard. Der API-Server lauscht laut Status auf allen Interfaces (\(listenerBase)). Die App braucht davor eine HTTPS-Adresse (Reverse Proxy oder Tunnel) und den API-Schlüssel."' "$settings"
require_fixed "Meldung: konkrete Adresse" \
    'return "Das ist das Hermes-Dashboard. Der API-Server läuft laut Status auf \(listenerBase). Die App braucht diese Adresse als HTTPS-Basis-URL — bei http:// zuerst TLS-Terminierung einrichten — und den API-Schlüssel."' "$settings"
require_fixed "Meldung: listener_base fehlt" \
    'return "Das ist das Hermes-Dashboard. Der Status meldet keine Adresse des API-Servers. Prüfe API_SERVER_HOST und API_SERVER_PORT."' "$settings"
require_fixed "Meldung: state fehlt" \
    'return "Das Hermes-Dashboard antwortet, meldet aber keinen Zustand des API-Servers. Prüfe, ob die api_server-Plattform aktiv ist."' "$settings"
require_fixed "Meldung: state nicht connected" \
    'return "Das Hermes-Dashboard antwortet, aber der API-Server ist nicht verbunden (state: \(trimmedState)). Starte ihn und prüfe API_SERVER_HOST und API_SERVER_KEY."' "$settings"

loopback_return="$(branch_return 'case [.]loopback:' "$settings")"
all_return="$(branch_return 'case [.]allInterfaces:' "$settings")"
other_return="$(branch_return 'case [.]other:' "$settings")"
if [[ -n "$loopback_return" ]] && grep -qF 'nur auf dem Server selbst erreichbar' <<<"$loopback_return"; then
    pass "Loopback-Meldung hängt am Loopback-Zweig"
else
    fail_check "Loopback-Meldung hängt am Loopback-Zweig"
fi
if [[ -n "$all_return" ]] && grep -qF 'auf allen Interfaces' <<<"$all_return"; then
    pass "Alle-Interfaces-Meldung hängt am allInterfaces-Zweig"
else
    fail_check "Alle-Interfaces-Meldung hängt am allInterfaces-Zweig"
fi
if [[ -n "$other_return" ]] \
    && grep -qF 'als HTTPS-Basis-URL' <<<"$other_return" \
    && grep -qF 'TLS-Terminierung einrichten' <<<"$other_return"; then
    pass "Konkrete-Adresse-Meldung nennt HTTPS-Basis-URL und TLS-Terminierung"
else
    fail_check "Konkrete-Adresse-Meldung nennt HTTPS-Basis-URL und TLS-Terminierung"
fi
if grep -qF 'switch HermesSurface.listenerScope(listenerBase)' <<<"$msg_code"; then
    pass "die Meldung entscheidet über listenerScope"
else
    fail_check "die Meldung entscheidet über listenerScope"
fi
if grep -qF '\(listenerBase)' <<<"$msg_code"; then
    pass "listener_base wird interpoliert"
else
    fail_check "listener_base wird interpoliert"
fi
if ! grep -qF '127.0.0.1:8642' <<<"$msg_code"; then
    pass "keine hartcodierte API-Server-Adresse in der Meldung"
else
    fail_check "keine hartcodierte API-Server-Adresse in der Meldung"
fi
forbid_fixed "keine 0.0.0.0-Eintragungsempfehlung" \
    '0.0.0.0. Diese Adresse' "$settings"
# Kein `http://`-Adressangebot: Ein Wert mit angehängtem Host/Port wäre eine
# nicht verbindbare Basis-URL. Der bloße Hinweis „bei http:// zuerst
# TLS-Terminierung“ ist erlaubt und wird oben separat verlangt.
if ! grep -qE 'http://[^ ]' <<<"$msg_code"; then
    pass "kein http://-Adressangebot in der Meldung"
else
    fail_check "kein http://-Adressangebot in der Meldung"
fi
require_fixed "state wird kleingeschrieben verglichen" \
    'let normalizedState = trimmedState.lowercased()' "$settings"
if grep -qF 'normalizedState == "connected"' <<<"$msg_code" \
    && ! grep -qF 'state == "connected"' <<<"$msg_code"; then
    pass "kein state-Vergleich ohne lowercased()"
else
    fail_check "kein state-Vergleich ohne lowercased()"
fi
if grep -qF 'guard !normalizedState.isEmpty else {' <<<"$msg_code"; then
    pass "ein fehlender state wird nicht als nicht verbunden behauptet"
else
    fail_check "ein fehlender state wird nicht als nicht verbunden behauptet"
fi

require_fixed "Erfolgsmeldung bleibt unverändert" \
    'return "Verbindung erfolgreich (Hermes-API-Server)."' "$settings"
require_fixed "401-Meldung bleibt erhalten" \
    'return "Zugriff verweigert (401): \(tokenName(for: service)) fehlt oder ist ungültig."' "$settings"
require_fixed "405-Meldung bleibt erhalten" \
    'Das ist das Hermes-Dashboard, nicht der API-Server: POST ist dort nicht erlaubt.' "$settings"
require_fixed "404-Meldung für Hermes bleibt erhalten" \
    'Pfad falsch — Hermes erwartet den Origin ohne Pfad.' "$settings"
# Der 3xx-Text in `connectionMessage` ist für den Hermes-Verbindungstest nicht
# mehr erreichbar (testHermesConnection fängt 3xx lokal ab); er bleibt nur als
# Rückfall im gemeinsamen Übersetzer. Er wird darum nicht als Hermes-Verhalten
# zugesichert (Review-Befund 1d).

# --- (5) HTTPS-Regel unverändert ------------------------------------------

require_fixed "http bleibt auf localhost/127.0.0.1 beschränkt" \
    'case "http" where host == "localhost" || host == "127.0.0.1":' "$configuration"
forbid_fixed "kein pauschales case http" \
    'case "http":' "$configuration"
require_fixed "https bleibt der Regelfall" \
    'case "https":' "$configuration"

# --- (6) Keine ATS-Ausnahme in der pbxproj --------------------------------

for key in NSAllowsArbitraryLoads NSExceptionDomains NSAllowsLocalNetworking NSAllowsArbitraryLoadsInWebContent; do
    forbid_fixed "pbxproj ohne $key" "$key" "$pbx"
done

# --- (7) Dokumentation ----------------------------------------------------

require_fixed "Doku-Abschnitt zu den curl-Ausgaben" \
    '## Was die curl-Ausgaben bedeuten' "$docs"
require_fixed "Doku-Tabelle mit Aufruf/Antwort/Bedeutung" \
    '| Aufruf | Antwort | Bedeutung |' "$docs"
for needle in listener_base API_SERVER_HOST 9180 8642 'http://localhost:9180'; do
    require_fixed "Doku nennt $needle" "$needle" "$docs"
done
require_fixed "Doku nennt das Dashboard-Statusfeld" \
    'gateway_platforms.api_server.listener_base' "$docs"
require_fixed "Doku liest den Schlüssel aus der .env" \
    "grep '^API_SERVER_KEY=' ~/.hermes/.env | cut -d= -f2-" "$docs"
require_fixed "Doku nennt die irreführende config-Antwort" \
    'Config key not set: API_SERVER_KEY' "$docs"
require_fixed "Doku warnt vor 0.0.0.0 als Basis-URL" \
    '0.0.0.0` ist keine verbindbare Adresse' "$docs"
require_fixed "README verweist auf die Diagnose" \
    'docs/hermes-405-diagnose.md' "$readme"
require_fixed "README nennt die Status-Auswertung" \
    'GET /api/status' "$readme"
require_fixed "README nennt listener_base" \
    'listener_base' "$readme"
forbid_fixed "README behauptet keinen API_SERVER_HOST-Hinweis in der Meldung" \
    'nennt die Meldung den Hermes-Default' "$readme"

if [[ "$fail" -ne 0 ]]; then
    echo "Ergebnis: FEHLGESCHLAGEN"
    exit 1
fi

echo "Ergebnis: OK"
