# Hermes: HTTP 405 (Method Not Allowed) — Diagnose

Stand: MARAAA-158. Belegt am laufenden Hermes 0.21.5 (Dashboard 9119, API-Server 8642)
und am Code dieses Repos.

## Kurzfassung

Die App spricht **zwei verschiedene Hermes-Oberflächen** an, die auf dem Server zwei
getrennte Prozesse mit getrennten Zugängen sind:

| Oberfläche | Prozess | Authentifizierung | Endpunkte der App |
|---|---|---|---|
| **Dashboard** | `hermes dashboard` (Port 9119, öffentlich als `https://hermes.example.com`) | `POST /auth/password-login` + Session-Cookies | `GET /api/sessions`, `GET /api/sessions/{id}`, `GET .../messages` |
| **API-Server** | `api_server`-Plattform des Gateways (Port 8642) | `Authorization: Bearer <API_SERVER_KEY>` | `POST /api/sessions`, `POST /v1/chat/completions`, `POST /v1/runs/{id}/approval`, `GET /v1/models` |

Der 405 entsteht, weil die Basis-URL auf das **Dashboard** zeigt, die Chat-Aufrufe aber
nur auf dem **API-Server** existieren:

- `POST /api/sessions` (Sitzung anlegen) trifft im Dashboard auf eine Route, die nur
  `GET` kennt → **405 Method Not Allowed**.
- `POST /v1/chat/completions` und `POST /v1/runs/{id}/approval` existieren im Dashboard
  überhaupt nicht (dort nur SPA/GET) → je nach Sitzung 405 oder 302 auf `/login`.

Der Password-Login selbst ist **nicht** die Ursache: er funktioniert gegen das Dashboard
und liefert Cookies. Deshalb wirkt die Verbindung „fast in Ordnung“ — bis der Chat eine
Sitzung anlegen oder streamen will.

## Belege

### 1. Die öffentliche URL ist das Dashboard

```
GET https://hermes.example.com/api/sessions     -> 401 application/json
   {"error":"unauthenticated","detail":"Unauthorized","reason":"no_cookie","login_url":"/login"}

GET https://hermes.example.com/v1/models        -> 302 (Weiterleitung, kein API-Server)
```

Die 401-Form mit `reason`/`login_url` ist der Auth-Gate-Middleware des Dashboards
zuzuordnen; der API-Server antwortet auf fehlende Authentifizierung mit
`{"error":{"code":"gateway_auth_failed", ...}}`.

### 2. Login-Pfad und -Methode sind korrekt

```
POST https://hermes.example.com/auth/password-login
Content-Type: application/json
{"provider":"basic","username":"…","password":"…"}

-> 401 {"detail":"Invalid credentials"}     (falsches Passwort)
-> 200 + Set-Cookie + {"ok":true,"next":"/"} (richtiges Passwort)
```

Die Route existiert also als `POST`; ein 405 an dieser Stelle wäre ein anderer Fehler.

### 3. Der 405-Mechanismus ist die Methode, nicht die URL

Eine öffentliche, ausschließlich per `GET` registrierte Dashboard-Route
(`/api/auth/providers`) mit `POST` aufgerufen:

```
POST https://hermes.example.com/api/auth/providers  -> 405 {"detail":"Method Not Allowed"}
```

Genau diese Antwort erzeugt die App als `Serverfehler (HTTP_405): Method Not Allowed`.

### 4. Routentabelle des Dashboards (Auszug)

```
['GET']                       /api/sessions
['POST']                      /api/sessions/bulk-delete
['DELETE']                    /api/sessions/empty
['GET']                       /api/sessions/empty/count
['POST']                      /api/sessions/import
['POST']                      /api/sessions/prune
['GET']                       /api/sessions/search
['GET']                       /api/sessions/stats
['GET','PATCH','DELETE']      /api/sessions/{session_id}
['GET']                       /api/sessions/{session_id}/messages
['POST']                      /auth/password-login
```

Kein `POST /api/sessions`, keine `/v1/*`-Route.

### 5. Der API-Server hat die Chat-Flächen, aber keinen Password-Login

```
POST http://127.0.0.1:8642/auth/password-login   -> 404 404: Not Found
POST http://127.0.0.1:8642/api/sessions          -> 401 {"error":{"code":"gateway_auth_failed", ...}}
POST http://127.0.0.1:8642/v1/chat/completions   -> 401 {"error":{"code":"gateway_auth_failed", ...}}
```

Der API-Server prüft ausschließlich `Authorization: Bearer <API_SERVER_KEY>`
(`_check_auth` in `gateway/platforms/api_server.py`); Dashboard-Cookies werden nicht
ausgewertet. Seine Fähigkeitstabelle (`_CAPABILITY_ENDPOINTS`) enthält genau die
Endpunkte, die die App im Chat nutzt, inklusive `session_create` (`POST /api/sessions`).

## Was die curl-Ausgaben bedeuten

Die folgenden Aufrufe werden auf dem Hermes-Server ausgeführt; sie trennen die
beiden Oberflächen und die Bindungsadresse des API-Servers.

| Aufruf | Antwort | Bedeutung |
|---|---|---|
| `curl http://127.0.0.1:9119/api/status` | `200` | Dashboard-Status; enthält `gateway_platforms.api_server.listener_base` und `state` des API-Servers. |
| `curl http://127.0.0.1:8642/` | `404: Not Found` | Der API-Server läuft, hat aber keine Route `/`. |
| `curl http://127.0.0.1:8642/api/status` | `404` | `/api/status` ist eine Dashboard-Route, keine API-Server-Route. |
| `curl http://<lan-ip>:8642` | `Failed to connect` | Der API-Server bindet nur `127.0.0.1` (Hermes-Default `API_SERVER_HOST`). |
| `curl -H "Authorization: Bearer $API_SERVER_KEY" http://127.0.0.1:8642/v1/models` | `200` | Der API-Server ist gesund; nur der Weg von außen fehlt. |

Die ersten beiden Zeilen sind kein Fehler, sondern der Normalfall: Dashboard
und API-Server sind getrennte Prozesse mit getrennten Routen. Ein
`Failed to connect` auf die LAN-Adresse bedeutet dagegen nicht, dass der
API-Server aus ist — er lauscht nur auf Loopback. Genau das wertet der
Verbindungstest der App aus: Nach einem nicht erfolgreichen `GET /v1/models`
fragt er für Hermes zusätzlich `GET /api/status` ab und nennt die dort
gemeldete `listener_base`.

### Zwei zulässige Betriebsarten

**(1) Eine URL über hermes-front (empfohlen).** Der Caddy-Proxy lauscht auf
`127.0.0.1:9180` und verteilt Dashboard- und API-Verkehr; der Cloudflare-Tunnel
zeigt auf ihn. In der App steht dann genau eine Adresse:

```
Cloudflare Zero Trust → Tunnel → Public Hostname
  Dienst:  http://localhost:9180      (vorher http://localhost:9119)
App-Basis-URL:  https://<domain>      (ohne Pfad)
App:            API-Schlüssel = API_SERVER_KEY
```

**(2) Direkt auf den API-Server.** Dafür muss der Listener an alle Interfaces
gebunden werden:

```
# ~/.hermes/.env bzw. Dienstumgebung
API_SERVER_HOST=0.0.0.0
API_SERVER_KEY=<schlüssel>

grep '^API_SERVER_KEY=' ~/.hermes/.env | cut -d= -f2-   # Schlüssel anzeigen
```

`hermes config get API_SERVER_KEY --raw` ist hier **kein** tauglicher Weg: Steht
der Schlüssel nur in `~/.hermes/.env`, antwortet der Befehl mit
`Config key not set: API_SERVER_KEY` (rc=1). Deshalb den Wert direkt aus der
`.env` lesen (oben) und nicht in Dateien oder Logs schreiben.

Die App akzeptiert **nur HTTPS** (Ausnahme: `http` auf `localhost`/
`127.0.0.1`, MARAAA-98). Ein Direktzugriff auf `http://<host>:8642` ist darum
keine gültige Basis-URL; für Betriebsart (2) braucht der Port eine
TLS-Terminierung (Reverse Proxy oder Tunnel), und die App bekommt deren
`https://…`-Adresse. `0.0.0.0` ist keine verbindbare Adresse und darf nie als
Basis-URL eingetragen werden — es beschreibt nur, dass der Listener auf allen
Interfaces lauscht.

## Was daraus folgt

Eine einzige Basis-URL kann mit dem heutigen Hermes nur eine der beiden Oberflächen
sein. Für den Chat braucht die App den **API-Server** und dessen **API-Schlüssel**;
der Password-Login gehört zum Dashboard und ersetzt ihn nicht.

Eine **pauschale** Weiterleitung von `/api/*` an den API-Server ist keine Lösung: das
Dashboard benutzt `GET /api/sessions` selbst für seine Sitzungsliste. Trennen lässt sich
der Verkehr nur an einem Merkmal, das die App und nicht der Browser sendet — die App
trägt dafür `X-Hermes-Client: planer`.

## Änderung in der App

1. **API-Schlüssel-Modus (additiv).** Ist für Hermes ein API-Schlüssel in der Keychain
   hinterlegt (`.apiToken`), sendet `NetworkClient` `Authorization: Bearer …` und
   unterlässt Cookie-Header, Password-Login und Re-Login. Ohne Schlüssel bleibt alles
   wie bisher (Password-Login + Cookies).
2. **Ehrlicher Verbindungstest.** Hermes wird gegen `GET /v1/models` geprüft — den
   Marker des API-Servers. 405 und 302 werden als „das ist das Dashboard“ gemeldet,
   401 als fehlender/ungültiger Schlüssel.
3. **Eigener Fehlerfall für 405.** `APIError.methodNotAllowed` nennt die Ursache
   (Dashboard statt API-Server, Port 8642) statt eines generischen Serverfehlers.

## Betrieb unter einer öffentlichen URL (umgesetzt)

Damit alles unter **einer** Adresse (`https://hermes.example.com`) erreichbar ist, läuft
vor beiden Hermes-Prozessen ein Reverse Proxy als User-Service:

| | |
|---|---|
| Dienst | `hermes-front.service` (`systemctl --user`) |
| Proxy | Caddy, `127.0.0.1:9180`, Konfiguration `~/.config/hermes-front/Caddyfile` |
| Upstreams | Dashboard `127.0.0.1:9119`, API-Server `127.0.0.1:8642` |

Wegewahl (Caddy, in dieser Reihenfolge):

| Anfrage | Ziel |
|---|---|
| `/api/*`, `/v1/*`, `/health` **mit** `X-Hermes-Client` | API-Server (Header wird durchgereicht) |
| `/v1/*`, `/health` (ohne Marker) | API-Server |
| alles andere (`/`, `/login`, `/auth/*`, `/api/*` ohne Marker) | Dashboard |

Der Proxy **injiziert keinen Schlüssel**. `X-Hermes-Client` ist nur ein Routing-Hinweis,
keine Autorisierung: ohne gültigen `Authorization: Bearer <API_SERVER_KEY>` antwortet der
API-Server auch über den Proxy mit `401 gateway_auth_failed`. `flush_interval -1` hält
SSE-Streams und den Dashboard-WebSocket (`/api/pty`) durchgängig.

Verifiziert (lokal gegen `127.0.0.1:9180`, Host-Header der öffentlichen Domain):

```
GET /                                    -> 302 /login          (Dashboard)
GET /api/auth/providers                  -> 200                 (Dashboard)
POST /auth/password-login (falsch)       -> 401 Invalid credentials (Dashboard)
GET /api/sessions            (ohne Marker) -> 401 reason=no_cookie    (Dashboard)
GET /api/sessions   (Marker, ohne Bearer)  -> 401 gateway_auth_failed (API-Server)
GET /api/sessions   (Marker + Bearer)      -> 200 {"object":"list"}   (API-Server)
GET /v1/models              (ohne Bearer)  -> 401 gateway_auth_failed
GET /v1/models              (mit Bearer)   -> 200 {"data":[{"id":"hermes-agent"}]}
WS  /api/pty                             -> 403 (Dashboard-Auth), kein 502/504
```

### Tunnel prüfen: was antwortet die öffentliche URL?

Vor dem Origin stehen **zwei** Stellen, die beide mit `302` antworten können:
**Cloudflare Access** am Edge und das **Dashboard** (Port 9119). Ein Statuscode
allein ist darum mehrdeutig — er sagt nicht, ob der Tunnel umgestellt ist. Zuerst
die `Location` der Antwort ansehen:

```
curl -sSI https://<domain>/v1/models | grep -i '^location:'
```

| `Location` der 302-Antwort | Quelle | Bedeutung |
|---|---|---|
| enthält `cloudflareaccess.com` | **Cloudflare Access** (Edge) | Die Anfrage erreicht den **Origin nie**. Über Tunnel, Proxy und API-Server ist damit **nichts** gesagt — der Origin-Zustand bleibt unbekannt. Prüfbar nur mit Service-Token (b) oder direkt am Origin (a). |
| endet auf `/<domain>/login` | **Dashboard** (Port 9119) | Der Tunnel zeigt noch auf das Dashboard. Im Tunnel den Dienst auf `http://localhost:9180` ändern. |

Am laufenden Host gemessen: `302` mit
`location: https://<team>.cloudflareaccess.com/cdn-cgi/access/login/<domain>?…&redirect_url=%2Fv1%2Fmodels`,
`www-authenticate: Cloudflare-Access`, im Meta-JWT `"service_token_status":false`.
Dieser 302 **bleibt nach dem Tunnel-Wechsel bestehen** — Access sitzt davor. Er ist
kein Beleg dafür, dass die Umstellung gescheitert ist.

Der Statuscode allein, ohne jeden Token (Body wird verworfen):

```
curl -s -o /dev/null -w '%{http_code}\n' https://<domain>/v1/models
```

| Antwort (ohne Bearer, ohne Service-Token) | Bedeutung |
|---|---|
| **401** | **Erfolgsfall.** Die Anfrage hat Access und den Proxy passiert; der API-Server weist den fehlenden Bearer-Token mit `gateway_auth_failed` ab. |
| **302** | **Mehrdeutig.** Entweder Cloudflare Access (Edge, `Location` → `cloudflareaccess.com`) **oder** das Dashboard (Port 9119, `Location` → `/<domain>/login`). Ohne die `Location` ist keine Aussage möglich — Tabelle oben. |
| **200** | Ohne Bearer **nicht zu erwarten**: der API-Server gibt `/v1/models` niemals ohne gültigen Schlüssel frei. Ein 200 an dieser Stelle ist darum kein Beweis für den Proxy, sondern ein Hinweis auf ein anderes Ziel — Ursache prüfen, nicht als Erfolg werten. |
| **502 / 504** | Der Proxy antwortet, aber sein Upstream fehlt (`hermes-front.service` bzw. Caddyfile prüfen). |

Zwei Prüfungen, die unabhängig von Access eine belastbare Aussage geben:

**a) Am Origin, ohne Access** (funktioniert immer, umgeht Edge und Tunnel):

```
curl -s -o /dev/null -w '%{http_code}\n' \
  -H 'Host: <domain>' http://127.0.0.1:9180/v1/models
```

| Antwort | Bedeutung |
|---|---|
| **401** | Der Proxy erreicht den API-Server (fehlender Bearer wird abgewiesen) — Tunnel-Ziel `9180` ist richtig. |
| **302** | Der Proxy liefert das Dashboard; Caddy-Wegewahl bzw. Upstream prüfen. |
| **502 / 504** | Caddy bzw. `hermes-front.service` oder dessen Upstream fehlt. |

**b) Öffentlich mit Service-Token** (prüft Access **und** Origin in einem Aufruf):

```
curl -s -o /dev/null -w '%{http_code}\n' \
  -H "CF-Access-Client-Id: $CF_ACCESS_CLIENT_ID" \
  -H "CF-Access-Client-Secret: $CF_ACCESS_CLIENT_SECRET" \
  https://<domain>/v1/models
```

**401** = Access, Proxy und API-Server sind in Ordnung. **Ohne** Token ist ein `302`
auf `cloudflareaccess.com` dagegen **erwartet** und **kein Tunnel-Fehler**.

Die App braucht dasselbe Service-Token in den Einstellungen
(`CF-Access-Client-ID` / `CF-Access-Client-Secret`); sie sendet es als
`CF-Access-Client-Id` / `CF-Access-Client-Secret` (`NetworkClient.swift:310-311`).
Fehlt es, meldet sie „Cloudflare Access: Service-Token fehlt oder ungültig.“
(`APIError.swift:194-195`) — das ist bereits implementiert, hier ist nichts zu ändern.

Erst danach lohnt der Gegentest **mit** Schlüssel (`grep '^API_SERVER_KEY=' ~/.hermes/.env | cut -d= -f2-`,
Wert nur in der Kommandozeile, nicht in Dateien): derselbe Aufruf muss dann `200` mit
`{"object":"list","data":[{"id":"hermes-agent",…}]}` liefern.

## Was der Betreiber noch konfigurieren muss

1. **Cloudflare-Tunnel** (Zero Trust → Tunnel → Public Hostname): Dienst von
   `http://localhost:9119` auf `http://localhost:9180` umstellen. Der alte Wert ist der
   Rückweg; der Proxy selbst lauscht nur auf Loopback, es wird nichts neu veröffentlicht.
2. **Service-Token für Cloudflare Access** (Zero Trust → Access → Applications → die
   Anwendung für `<domain>`): ein Service-Token anlegen, in der Policy eine Regel
   **„Service Auth“** für dieses Token erlauben (neben dem Browser-Login), und
   Client-ID/Secret notieren. Ohne diesen Schritt antwortet Access an der Edge weiter
   mit `302` auf `cloudflareaccess.com` — auch bei korrektem Tunnel, und die App kommt
   am Origin nie an.
3. **`API_SERVER_KEY`** auslesen
   (`grep '^API_SERVER_KEY=' ~/.hermes/.env | cut -d= -f2-`) und in der App
   hinterlegen — der Schlüssel gehört in die Keychain, nicht ins Repo und nicht
   in die Proxy-Konfiguration. `hermes config get API_SERVER_KEY --raw` meldet
   `Config key not set: API_SERVER_KEY`, wenn der Wert nur in der `.env` steht.
4. **In der App:** Hermes-Basis-URL = `https://hermes.example.com` (ohne Pfad), Feld
   „API-Schlüssel (API-Server)“ ausfüllen, dazu `CF-Access-Client-ID` und
   `CF-Access-Client-Secret` des Service-Tokens. „Test Verbindung“ muss
   „Verbindung erfolgreich (Hermes-API-Server).“ melden; ohne Token erscheint
   stattdessen „Cloudflare Access: Service-Token fehlt oder ungültig.“
5. Der Password-Login bleibt für die **Dashboard-Oberfläche** im Browser; der API-Server
   kennt ihn nicht. Ein 401 von ihm erscheint in der App als
   „API-Schlüssel fehlt oder ist ungültig (API_SERVER_KEY)“.

## Grenzen dieser Diagnose

- Die App lief nicht auf einem Gerät; belegt sind Serververhalten (curl), Routentabellen
  und der Code. Ein Swift-Lauf ist auf diesem Prüfstand nicht möglich.
- Die konkrete Basis-URL in der Keychain des Geräts war nicht einsehbar. Die Zuordnung
  „öffentliche URL = Dashboard“ ist über das Antwortverhalten belegt (Belege 1 und 3),
  nicht über den gespeicherten Wert.
