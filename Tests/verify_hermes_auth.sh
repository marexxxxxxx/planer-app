#!/usr/bin/env bash
#
# Statischer Regressionstest für MARAAA-146 (Hermes-Auth nach MARAAA-145):
#   (1) Genau ein Bearer-Set je Dienstzweig: Mealie immer, Hermes nur im
#       API-Token-Modus (`hermesUsesAPIToken`); im Cookie-Modus setzt der
#       Hermes-Zweig keinen Authorization-Header.
#   (2) Cloudflare-Access-Header auf jedem Request; der Login-Request läuft
#       durch dieselbe `injectHeaders`-Kette.
#   (3) Password-Login gegen `/auth/password-login` mit `provider` = `basic`,
#       Benutzername/Passwort aus der Keychain (`username`/`password`).
#   (4) `Set-Cookie`-Cookies werden gespeichert und als `Cookie`-Header aus
#       `HTTPCookie.requestHeaderFields(with:)` gesendet; nur Prozessspeicher.
#   (5) Genau ein Re-Login bei 401 mit den belegten `reason`/`error`-Werten.
#   (6) Gleichzeitige 401s koaleszieren zu einem Login (`actor` + `Task`).
#   (7) `send`, `sendRaw` und `stream` nutzen denselben Login-/Cookie-Pfad.
#   (8) Einstellungen: Hermes zeigt Benutzername/Passwort und zusätzlich das
#       optionale API-Schlüssel-Feld (`.apiToken`).
#   (9) Fehlertexte: Ein fehlgeschlagener Login nennt Benutzername/Passwort,
#       der 401 des Verbindungstests für Hermes den API-Schlüssel; der
#       CF-Hinweis bleibt erhalten.
#  (10) Hermes verfolgt keine Redirects; ein 3xx löst genau einen Re-Login aus,
#       die Wiederholung bleibt POST, und der Fehlertext nennt die Ursache
#       (MARAAA-154). Im API-Token-Modus ist der Re-Login ausgeschlossen; das
#       prüft `Tests/verify_hermes_api_mode.sh` zusätzlich.
#
# Warum statisch: Auf diesem Prüfstand gibt es keine Swift-Toolchain; die
# übrigen WP-Abnahmen laufen ebenfalls über grep-/Schema-Prüfungen.
#
# Grenze der Prüfung (MARAAA-149, MARAAA-152): der 401-Grundfilter wird
# strukturell über den Funktionskörper von `indicatesExpiredSession` geprüft:
# Rückgabe `false` im Guard, die **positive** Entscheidungsform über beide
# Mengen als zusammenhängender Block, kein invertiertes `return !…` und kein
# pauschales `return true`. Der Re-Login wird in `performRaw` und
# `performStream` getrennt gefordert. Abschnitte werden vor dem Match um reine
# Kommentarzeilen bereinigt, damit ein auskommentierter Aufruf keine Prüfung
# erfüllt. Ein echter Swift-Laufzeittest für „fremder Grund → kein Re-Login"
# fehlt weiterhin.
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
#
# `grep -F` matcht sonst auch `// injectHermesCookies(into: &retried)` und ein
# auskommentierter Aufruf erfüllte die Prüfung (MARAAA-152).
strip_comments() {
    grep -v '^[[:space:]]*//' <<<"$1" || true
}

# Abschnitt ohne jeglichen Leerraum — für Prüfungen auf mehrzeilige Formen.
compact() {
    tr -d '[:space:]' <<<"$1"
}

client="Planer/Networking/NetworkClient.swift"
session="Planer/Networking/HermesSession.swift"
service_type="Planer/Networking/ServiceType.swift"
configuration="Planer/Networking/ServiceConfiguration.swift"
api_error="Planer/Networking/APIError.swift"
settings="Planer/Settings/ServiceSettingsSection.swift"
chat_view_model="Planer/Features/Chat/ChatViewModel.swift"

# --- (1) Ein Bearer-Set je Dienstzweig ------------------------------------

bearer_count="$(grep -c 'Bearer' <<<"$(strip_comments "$(cat "$client")")" || true)"
if [[ "$bearer_count" -eq 2 ]]; then
    pass "genau zwei Bearer-Stellen im NetworkClient (Mealie, Hermes-Token)"
else
    fail_check "genau zwei Bearer-Stellen im NetworkClient (gefunden: $bearer_count)"
fi

mealie_branch="$(section_between 'case .mealie:' 'case .hermes:' "$client")"
if grep -qF 'Bearer \(token)' <<<"$mealie_branch"; then
    pass "Bearer bleibt im Mealie-Zweig"
else
    fail_check "Bearer bleibt im Mealie-Zweig"
fi

# Der Hermes-Zweig hat zwei Betriebsarten: Cookie (Password-Login) und Bearer
# (API-Server). Genau ein Bearer-Set, gebunden an `hermesUsesAPIToken`.
hermes_branch="$(section_between 'case .hermes:' 'case .grocy:' "$client")"
if [[ -n "$hermes_branch" ]] \
    && grep -qF 'configuration.hermesUsesAPIToken' <<<"$hermes_branch" \
    && grep -qF 'Bearer \(token)' <<<"$hermes_branch"; then
    pass "Hermes-Zweig setzt Bearer nur im API-Token-Modus"
else
    fail_check "Hermes-Zweig setzt Bearer nur im API-Token-Modus"
fi
hermes_bearer_count="$(grep -cF 'setValue("Bearer \(token)' <<<"$hermes_branch" || true)"
if [[ "$hermes_bearer_count" -eq 1 ]]; then
    pass "genau ein Bearer-Set im Hermes-Zweig"
else
    fail_check "genau ein Bearer-Set im Hermes-Zweig (gefunden: $hermes_bearer_count)"
fi
if grep -qF '} else {' <<<"$hermes_branch" \
    && grep -qF 'injectHermesCookies' <<<"$hermes_branch"; then
    pass "Hermes-Zweig setzt den Cookie-Header im Cookie-Modus"
else
    fail_check "Hermes-Zweig setzt den Cookie-Header im Cookie-Modus"
fi
if grep -qF 'case .mealie:' "$configuration" && ! grep -qF 'case .hermes, .mealie:' "$configuration"; then
    pass "API-Token wird in getrennten Dienstzweigen gelesen (Mealie, Hermes)"
else
    fail_check "API-Token wird in getrennten Dienstzweigen gelesen (Mealie, Hermes)"
fi

# --- (2) Cloudflare-Header auf jedem Request ------------------------------

require_fixed "CF-Client-ID wird in injectHeaders gesetzt" \
    'CF-Access-Client-Id' "$client"
require_fixed "CF-Client-Secret wird in injectHeaders gesetzt" \
    'CF-Access-Client-Secret' "$client"

login_section="$(section_between 'private func loginHermes' 'private static func makeLoginBody' "$client")"
if [[ -n "$login_section" ]] && grep -qF 'makeURLRequest(' <<<"$login_section"; then
    pass "Login-Request läuft durch makeURLRequest/injectHeaders"
else
    fail_check "Login-Request läuft durch makeURLRequest/injectHeaders"
fi
forbid_fixed "kein zweiter CF-Header-Ort in HermesSession" \
    'CF-Access-Client' "$session"
forbid_fixed "kein zweiter CF-Header-Ort in HermesSession (Secret)" \
    'CF-Access-Client-Secret' "$session"

# --- (3) Password-Login ---------------------------------------------------

require_fixed "Login-Pfad /auth/password-login" \
    '"/auth/password-login"' "$client"
require_fixed "Login sendet Content-Type application/json" \
    '"Content-Type": "application/json"' "$client"
require_fixed "Login-Provider ist basic" \
    'self.provider = "basic"' "$session"
require_fixed "Login-Body trägt den Benutzernamen" \
    'let username: String' "$session"
require_fixed "Login-Body trägt das Passwort" \
    'let password: String' "$session"
require_fixed "Benutzername kommt aus der Keychain" \
    'account: .username' "$configuration"
require_fixed "Passwort kommt aus der Keychain" \
    'account: .password' "$configuration"
require_fixed "ServiceCredential-Rohwert username" \
    'case username = "username"' "$service_type"
require_fixed "ServiceCredential-Rohwert password" \
    'case password = "password"' "$service_type"

if grep -qF 'HermesLoginBody(username: username, password: password)' "$client"; then
    pass "Login-Body wird aus den Keychain-Werten gebaut"
else
    fail_check "Login-Body wird aus den Keychain-Werten gebaut"
fi
forbid "kein Logging der Zugangsdaten" \
    'print\(|NSLog\(|os_log\(|Logger\(' "$client"
forbid "kein Logging der Zugangsdaten in HermesSession" \
    'print\(|NSLog\(|os_log\(|Logger\(' "$session"
forbid "keine Zugangsdaten im Fehlertext (Benutzername)" \
    '\\\(username' "$client"
forbid "keine Zugangsdaten im Fehlertext (Passwort)" \
    '\\\(password' "$client"

# --- (4) Cookies ----------------------------------------------------------

# Die beiden Wiederholungspfade werden hier einmal abgegrenzt, damit die
# Cookie-Injektion **je Pfad** geprüft werden kann: die Zeichenkette steht in
# beiden Pfaden, eine dateiweite Suche deckt eine fehlende Stelle deshalb ab
# (MARAAA-149, MARAAA-148).
perform_section="$(section_between 'private func performRaw' '// MARK: - Hermes-Anmeldung' "$client")"
stream_section="$(section_between 'private func performStream' '// MARK: - Request-Aufbau' "$client")"
perform_code="$(strip_comments "$perform_section")"
stream_code="$(strip_comments "$stream_section")"

require_fixed "Cookie-Header wird aus den gespeicherten Cookies gebaut" \
    'HTTPCookie.requestHeaderFields(with:' "$session"
require_fixed "Set-Cookie wird über HTTPCookie gelesen" \
    'withResponseHeaderFields:' "$session"
require_fixed "Cookies werden aus der Antwort gespeichert" \
    'HermesCookieJar.shared.replace(from:' "$client"
require_fixed "Hermes-Requests senden den Cookie-Header" \
    'request.setValue(cookie, forHTTPHeaderField: "Cookie")' "$client"
if grep -qF 'injectHermesCookies(into: &retried)' <<<"$stream_code"; then
    pass "der Stream sendet nach dem Re-Login den Cookie-Header"
else
    fail_check "der Stream sendet nach dem Re-Login den Cookie-Header"
fi
if grep -qF 'injectHermesCookies(into: &retried)' <<<"$perform_code"; then
    pass "performRaw sendet nach dem Re-Login den Cookie-Header"
else
    fail_check "performRaw sendet nach dem Re-Login den Cookie-Header"
fi
forbid_fixed "keine Cookie-Ablage in UserDefaults (Jar)" \
    'UserDefaults.' "$session"
forbid_fixed "keine Cookie-Ablage in UserDefaults (Client)" \
    'UserDefaults.' "$client"

# --- (5) 401-Behandlung ---------------------------------------------------

for value in no_cookie invalid_or_expired_session session_expired unauthenticated; do
    require_fixed "401-Grund $value wird erkannt" "\"$value\"" "$session"
done

# Die vier Literale oben belegen nur, dass die Werte irgendwo in der Datei
# stehen. Der Filter selbst muss sie auch auswerten — und für einen fremden
# Grund `false` liefern, für einen passenden `true`. Ohne Swift-Laufzeit
# geschieht das strukturell über den Funktionskörper von
# `indicatesExpiredSession` (MARAAA-149, MARAAA-152).
auth_filter_section="$(section_between 'static func indicatesExpiredSession' 'final class HermesCookieJar' "$session")"
auth_filter_code="$(strip_comments "$auth_filter_section")"
if grep -qF 'return false' <<<"$auth_filter_code"; then
    pass "401-Filter liefert für fremde Gründe false"
else
    fail_check "401-Filter liefert für fremde Gründe false"
fi
if grep -qF 'expiredReasons.contains(failure.reason' <<<"$auth_filter_code"; then
    pass "401-Filter entscheidet über expiredReasons"
else
    fail_check "401-Filter entscheidet über expiredReasons"
fi
if grep -qF 'expiredErrors.contains(failure.error' <<<"$auth_filter_code"; then
    pass "401-Filter entscheidet über expiredErrors"
else
    fail_check "401-Filter entscheidet über expiredErrors"
fi
if grep -qE 'return[[:space:]]+true' <<<"$auth_filter_code"; then
    fail_check "401-Filter löst nicht pauschal für jeden 401 aus"
else
    pass "401-Filter löst nicht pauschal für jeden 401 aus"
fi

# Die Richtung der Entscheidung: die positive Form muss als zusammenhängender
# Block dastehen. `return !(… || …)` erfüllt die Anwesenheitsprüfungen oben,
# kehrt aber genau die belegte Entscheidung um (MARAAA-152).
positive_filter='returnexpiredReasons.contains(failure.reason??"")||expiredErrors.contains(failure.error??"")'
if [[ "$(compact "$auth_filter_code")" == *"$positive_filter"* ]]; then
    pass "401-Filter entscheidet positiv über beide Mengen"
else
    fail_check "401-Filter entscheidet positiv über beide Mengen"
fi
if grep -qE 'return[[:space:]]+!' <<<"$auth_filter_code"; then
    fail_check "401-Filter ist nicht invertiert"
else
    pass "401-Filter ist nicht invertiert"
fi

require_fixed "Re-Login ist durch ein Guard-Flag begrenzt" \
    'didRelogin' "$client"

retry_true="$(grep -c 'didRelogin: true' "$client" || true)"
if [[ "$retry_true" -eq 2 ]]; then
    pass "genau eine Wiederholung je Weg (send, stream)"
else
    fail_check "genau eine Wiederholung je Weg (send, stream) (gefunden: $retry_true)"
fi

guards="$(grep -c '!didRelogin' "$client" || true)"
if [[ "$guards" -eq 2 ]]; then
    pass "Re-Login wird auf beiden Wegen nur einmal ausgelöst"
else
    fail_check "Re-Login wird auf beiden Wegen nur einmal ausgelöst (gefunden: $guards)"
fi

if [[ -n "$perform_code" ]] \
    && grep -qF 'http.statusCode == 401' <<<"$perform_code" \
    && grep -qF 'service == .hermes' <<<"$perform_code"; then
    pass "performRaw behandelt den Hermes-401"
else
    fail_check "performRaw behandelt den Hermes-401"
fi
if grep -qF 'HermesAuthFailure.indicatesExpiredSession(result.data)' <<<"$perform_code"; then
    pass "performRaw prüft den 401-Grund vor dem Re-Login"
else
    fail_check "performRaw prüft den 401-Grund vor dem Re-Login"
fi
# Ohne diese Forderung blieb das Skript grün, wenn `performRaw` den 401 zwar
# erkennt, aber gar keinen Re-Login ausführt (MARAAA-151, Befund 1).
if grep -qF 'loginHermes(configuration: configuration)' <<<"$perform_code"; then
    pass "performRaw loggt sich nach dem 401 neu ein"
else
    fail_check "performRaw loggt sich nach dem 401 neu ein"
fi

if [[ -n "$stream_code" ]] \
    && grep -qF 'HermesAuthFailure.indicatesExpiredSession(body)' <<<"$stream_code" \
    && grep -qF 'loginHermes(configuration: configuration)' <<<"$stream_code"; then
    pass "Stream behandelt den Hermes-401 mit demselben Grund"
else
    fail_check "Stream behandelt den Hermes-401 mit demselben Grund"
fi

# --- (6) Kein Login-Sturm -------------------------------------------------

require_fixed "Login-Koaleszierung ist ein actor" \
    'actor HermesLoginCoordinator' "$session"
require_fixed "actor hält die laufende Login-Task" \
    'private var running: Task<Void, Error>?' "$session"
require_fixed "zweiter Aufrufer wartet auf die laufende Task" \
    'if let running {' "$session"
require_fixed "NetworkClient nutzt den Koordinator" \
    'HermesLoginCoordinator.shared.login' "$client"

# --- (7) Alle drei Wege ---------------------------------------------------

require_fixed "send nutzt den gemeinsamen Perform-Pfad" \
    'return try await perform(' "$client"
require_fixed "sendRaw nutzt den gemeinsamen Perform-Pfad" \
    'return try await performRaw(' "$client"
require_fixed "stream nutzt den gemeinsamen Stream-Pfad" \
    'return try await performStream(' "$client"

perform_calls="$(grep -cE 'performRaw\(' "$client" || true)"
if [[ "$perform_calls" -ge 4 ]]; then
    pass "send und sendRaw laufen durch performRaw"
else
    fail_check "send und sendRaw laufen durch performRaw (Aufrufe: $perform_calls)"
fi

# --- (8) Einstellungen ----------------------------------------------------

require_fixed "Hermes zeigt ein Benutzername-Feld" \
    'TextField("Benutzername", text: $hermesUsername)' "$settings"
require_fixed "Hermes zeigt ein Passwort-SecureField" \
    'SecureField("Passwort", text: $hermesPassword)' "$settings"
require_fixed "Benutzername wird in die Keychain geschrieben" \
    'persist(hermesUsername, account: .username)' "$settings"
require_fixed "Passwort wird in die Keychain geschrieben" \
    'persistSecret(hermesPassword, account: .password)' "$settings"
require_fixed "leeres Passwort löscht den Keychain-Eintrag" \
    'try keychain.remove(for: service, account: account)' "$settings"
require_fixed "Mealie behält den API-Token" \
    'case .mealie:' "$service_type"
require_fixed "Mealie liefert weiterhin apiToken" \
    'return .apiToken' "$service_type"
if grep -qF 'case .hermes, .mealie:' "$service_type"; then
    fail_check "Hermes hat keinen kombinierten apiCredential-Zweig"
else
    pass "Hermes hat keinen kombinierten apiCredential-Zweig"
fi

# --- (9) Fehlertexte ------------------------------------------------------

require_fixed "fehlgeschlagener Login nennt Benutzername/Passwort" \
    'Benutzername und Passwort prüfen' "$api_error"
# Der Verbindungstest fragt für Hermes `/v1/models` auf dem API-Server ab; ein
# 401 dort kann nur den API-Schlüssel meinen (Dashboard-Zugang hilft nicht).
require_fixed "401 des Verbindungstests nennt für Hermes den API-Schlüssel" \
    'return "API-Schlüssel"' "$settings"
require_fixed "CF-Hinweis bleibt erhalten" \
    'Cloudflare Access: Service-Token fehlt oder ungültig.' "$settings"
require_fixed "Login-Fehler ist ein eigener Fall" \
    'case hermesLoginFailed' "$api_error"
token_section="$(section_between 'private static func tokenName' 'private static func isJSON' "$settings")"
hermes_token="$(awk '/case \.hermes:/{flag=1} flag{print} flag && /case \.mealie:/{exit}' <<<"$token_section")"
if [[ -n "$hermes_token" ]] \
    && grep -qF 'return "API-Schlüssel"' <<<"$hermes_token" \
    && ! grep -qF 'return "API-Token"' <<<"$hermes_token"; then
    pass "Hermes-401 nennt den API-Schlüssel statt eines Tokens"
else
    fail_check "Hermes-401 nennt den API-Schlüssel statt eines Tokens"
fi

# --- (10) Redirects und 3xx als Auth-Signal -------------------------------

require_fixed "Redirect-Status sind 301/302/303/307/308" \
    'private static let redirectStatusCodes: Set<Int> = [301, 302, 303, 307, 308]' "$client"
require_fixed "RedirectBlocker verwirft die Weiterleitung" \
    'completionHandler(nil)' "$client"
if grep -qF 'private static let redirectBlockingSession' "$client" \
    && grep -qF 'delegate: RedirectBlocker()' "$client"; then
    pass "redirect-blockierende Session nutzt den RedirectBlocker"
else
    fail_check "redirect-blockierende Session nutzt den RedirectBlocker"
fi

# Hermes muss als einziger Dienst die blockierende Session wählen. Die exakte
# kompakte Form verhindert, dass ein unbedingtes `return session` die Prüfung
# erfüllt (Mutation: Redirect-Verfolgen wieder aktivieren).
session_section="$(section_between 'private func urlSession' 'private func loadConfiguration' "$client")"
session_code="$(strip_comments "$session_section")"
expected_session='ifservice==.hermes{returnNetworkClient.redirectBlockingSession}returnsession'
if [[ "$(compact "$session_code")" == *"$expected_session"* ]]; then
    pass "Hermes nutzt die redirect-blockierende Session, andere Dienste nicht"
else
    fail_check "Hermes nutzt die redirect-blockierende Session, andere Dienste nicht"
fi

session_calls="$(grep -c 'urlSession(for:' "$client" || true)"
if [[ "$session_calls" -ge 3 ]]; then
    pass "performRaw, performStream und Login wählen die Session je Dienst"
else
    fail_check "performRaw, performStream und Login wählen die Session je Dienst (Aufrufe: $session_calls)"
fi

# Der 3xx-Zweig muss Teil derselben didRelogin-Bedingung sein wie der 401.
# Ohne diesen Block blieb das Skript grün, wenn Redirects zwar blockiert, aber
# nicht als Auth-Signal behandelt werden (Mutation: 3xx-Zweig entfernen).
if [[ "$(compact "$perform_code")" == *'letredirect=service==.hermes&&Self.isRedirect(http.statusCode)'* ]] \
    && [[ "$(compact "$perform_code")" == *'if!didRelogin,!configuration.hermesUsesAPIToken,expired||redirect'* ]]; then
    pass "performRaw behandelt den Hermes-3xx vor dem didRelogin-Guard"
else
    fail_check "performRaw behandelt den Hermes-3xx vor dem didRelogin-Guard"
fi
if [[ "$(compact "$stream_code")" == *'letredirect=service==.hermes&&Self.isRedirect(http.statusCode)'* ]] \
    && [[ "$(compact "$stream_code")" == *'if!didRelogin,!configuration.hermesUsesAPIToken,expired||redirect'* ]]; then
    pass "Stream behandelt den Hermes-3xx vor dem didRelogin-Guard"
else
    fail_check "Stream behandelt den Hermes-3xx vor dem didRelogin-Guard"
fi

if [[ "$(compact "$perform_code")" == *'ifredirect{throwSelf.hermesRedirectError(http)}'* ]]; then
    pass "zweiter 3xx in performRaw wird als Fehler gemeldet"
else
    fail_check "zweiter 3xx in performRaw wird als Fehler gemeldet"
fi
if [[ "$(compact "$stream_code")" == *'ifredirect{throwSelf.hermesRedirectError(http)}'* ]]; then
    pass "zweiter 3xx im Stream wird als Fehler gemeldet"
else
    fail_check "zweiter 3xx im Stream wird als Fehler gemeldet"
fi

login_code="$(strip_comments "$(section_between 'private func loginHermes' 'private static func makeLoginBody' "$client")")"
if grep -qF 'urlSession(for: .hermes)' <<<"$login_code"; then
    pass "auch der Login verfolgt keine Redirects"
else
    fail_check "auch der Login verfolgt keine Redirects"
fi
perform_login_code="$(strip_comments "$(section_between 'private static func performLogin' 'guard let url = http.url' "$client")")"
if grep -qF 'Self.isRedirect(http.statusCode)' <<<"$perform_login_code" \
    && grep -qF 'Self.hermesRedirectError(http)' <<<"$perform_login_code"; then
    pass "ein 3xx des Logins wird als Auth-Fehler gemeldet"
else
    fail_check "ein 3xx des Logins wird als Auth-Fehler gemeldet"
fi

# POST bleibt POST: die Wiederholung ist eine Kopie des Requests, nur der
# Cookie-Header wird ersetzt. Kein GET-Fallback, kein verworfener Body.
if grep -qF 'var retried = request' <<<"$perform_code" \
    && ! grep -qE 'retried\.httpMethod|httpMethod[[:space:]]*=[[:space:]]*"GET"' <<<"$perform_code"; then
    pass "performRaw wiederholt den POST unverändert"
else
    fail_check "performRaw wiederholt den POST unverändert"
fi
if grep -qF 'var retried = urlRequest' <<<"$stream_code" \
    && ! grep -qE 'retried\.httpMethod|httpMethod[[:space:]]*=[[:space:]]*"GET"' <<<"$stream_code"; then
    pass "Stream wiederholt den POST unverändert"
else
    fail_check "Stream wiederholt den POST unverändert"
fi
forbid "kein GET-Fallback im Client" \
    'httpMethod[[:space:]]*=[[:space:]]*"GET"' "$client"
forbid "kein Body-Verlust bei der Wiederholung" \
    'httpBody[[:space:]]*=[[:space:]]*nil' "$client"
forbid "kein Verwurf des Content-Type bei der Wiederholung" \
    'setValue\(nil, forHTTPHeaderField: "Content-Type"\)' "$client"

require_fixed "3xx liest den Location-Header" \
    'value(forHTTPHeaderField: "Location")' "$client"
require_fixed "3xx erkennt Cloudflare Access an der Location" \
    'contains("cloudflareaccess.com")' "$client"
redirect_error_section="$(section_between 'private static func hermesRedirectError' '// MARK: - Hermes-Anmeldung' "$client")"
redirect_error_code="$(strip_comments "$redirect_error_section")"
expected_error='return.hermesAuthenticationRequired(cloudflareAccess:location.contains("cloudflareaccess.com"))'
if [[ "$(compact "$redirect_error_code")" == *"$expected_error"* ]]; then
    pass "die Cloudflare-Ursache wird in den Fehler übernommen"
else
    fail_check "die Cloudflare-Ursache wird in den Fehler übernommen"
fi
require_fixed "Cloudflare-3xx nennt das Service-Token" \
    'Cloudflare Access: Service-Token fehlt oder ungültig.' "$api_error"
require_fixed "Hermes-3xx nennt die Anmeldung" \
    'Hermes-Anmeldung erforderlich — Benutzername/Passwort prüfen.' "$api_error"
require_fixed "Chat behandelt den Redirect-Fehler als Auth-Fall" \
    'case .hermesAuthenticationRequired' "$chat_view_model"

if [[ "$fail" -ne 0 ]]; then
    echo "Ergebnis: FEHLGESCHLAGEN"
    exit 1
fi

echo "Ergebnis: OK"
