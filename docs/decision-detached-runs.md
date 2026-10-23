# Entscheidung: Kann ein Hermes-Lauf ohne verbundenen Client weiterlaufen?

**Stand:** 2026-10-23 · **Vorgang:** MARAAA-199
**Art:** Entscheidung, kein Code. Keine Änderung an `Planer/**`, `Tests/**` oder an Hermes.
**Gilt für:** `Planer/Features/Chat` auf `main` = `74e161a`, Hermes 0.21.5
(Checkout `206102314a`, laufendes Gateway auf diesem Host).
**Basis:** `docs/decision-stream-liveness.md` (MARAAA-193, Branch
`docs/decision-stream-liveness`, nicht in `main`). Dieses Dokument baut darauf auf
und ersetzt es nicht: dort ging es um die Frist eines Watchdogs, hier um die
Frage, ob ein Turn den Client überhaupt überleben kann.

## Kurzfassung

1. **Das Abbruchverhalten von `POST /v1/chat/completions` ist nicht
   konfigurierbar.** Es gibt keinen Schlüssel dafür — weder in
   `gateway.api_server.*` noch sonst im Checkout. Der Abbruch steht hart im
   SSE-Schreiber (`api_server_openai_routes.py:965–967` →
   `api_server.py:699–714`). Abnahmepunkt 2 entfällt damit.
2. **Der Server kann es trotzdem — ohne jede Änderung.** Hermes 0.21.5 hat mit
   `POST /v1/runs` eine Annahmefläche, die einen Lauf startet und sofort eine
   `run_id` zurückgibt; der Lauf hängt nicht am Request. Dazu gehören
   `GET /v1/runs/{id}` (Status), `GET /v1/runs/{id}/events` (SSE, ab Sequenz
   wiederaufsetzbar), `POST /v1/runs/{id}/approval` und
   `POST /v1/runs/{id}/stop`. Auf diesem Host ist die Fläche vorhanden,
   authentifiziert erreichbar **und gemessen**: ein Lauf ohne jeden Client wurde
   `completed`, sein Text stand danach als Assistentennachricht im Verlauf der
   Sitzung (§3.3).
3. **Empfehlung: Variante A.** Die App sendet jeden Turn über `POST /v1/runs`,
   koppelt sich mit `GET /v1/runs/{id}/events?last_seq=…` an und hält `run_id`
   plus letzte Sequenz persistent. Damit ist „App schließen, Turn arbeitet
   weiter, beim nächsten Öffnen Verlauf laden“ erfüllt — **ohne Patch an
   Hermes** und ohne zweiten Antwortpfad.
4. **Der Preis ist benannt:** die Run-Fläche liefert keine
   Reasoning-Deltas und keine `hermes.status`-Notizen, und Werkzeugkarten
   kommen ohne `toolCallId`/Emoji. Live fehlt damit die Denk-Spur; nach dem
   Merge steht sie aus dem Verlauf. Das wird für v1 **akzeptiert** (§5.3).
5. **Bedingung:** Die Empfehlung gilt, solange die Instanz `run_submission` und
   `run_events_sse` in `GET /v1/capabilities` mit `true` ausweist. Fehlt die
   Fläche (ältere Installation), bleibt nur Variante C, bis der Server
   aktualisiert ist.

| Abnahmepunkt (MARAAA-199) | Beantwortet in |
|---|---|
| 1. Zielbild, heutiges Verhalten, ist der Abbruch konfigurierbar (mit Quelle) | §1, §2 — **nein**, mit Quelle |
| 2. Falls konfigurierbar: Schalter, Default, Ort, Nebenwirkungen | entfällt — es gibt keinen Schalter (§2.1) |
| 3. Falls nicht: minimaler Servereingriff + Vertrag der App + verwaisster Lauf | §4 (a′) — Eingriff: **keiner**; §6 (Vertrag), §6.5 (verwaister Lauf) |
| 4. Variantenvergleich (a/b/c) mit Nutzerfolgen, Risiken, Aufwand | §4 |
| 5. Genau eine Empfehlung mit Default und Bedingung | §5 |

---

## 1. Zielbild

Der Nutzer schickt einen Turn ab, schließt die App (Hintergrund oder beendet),
und der Turn rechnet auf dem Server zu Ende. Beim nächsten Öffnen ist der Chat
da — die fertige Antwort steht im Verlauf, ohne dass der Nutzer etwas
wiederholen muss.

Das ist **eine** Anforderung, nicht zwei: „Turn überlebt den Client“ **und**
„Chat ist beim Öffnen ladbar“ müssen zusammen gelten. Ein Turn, der zwar
weiterläuft, dessen Ergebnis aber nirgends ankommt, ist kein Fortschritt.

## 2. Heutiges Verhalten

### 2.1 Der Abbruch ist nicht konfigurierbar

Der Schreibpfad des Streams fängt den Verbindungsabbruch und beendet den Lauf:

- `gateway/platforms/api_server_openai_routes.py:886–889` (Docstring von
  `_write_sse_chat_completion`): „On client disconnect the agent is interrupted
  (stops LLM calls), then its task wrapper cancelled.“
- `gateway/platforms/api_server_openai_routes.py:965–967`: bei
  `ConnectionResetError`, `ConnectionAbortedError`, `BrokenPipeError`, `OSError`
  ruft der Server `_abandon_agent_task(agent_ref, agent_task, "SSE client
  disconnected")` und schreibt die Logzeile.
- `gateway/platforms/api_server.py:699–714` (`_abandon_agent_task`): Zeile 708
  `request_hard_interrupt(agent, reason, …)`, Zeile 711 `agent_task.cancel()`,
  Zeilen 713–714 warten auf den abgebrochenen Task.

**Es gibt keinen Schalter dafür.** Geprüft am 2026-10-23 im Checkout
`206102314a`:

| Prüfung | Ergebnis |
|---|---|
| `grep -rn "abort_on_disconnect\|disconnect_interrupt\|interrupt_on_disconnect\|detach_on_disconnect\|continue_on_disconnect"` über `*.py`, `*.yaml`, `*.md` | **kein Treffer** |
| Konfigurierbare Werte unter `gateway.api_server` | nur Ganzzahlen über `_resolve_api_server_int` (`api_server.py:1388–1398`): `max_concurrent_runs` (Default **10**, `0` = aus), `history_tool_output_max_chars` (Default **0**) |
| `~/.hermes/config.yaml` | enthält keinen Abschnitt `api_server`; der Abbruch ist damit auch nicht stillschweigend umkonfiguriert |
| Upstream-Test `tests/gateway/test_api_server_sse_keepalive.py:1–8` | beschreibt den Abbruch als **gewolltes** Verhalten: ein untätiger Strom wird verworfen, der Disconnect unterbricht den Turn — deshalb das 10-s-Keepalive |

Der Abbruch ist also eine Designentscheidung des Servers, keine Einstellung.
Abnahmepunkt 2 ist damit beantwortet: **kein Schalter, kein Default, kein Ort,
keine Nebenwirkungen** — es gibt nichts umzustellen.

### 2.2 Was die App heute tut

- Der Turn hängt an einem Streaming-`POST /v1/chat/completions`
  (`ChatConfiguration.swift:27`, `ChatStreamProvider.swift:93–98`).
- Abgebrochen wird über `Task.cancel()` → Socket zu
  (`ChatViewModel.swift:560`, `ChatStreamProvider.swift:133–135`). Die App sendet
  keinen Abbruch-Endpunkt.
- Im Hintergrund bittet die App iOS um Zeit
  (`ChatViewModel.swift:663–677`, `beginBackgroundTask(withName: "chat-turn")`).
  Das ist eine **Frist von iOS**, keine Garantie: das System beendet die Aufgabe
  nach kurzer Zeit (Größenordnung 30 s) und suspendiert danach den Prozess.
- Nach der Rückkehr prüft ein Watchdog auf Lebenszeichen und bricht im Zweifel ab
  (Regel und Frist: `docs/decision-stream-liveness.md` §2.4).

### 2.3 Nutzerfolgen heute

Sobald die App in den Hintergrund geht und iOS den Prozess suspendiert, wird der
Socket irgendwann nicht mehr beschrieben. Der nächste Keepalive-Schreibversuch
schlägt fehl (spätestens nach 10 s Server-Takt), der Server ruft
`_abandon_agent_task` und **beendet den Turn**. Was der Nutzer sieht:

- Beim Zurückkehren ist der Live-Text weg.
- Im Verlauf steht nur, was der Server vor dem Abbruch schon gespeichert hatte.
- Der Turn ist **nicht** wiederholbar, ohne ihn neu zu bezahlen.
- Die Meldung „Der Turn kann auf dem Server weiterlaufen“
  (`ChatViewModel.swift:47`) ist im Normalfall falsch — der lokale Abbruch ist
  der serverseitige Abbruch (bereits in MARAAA-193 §2.3 festgehalten).

Das ist genau das gemeldete Verhalten. Die Ursache ist nicht die App, sondern
der gewählte Endpunkt.

## 3. Befund: die Fähigkeit existiert bereits

### 3.1 `POST /v1/runs` ist Annahme, nicht Antwortstrom

`gateway/platforms/api_server_runs.py:620–757` (`_handle_runs`):

- Der Handler prüft Auth, Body, Route, Konkurrenz und Idempotenz, legt einen
  `_RunStream` an, startet die Ausführung als **eigene asyncio-Task**
  (`api_server_runs.py:748–751`, `asyncio.create_task(_execute_run(...))`,
  registriert in `_background_tasks`) und antwortet **sofort** mit
  `202 {"run_id", "status": "started", "replayed": false}`
  (`_accepted_response`, `api_server_runs.py:461–468`).
- Der Request ist damit beendet, **während** der Turn noch läuft. Es gibt keine
  Verbindung mehr, die abbrechen könnte.
- Der Strom ist ein **separater** Aufruf: `GET /v1/runs/{id}/events`
  (`api_server_runs.py:1064–1156`). Ein Abonnent, der geht, wird nur abgemeldet
  (`finally: stream.detach(q)`, `api_server_runs.py:1150–1153`); der Lauf läuft
  weiter.

Die inside-out-Reihenfolge ist der ganze Unterschied zum Chat-Endpunkt:
`/v1/chat/completions` **ist** der Antwortstrom (deshalb tötet sein Ende den
Lauf), `/v1/runs` **hat** einen Antwortstrom (deshalb tötet dessen Ende nichts).

### 3.2 Was der Server zusichert — und wo die Grenzen liegen

| Eigenschaft | Wert | Quelle |
|---|---|---|
| Statuswerte | `queued`, `running`, `waiting_for_approval`, `stopping`, danach terminal `completed`, `failed`, `cancelled`, `interrupted` | `_set_run_status` (`api_server_runs.py:258–284`), `TERMINAL_STATUSES` (`api_server_run_idempotency.py:21`) |
| Terminaler Text | `output` = `final_response` des Turns; `usage`; `runtime` | `_execute_run` → `_finish` (`api_server_runs.py:937–1000`) |
| Ereignisse im Strom | `message.delta`, `message.interim`, `tool.started`, `tool.completed`, `reasoning.available`, `approval.request`, `approval.responded`, `run.steered`, `run.<status>` | `_execute_run` (`:921–948`), `_make_run_event_callback` (`:315–349`), `_mark_run_event` (`:1156–1166`) |
| Nachlauf-Puffer | **1000** Ereignisse je Lauf, `seq` ab 0 | `_RunStream.BACKLOG_LIMIT` (`api_server_runs.py:119–157`) |
| Wiederaufsetzen | `Last-Event-ID`-Header **oder** `?last_seq=<n>`; ältere Sequenzen werden nachgespielt, bei Lücke `replay.truncated` mit `oldest_retained_seq` | `api_server_runs.py:1084–1124` |
| Keepalive im Strom | alle **10 s** `: keepalive` | `api_server_runs.py:1134–1138`, `CHAT_COMPLETIONS_SSE_KEEPALIVE_SECONDS = 10.0` (`api_server.py:236`) |
| Ende des Stroms | `: stream closed` (Kommentarzeile), kein Fehler | `api_server_runs.py:1126–1130, 1144–1146` |
| Transport-Puffer-Lebensdauer | **300 s ab Annahme** (nicht ab letztem Ereignis); danach kein Nachspielen mehr | `_RUN_STREAM_TTL = 300` (`api_server.py:4385`), Sweep `api_server_runs.py:1284–1299` |
| Status-Lebensdauer | **3600 s nach terminal** im Speicher | `_RUN_STATUS_TTL = 3600` (`api_server.py:4386`) |
| Dauerhaftigkeit | nur mit `Idempotency-Key`: Status liegt in SQLite (`~/.hermes/runs_idempotency.db`), Aufbewahrung **24 h**; ohne Key lebt der Status nur im Prozess | `RunIdempotencyStore` (`api_server_run_idempotency.py:69–120`), Persistenzbedingung `_set_run_status` (`api_server_runs.py:272–284`) |
| Gateway-Neustart | ein nicht-terminaler Lauf mit toter Owner-PID wird beim nächsten Lesen auf `interrupted` gesetzt („The gateway restarted before this run settled.“) | `_durable_run_status` (`api_server_runs.py:395–419`) |
| Konkurrenz | **429** `rate_limit_exceeded` mit `Retry-After: 1`, Deckel `gateway.api_server.max_concurrent_runs` (Default 10) | `_concurrency_limited_response` (`api_server.py:4107–4122`) |
| Stop | `POST /v1/runs/{id}/stop` → `{"run_id", "status": "stopping"}`, terminal bereits erledigt → 200 mit Status, sonst **409** `run_not_active` | `_handle_stop_run` (`api_server_runs.py:1253–1276`) |

Was der Server **nicht** zusichert:

- **Kein Reconnect nach 300 s.** Wer länger als fünf Minuten weg ist, bekommt
  den Ereignispuffer nicht mehr; `GET …/events` antwortet dann `404
  run_not_found`, obwohl der Status noch existiert. Das ist kein Fehler, sondern
  die Grenze des Puffers — und für das Zielbild unkritisch, weil der fertige
  Text im Verlauf steht. **Gemessen** in §3.3: 8 Minuten nach der Annahme
  antwortete `events` mit `404`, `status` weiter mit `completed`.
- **Kein Überleben über einen Gateway-Neustart hinaus** im Sinne von
  „weiterlaufen“. Der Lauf wird als `interrupted` markiert; die Arbeit ist weg.
- **Keine Ordnungsgarantie über die Puffergrenze.** Mehr als 1000 Ereignisse
  (bei langen Werkzeugläufen realistisch) werden vorne abgeschnitten;
  `replay.truncated` sagt es.

### 3.3 Messung auf diesem Host (2026-10-23)

Auf einem laufenden Gateway geprüft, mit einer eigens dafür angelegten
Probe-Sitzung; keine Änderung an Konfiguration, Code oder bestehenden Sitzungen:

| Zeit (UTC) | Aufruf | Ergebnis |
|---|---|---|
| 09:22 | `GET /v1/capabilities` mit Bearer-Key | `run_submission: true`, `run_status: true`, `run_events_sse: true`, `run_stop: true`, `run_steer: true`, `run_approval_response: true`, `runs_idempotency: {supported: true, durable: true, retention_seconds: 86400}` |
| 09:22 | `GET /v1/runs/run_probe` ohne Key | `401 gateway_auth_failed` — die Route existiert und ist auth-geschützt |
| 09:22 | `GET /v1/runs/run_probe` mit Key | `404 run_not_found` — die Route antwortet fachlich |
| 09:23:09 | `POST /api/sessions` (Probe-Sitzung) | `api_1792747389_55ac4ab5` |
| 09:23:09 | `POST /v1/runs` mit `Idempotency-Key`, Body `{input: "Antworte nur mit: PROBE-OK", session_id: "api_…"}` | `202 {"run_id": "run_d638cfe3…", "status": "started", "replayed": false}` |
| 09:23:09 | `~/.hermes/logs/gateway.log` | `started trace 3ca1b2f96c1ba767499bdb650d508867 for task:api_1792747389_55ac4ab5:…` — der Agent hat tatsächlich begonnen |
| 09:23:12 … 09:23:27 | `GET /v1/runs/{id}` (alle 3 s) | `running` — **ohne dass je ein Client am Ereignisstrom hing** |
| 09:23 … 09:28 | `GET /v1/runs/{id}` weiter | weiterhin `running`, kein `cancelled` |
| 09:30:51 | `GET /v1/runs/{id}` | **`completed`**, `last_event: run.completed`, `output: "PROBE-OK"`, `usage: {input_tokens: 27623, output_tokens: 35, total_tokens: 27658}` |
| 09:31 | `GET /api/sessions/api_…/messages?limit=20&order=latest` | `user: "Antworte nur mit: PROBE-OK"`, `assistant: "PROBE-OK"` — der Turn steht **im Verlauf** |
| 09:31 | `GET /v1/runs/{id}/events?last_seq=0` | **`404 run_not_found`** — der Ereignispuffer war nach 300 s schon weggeräumt, obwohl der Status noch `completed` lieferte (genau die Grenze aus §3.2) |
| 09:31 | `DELETE /api/sessions/api_…` | `200 {"deleted": true}`, danach `GET` → `404 session_not_found` — Probe beseitigt |

**Was das belegt:** Ein Lauf, für den nie ein Client am Ereignisstrom hing,
existiert nach der Annahme weiter, endet regulär, liefert seinen Text als Status
**und** als Assistentennachricht im Verlauf. Ein Chat-Completions-Turn wäre unter
denselben Bedingungen spätestens beim nächsten Keepalive-Schreibversuch (≤ 10 s)
abgebrochen worden und hätte die Logzeile
`SSE client disconnected; interrupted agent task …` erzeugt. Damit ist auch der
zweite Teil des Zielbilds gemessen: „beim nächsten Öffnen den Chat laden“ ist der
vorhandene Weg über `GET /api/sessions/{id}/messages`, und er enthält die Antwort.

**Was das nicht belegt** (ausdrückliche Offenlegung):

1. Die drahtseitige Zustellung auf dem Gerät (iOS-Suspension, Caddy, Cloudflare)
   ist weiterhin ungemessen — dieselbe offene Messung wie in
   `docs/decision-stream-liveness.md` §6. Für diese Entscheidung ist sie nicht
   blockierend: sie betrifft die Latenz, nicht die Lebensdauer des Laufs.
2. **Nicht** gemessen ist das Wiederankoppeln an einen **laufenden** Lauf nach
   einem Stromabbruch (`last_seq`-Replay). Der Puffer war bei der Messung schon
   abgelaufen, das Replay also nicht mehr prüfbar. Code-Beleg:
   `_RunStream.attach(last_seq)` (`api_server_runs.py:147–157`) und die
   Replay-Schleife (`:1119–1127`); Verifikation im Umsetzungsschritt (§9, A5).
3. Die Laufzeit der Probe (09:23:09 bis ~09:30:45, also gut 7½ Minuten) ist
   **keine** Aussage über die Turn-Dauer: der Host bediente parallel einen langen
   Fremd-Turn (`response ready … time=1573.6s` im selben Log). Sie zeigt aber,
   dass ein Lauf auch bei belegter Auslastung nicht abgebrochen wird.

## 4. Optionen

### (a) Detach über die vorhandene Run-Fläche *(empfohlen)*

Die App sendet Turns über `POST /v1/runs` und koppelt sich an
`GET /v1/runs/{id}/events`. Kein Server-Eingriff.

- **Nutzer sieht:** Antwort streamt wie heute, solange die App offen ist. App zu
  → beim Zurückkehren steht die fertige Antwort im Verlauf, Werkzeugkarten und
  Denk-Spur kommen aus dem Verlauf. Bricht die Verbindung nur kurz ab, setzt der
  Strom ab `last_seq` ohne sichtbaren Sprung wieder auf.
- **Risiken:** Geisterlauf (durch `stop`, Status-TTL und `interrupted`-Markierung
  begrenzt), Doppel-Turn bei Netz-Wiederholung (durch stabilen
  `Idempotency-Key` ausgeschlossen), zwei Dialekte (durch **eine**
  `ChatStreamProvider`-Implementierung gekapselt), Live-Reasoning fehlt (§5.3).
- **Aufwand:** mittel. Ein neuer Provider gegen das bestehende Protokoll, ein
  persistenter Turn-Datensatz, ein Resume-Pfad im ViewModel, ein Prüfstand.
  Keine Änderung an `ChatView` (die Oberfläche kennt nur `ChatStreamEvent`).

### (a′) Detach durch Abschalten von `_abandon_agent_task` bei `chat/completions`

Der minimale „Server-Eingriff“, den Abnahmepunkt 3 verlangt, wäre winzig: im
`except`-Block des Schreibers `_abandon_agent_task` nicht rufen
(`api_server_openai_routes.py:965–967`). **Verworfen**, und zwar aus einem
Grund, der nicht Geschmack ist: danach läuft ein Turn weiter, den niemand mehr
beobachten kann. `chat/completions` hat

- keinen Status-Endpunkt, dessen Antwort ein Fortschritt wäre (der Status, den
  `_register_stream_approval` unter der Completion-ID anlegt, wird nur von
  `on_done` gesetzt — `api_server_openai_routes.py:569–600`),
- keinen Ereignispuffer (`_run_streams` wird dort nie angelegt),
- keinen Stop-Endpunkt (Stop adressiert `run_id`s aus `_active_run_tasks`),
- keine Persistenz des Status (kein `Idempotency-Key`-Pfad).

Das Ergebnis wäre ein Geisterlauf mit Kosten und ohne Steuerbarkeit — die
schlechtere Hälfte von (a) ohne dessen Nutzen. Ein solcher Patch würde außerdem
Hermes ändern, was dieser Vorgang ausdrücklich nicht tut.

### (b) Client hält die Verbindung (Background-Task, zeitlich begrenzt)

Die App tut das bereits (`ChatViewModel.swift:663–677`).

- **Nutzer sieht:** bei kurzem Wechsel (Sperrbildschirm, App-Umschalter) läuft
  der Strom weiter, oft ohne sichtbaren Unterschied.
- **Grenze:** iOS gibt dafür eine kurze Frist (Größenordnung 30 s) und beendet
  die Aufgabe danach; bei suspendiertem Prozess wird der Socket nicht mehr
  bedient. Wird die App vom Nutzer beendet, endet alles sofort. Für einen Turn,
  der Minuten dauert (im Gateway-Log dieses Hosts gemessene Turn-Dauern: 357 s
  bis 1573 s), ist das keine Lösung.
- **Risiken:** keine neuen — aber auch kein Fortschritt; die Frist kann nicht
  verlängert werden, ohne in Hintergrundmodi (Audio, Standort) zu fliehen, die
  hier nicht vertretbar sind.
- **Aufwand:** null (ist gebaut). **Empfehlung:** unverändert lassen, aber nicht
  als Lösung zählen.

### (c) Status quo: abbrechen und nachladen

- **Nutzer sieht:** ehrlichen Hinweis, Verlauf neu geladen, Composer frei.
- **Risiken:** der Server wirft bereits geleistete Arbeit weg (bezahlte Tokens,
  ausgeführte Werkzeuge); der Nutzer muss den Turn wiederholen; die Meldung
  „kann auf dem Server weiterlaufen“ bleibt falsch.
- **Aufwand:** null.

### Vergleich

| | (a) `/v1/runs` | (a′) Patch chat/completions | (b) Background-Task | (c) Status quo |
|---|---|---|---|---|
| Turn überlebt App-Ende | **ja** (bis Gateway-Neustart) | ja | nein (≤ ~30 s) | nein |
| Ergebnis beim nächsten Öffnen | Verlauf + Status | nichts abfragbar | nichts | Verlauf (Teilstand) |
| Live-Text nach Rückkehr | ja, wenn < 300 s weg; sonst aus Verlauf | nein (kein Leser) | ja, solange die Frist hält | nein |
| Steuerbar (Stop) | **ja** (`POST …/stop`) | nein | ja (Socket) | ja |
| Doppel-Turn bei Retry | nein (`Idempotency-Key`) | nein | nein | nein |
| Geisterlauf möglich | begrenzt (Status-TTL, `interrupted`) | **ja, unbegrenzt** | nein | nein |
| Hermes-Änderung nötig | **nein** | ja | nein | nein |
| Aufwand | mittel | klein, aber falsch | null | null |

## 5. Empfehlung

**Variante (a): Turns über `POST /v1/runs` senden, Ereignisse über
`GET /v1/runs/{id}/events` beziehen, `run_id` und letzte Sequenz persistent
halten. Kein Eingriff in Hermes.**

### 5.1 Defaults (verbindlich, keine Magic Numbers im Code)

| Wert | Default | Ableitung |
|---|---|---|
| `runAttachMaxGap` | **300 s** | `_RUN_STREAM_TTL` (`api_server.py:4385`): danach ist kein Nachspielen möglich, also gar nicht erst ankoppeln |
| `runStatusPollInterval` | **5 s** | nur im Vordergrund, nur solange kein Ereignisstrom hängt — Ersatzlebenszeichen, kleiner als der 10-s-Keepalive |
| `runStatusRetention` | **3600 s** | `_RUN_STATUS_TTL` (`api_server.py:4386`): danach ist ein 404 endgültig, kein Retry |
| `runKeepaliveGrace` | **25 s** | 2 × 10 s Keepalive + 4 s Reserve — derselbe Wert und dieselbe Ableitung wie in `docs/decision-stream-liveness.md` §4 |
| `runStopWaitLimit` | **3 s** | bestehender `streamStopWaitLimit`; danach Verlauf laden, nicht weiter warten |
| `Idempotency-Key` | die `UUID` des Turn-Eintrags | genau ein Schlüssel je Turn, stabil über Wiederholungen |
| `runInputField` | `input` (String) | `_handle_runs:651–657`; die Sitzung bindet `session_id`, **nicht** `X-Hermes-Session-Id` |

`runKeepaliveGrace` hat mit dieser Entscheidung eine **andere Bedeutung** als
heute: sie gilt dem Ereignisstrom, nicht dem Turn. Läuft die Frist ab, wird der
Strom als tot behandelt und auf `runStatusPollInterval` umgestellt — der Turn
wird **nicht** abgebrochen. Genau diese Trennung ist der Zweck der Umstellung:
ein toter Strom ist ab heute ein Anzeigeproblem, kein Arbeitsverlust.

### 5.2 Bedingung, unter der die Empfehlung gilt

1. `GET /v1/capabilities` weist `run_submission: true` **und**
   `run_events_sse: true` aus. Fehlt eines, ist der Run-Pfad nicht verfügbar;
   dann bleibt (c), bis der Server aktualisiert ist. Die App prüft das einmal je
   Sitzung und fällt **nicht** stillschweigend auf `chat/completions` zurück —
   ein stiller Rückfall wäre genau der Fehler, den dieses Dokument behebt.
2. Die Sitzung existiert vor dem Turn (`POST /api/sessions` bzw. geladene
   Sitzung). Die Run-Fläche legt keine Sitzung an; sie nimmt `session_id`.
3. Es läuft höchstens ein Turn je App (bestehende `isStreaming`-Regel). Der
   persistente Turn-Datensatz ist deshalb genau einer.

### 5.3 Bewusst akzeptierte Einbuße: Live-Reasoning

Die Run-Fläche liefert **keine** Reasoning-Deltas: `_execute_run` verdrahtet
`stream_delta_callback`, `interim_assistant_callback` und
`tool_progress_callback`, aber keinen Reasoning-Callback
(`api_server_runs.py:917–948`, Aufruf `:960–963`); Denken erscheint nur als
`reasoning.available` mit gekürztem `preview`
(`_FIXED_EVENT_FIELDS`, `api_server_runs.py:93–97`).

Entscheidung: **akzeptiert für v1.** Begründung:

- Der fertige Assistententext trägt die Denk-Spur; nach dem Merge zeigt die
  Klappe sie aus dem Verlauf (`ChatViewModel.map`, `:1367–1456`).
- Verloren geht nur der **mitlaufende** Denk-Text während des offenen Turns —
  eine Anzeigequalität, kein Ergebnis.
- Die Alternative wäre ein Patch im Hermes-Checkout. Der steht nicht in diesem
  Repository, wird von diesem Team nicht versioniert und würde bei jedem Update
  neu abgeglichen. Für eine Anzeigequalität ist das der falsche Preis.

Ebenso akzeptiert: `hermes.status`-Notizen (Provider-Wartezeit, Fallback) fehlen
auf der Run-Fläche ganz; Werkzeugkarten kommen live ohne `toolCallId`, Emoji und
Argumente (`tool.started` trägt nur `tool` und `preview`,
`api_server_runs.py:93–95`) und werden erst durch den Merge vollständig. Das ist
sichtbar, aber nicht täuschend: der Endstand ist korrekt.

**Nicht** akzeptiert: eine falsche Meldung. Der Text „Der Turn kann auf dem
Server weiterlaufen“ (`ChatViewModel.swift:47`) muss mit dieser Entscheidung
verschwinden — nach (a) läuft er tatsächlich weiter, und der Nutzer soll das
lesen, nicht raten.

## 6. Der Vertrag, den die App braucht

Alle Aufrufe tragen `Authorization: Bearer <API_SERVER_KEY>` — dieselbe
Injektion wie heute (`NetworkClient.swift:308–339`); der Freigabe-POST beweist,
dass die Run-Fläche damit erreichbar ist (`ChatConfiguration.swift:29`,
`HermesChatAPI.swift:102`).

### 6.1 Turn starten

```
POST /v1/runs
Idempotency-Key: <turn-uuid>
Content-Type: application/json

{"input": "<Nutzertext>", "session_id": "<sitzung>"}
```

| Antwort | Bedeutung | App-Verhalten |
|---|---|---|
| `202 {"run_id","status","replayed"}` | angenommen | `run_id` persistieren, Ereignisse ankoppeln |
| `400 invalid_request_error` | `Missing 'input' field`, leerer Text | wie heutiger Validierungsfehler |
| `401 gateway_auth_failed` | Key fehlt/falsch | bestehende Meldung (`APIError.hermesAPIServerKeyRequired`) |
| `409 idempotency_key_conflict` | gleicher Key, anderer Body | Programmierfehler; Turn nicht wiederholen, Verlauf laden |
| `429 rate_limit_exceeded` + `Retry-After` | Konkurrenzdeckel | Hinweis, ein Wiederholversuch nach `Retry-After` |

Ein **Replay** (Netz-Wiederholung mit gleichem Key) liefert `202` mit derselben
`run_id` und `Idempotency-Replayed: true` (`api_server_runs.py:461–468`) — daraus
entsteht kein zweiter Turn.

### 6.2 Ankoppeln

```
GET /v1/runs/{run_id}/events?last_seq=<n>
Accept: text/event-stream
```

- Frames tragen `id: <seq>`; `last_seq` (oder `Last-Event-ID`) setzt hinter der
  letzten gesehenen Sequenz auf.
- `: keepalive` alle 10 s, `: stream closed` am Ende — beides **kein** Fehler.
- `event: replay.truncated` mit `oldest_retained_seq`: Lücke. Nicht versuchen zu
  flicken — Verlauf laden.
- `404 run_not_found`: Puffer abgelaufen, Lauf unbekannt oder fremd. **Kein**
  Retry; Status prüfen, dann Verlauf laden.

### 6.3 Status

```
GET /v1/runs/{run_id}
→ 200 {"object":"hermes.run","run_id","status","created_at","updated_at",
        "session_id","model", "output"?, "error"?, "usage"?, "approval"?,
        "last_event"?, "shutdown_requested_at"?}
```

Verwendet für (i) die Entscheidung „ankoppeln oder direkt laden“, (ii) die
Anzeige einer offenen Freigabe nach der Rückkehr (`approval` im Status, gesetzt
in `api_server_runs.py:857`), (iii) die Erkennung von `interrupted` nach einem
Gateway-Neustart.

### 6.4 Abbrechen

```
POST /v1/runs/{run_id}/stop
→ 200 {"run_id","status":"stopping"} | 200 <terminaler Status>
→ 409 run_not_active  (Lauf nicht in diesem Prozess aktiv)
```

Ersetzt `Task.cancel()` als Abbruchweg. `409` heißt „schon vorbei“ → Verlauf
laden, keine Fehlermeldung.

### 6.5 Verwaister Lauf

Ein verwaister Lauf im Sinne von „läuft für immer“ ist nach diesem Vertrag nicht
möglich; es gibt vier Enden, und jedes ist erreichbar:

1. **Regulär:** der Turn endet → `completed` / `failed`.
2. **Vom Nutzer:** `POST …/stop` → `cancelled`.
3. **Durch Freigabe-Timeout:** eine offene Freigabe verfällt nach
   `approvals.timeout` (Default **300 s**, `tools/approval_context.py:247–258`)
   als „kein Ja“; der Turn läuft weiter und endet regulär.
4. **Durch Neustart:** das Gateway markiert den Lauf beim nächsten Lesen als
   `interrupted` (`_durable_run_status`, `api_server_runs.py:395–419`).

Die App hat genau eine Pflicht: den `run_id` **nicht verlieren**, solange der
Turn nicht terminal ist. Ein nicht mehr erreichbarer Status (404 nach 3600 s)
wird als „unbekannt“ behandelt und löst den Verlaufsabgleich aus — nie eine
Dauerschleife.

## 7. Datenmodell: was die App persistieren muss

Genau ein Datensatz, weil genau ein Turn gleichzeitig läuft. Ablage in den
bestehenden Nutzerwerten (`ChatPreferences`, `UserDefaults`), Feldnamen stabil:

| Feld | Typ | Herkunft |
|---|---|---|
| `turnID` | `UUID` | beim Senden erzeugt; zugleich `Idempotency-Key` und ID des optimistischen Eintrags |
| `runID` | `String` (`run_…`) | `202`-Antwort von `POST /v1/runs` |
| `sessionID` | `String` | die Sitzung, an die der Turn gebunden wurde |
| `lastSeq` | `Int` | `id:` des zuletzt gelesenen SSE-Frames; `-1` = noch keiner |
| `startedAt` | `Date` | lokale Uhr beim Senden; nur für `runAttachMaxGap` |
| `lastStatus` | `String` | letzter bekannter Status; nur für Anzeige und Abbruchlogik |

Der Datensatz wird **entfernt**, sobald ein terminaler Status bekannt ist oder
der Merge gelaufen ist. Er überlebt den Prozess — genau dafür existiert er.

## 8. Fehlerfälle

| Fall | Verhalten |
|---|---|
| `POST /v1/runs` antwortet nicht (Transport/Timeout) | **Kein** Retry mit neuem Key. Retry mit **demselben** `Idempotency-Key`; gibt es eine `run_id`, ist es derselbe Turn. Ohne Antwort: Verlauf laden, ehrlicher Hinweis |
| Ereignisstrom bricht ab, Lauf lebt | Neu ankoppeln mit `last_seq`; Lücke von höchstens einem Keepalive ist unsichtbar |
| Ereignisstrom bricht ab, `GET status` = terminal | Nicht wieder ankoppeln; direkt Verlauf laden |
| `404` auf `events`, Status vorhanden | Puffer abgelaufen (>300 s). Verlauf laden, Status weiter poll­en bis terminal oder 3600 s |
| `404` auf `status` **und** `events` | Lauf unbekannt (fremder Prozess, Store leer). Verlauf laden, Turn-Datensatz verwerfen |
| `run.interrupted` | Hinweis „Der Server wurde neu gestartet; der Turn wurde abgebrochen.“ + Verlauf laden |
| `run.failed` mit `error` | bestehende Fehleranzeige, `error` als Text (bereits redigiert, `_redact_api_error_text`) |
| `waiting_for_approval` beim Zurückkehren | Freigabekarte aus `status.approval` zeigen; POST auf den bestehenden Pfad; nach Fristablauf Karte als abgelaufen (`ApprovalPhase.derive`) |
| `stop` → `409 run_not_active` | Kein Fehler; Verlauf laden |
| Nutzer bricht ab, bevor die `202` da ist | `runID` fehlt → kein Stop möglich. Nach Eingang der `202` sofort `stop` senden (Turn-Datensatz existiert dann schon) |
| `429` beim Senden | Hinweis mit `Retry-After`, kein automatischer Doppelversuch |
| App startet neu, Turn-Datensatz vorhanden | `GET status` → terminal: Verlauf laden; nicht terminal und < 300 s: ankoppeln; nicht terminal und > 300 s: Status pollen + Verlauf laden |
| Zwei Geräte, dieselbe Sitzung | Die Run-Fläche bindet an `run_id`, nicht an die Sitzung; der zweite Turn läuft parallel. Das ist heute genauso und nicht Teil dieses Vorgangs |

## 9. Akzeptanzkriterien für die Umsetzung

Binär prüfbar; „A“ = automatisiert im Prüfstand, „M“ = manuell am Gerät.

| # | Kriterium |
|---|---|
| A1 | `ChatConfiguration` enthält die Pfade `/v1/runs` und `/v1/runs/%@/events` genau einmal, jeweils über `scoped(_:)`; kein Roh-Literal in `ChatViewModel` oder im Provider |
| A2 | Der Turn-Body enthält `input` und `session_id`; `X-Hermes-Session-Id` wird **nicht** gesendet (der Server liest es dort nicht: `_handle_runs:691`) |
| A3 | Jeder Turn sendet genau einen `Idempotency-Key`, der der `turnID` entspricht; ein Replay-Test (zweiter POST, gleicher Key) erzeugt **keine** zweite `run_id` |
| A4 | Nach einem Abbruch geht genau ein `POST /v1/runs/{id}/stop` raus; `409` wird als Erfolg behandelt (kein Fehlertext) |
| A5 | Ein simulierter Stromabbruch (Verbindung nach Frame `n` kappen) setzt mit `last_seq = n` wieder auf; die sichtbaren Einträge enthalten keinen doppelten Text |
| A6 | Ein Lauf, der während der Abwesenheit endet, erzeugt beim Zurückkehren **keinen** zweiten Turn und zeigt den Assistententext aus `GET /api/sessions/{id}/messages` |
| A7 | `404` auf `events` bei vorhandenem Status führt zu Verlaufsabgleich, nicht zu einer Wiederholschleife (maximal ein Versuch je Rückkehr) |
| A8 | `run.interrupted` erzeugt einen Hinweis und einen Verlaufsabgleich; kein „läuft noch“-Text |
| A9 | Der Turn-Datensatz ist nach terminalem Status entfernt; ein App-Neustart mit vorhandenem Datensatz nimmt den Resume-Pfad, ein Neustart ohne Datensatz zeigt keinen Geister-Turn |
| A10 | Die bestehenden Chat-Prüfstände (`Tests/verify_chat_*.sh`) bleiben grün; der neue Prüfstand ist eigenständig und nennt seine Fälle |
| M1 | App im Hintergrund schließen, Turn mit ≥ 60 s Werkzeuglauf, nach 2 Minuten zurückkehren: Antwort ist da, ohne Wiederholung; Serverlog enthält **keine** Zeile `SSE client disconnected` für diesen Turn |
| M2 | Dasselbe, aber App vom Nutzer beendet und neu gestartet: Verlauf ist geladen, Turn-Datensatz ist weg, kein doppelter Turn |
| M3 | Freigabe, die während der Abwesenheit eintrifft: nach Rückkehr innerhalb von 300 s ist die Karte da und beantwortbar; danach ist sie abgelaufen und der Turn endet regulär |

## 10. Risiken

| Risiko | Wirkung | Begrenzung |
|---|---|---|
| Live-Reasoning fehlt | Nutzer sieht während des Turns kein mitlaufendes Denken | bewusst akzeptiert (§5.3); nach dem Merge aus dem Verlauf sichtbar; kein Server-Patch |
| Zwei Transportdialekte | zwei Wahrheiten im Chat | **eine** `ChatStreamProvider`-Implementierung; `ChatView` und `ChatViewModel` unverändert im Ereignisvertrag |
| Geisterlauf frisst Tokens | Kosten ohne Leser. Die Probe in §3.3 kostete für die Antwort „PROBE-OK“ **27 623 Eingabetokens** — der Kontext, nicht die Antwort, ist der Preis | Status-TTL 3600 s, `stop`, `max_concurrent_runs` (10); der Nutzer sieht den Turn in der Sitzungsliste |
| Doppel-Turn | zwei Antworten, doppelte Kosten | `Idempotency-Key` = `turnID`, stabil über Retries; Replay liefert dieselbe `run_id` |
| Puffer nach 300 s weg | kein Live-Text nach langer Abwesenheit | definierter Pfad: Status + Verlauf; kein Retry |
| `run_id` geht verloren (App-Daten gelöscht) | Lauf nicht mehr adressierbar | Status ist ohne `run_id` nicht erreichbar; der Turn endet trotzdem, der Text steht im Verlauf. Kein Schaden außer Anzeige |
| Hermes-Update ändert die Run-Fläche | App bricht | Fähigkeitenprüfung aus §5.2 ist der Riegel; Prüfstand A2/A6 nennt die Felder |
| iOS-Zustellung ungemessen | Latenz, nicht Lebensdauer | offene Messung §3.3 Punkt 2; blockiert die Entscheidung nicht |

## 11. Was ausdrücklich nicht gebaut wird

- Kein Patch an Hermes, keine Änderung an `api_server*.py`, keine
  Neuinstallation, kein Deployment.
- Keine Abschaltung von `_abandon_agent_task` (Variante a′).
- Kein Umbau von `ChatView`, kein neues Ereignismodell: der Vertrag bleibt
  `ChatStreamEvent`.
- Kein Verlaufs-Merge **während** eines laufenden Stroms (die offene Frage aus
  `docs/decision-stream-liveness.md` §3 Variante C bleibt offen).
- Kein `Last-Event-ID`-Reconnect auf dem Chat-Completions-Pfad.
- Keine zweite Sitzungsanlage, kein Fork, kein Multi-Device-Abgleich.

## 12. Quellen

**App (`74e161a`):**

- `Planer/Features/Chat/ChatConfiguration.swift:27` — `chatPath`; `:29` —
  `approvalPath` (`/v1/runs/%@/approval`); `:48` — `streamIdleTimeout = 900`.
- `Planer/Features/Chat/ChatStreamProvider.swift:93–98` — Protokoll;
  `:133–135` — Abbruch über `Task.cancel()`.
- `Planer/Features/Chat/ChatViewModel.swift:35` — Hintergrund-Hinweis; `:47` —
  Verlust-Text; `:560` — `cancel()`; `:629–677` — Hintergrundwechsel und
  `beginBackgroundTask`; `:791–830` — `run`; `:922–1016` — `streamTurn`;
  `:1141–1229` — `merge`; `:1367–1456` — `map` (Denken aus dem Verlauf).
- `Planer/Features/Chat/HermesChatAPI.swift:102–112` — `respondToApproval`.
- `Planer/Networking/NetworkClient.swift:308–339` — `Authorization: Bearer`.
- `docs/decision-stream-liveness.md` §2.3, §2.4, §6 — Disconnect = Abbruch,
  Watchdog, offene Messung.

**Hermes 0.21.5 (Checkout `206102314a`, laufendes Gateway):**

- `gateway/platforms/api_server.py:236` — Keepalive 10,0 s; `:699–714` —
  `_abandon_agent_task`; `:1388–1398` — `gateway.api_server`-Ganzzahlen;
  `:4107–4122` — 429-Konkurrenz; `:4385–4386` — `_RUN_STREAM_TTL = 300`,
  `_RUN_STATUS_TTL = 3600`; `:67–96` — Fähigkeitentabelle mit `session_delete`.
- `gateway/platforms/api_server_runs.py:119–157` — `_RunStream` (Backlog 1000,
  `attach`/`detach`); `:234–240` — Routen; `:258–284` — `_set_run_status`;
  `:315–349` — Ereignis-Callback; `:395–419` — `_durable_run_status`;
  `:461–468` — `202`-Antwort; `:620–757` — Annahme; `:748–751` — eigene Task;
  `:915–1005` — `_execute_run`; `:1064–1156` — Ereignisstrom
  (`last_seq`/`replay.truncated`/Keepalive); `:1168–1219` — Freigabe;
  `:1253–1276` — Stop; `:1284–1299` — TTL-Sweep.
- `gateway/platforms/api_server_openai_routes.py:569–600` — Status unter der
  Completion-ID; `:886–967` — Chat-Schreiber, Disconnect, `_abandon_agent_task`.
- `gateway/platforms/api_server_run_idempotency.py:21, 69–120` — terminale
  Status, SQLite-Store, 24-h-Aufbewahrung.
- `tools/approval_context.py:247–258` — `approvals.timeout`, Default 300 s;
  `gateway/platforms/base_exec_approval.py:78–81` — „doing nothing is a safe no“.
- `tests/gateway/test_api_server_sse_keepalive.py:1–8` — Abbruch als Absicht.

**Betrieb (2026-10-23):**

- `GET http://127.0.0.1:8642/health` → `{"status":"ok","version":"0.21.5"}`.
- `GET /v1/capabilities` → `run_submission`, `run_status`, `run_events_sse`,
  `run_stop`, `run_steer`, `run_approval_response` = `true`,
  `runs_idempotency.durable = true`, `retention_seconds = 86400`.
- Probe-Lauf `run_d638cfe30c…` (Sitzung `api_1792747389_55ac4ab5`): `202` um
  09:23:09, `running` ohne jeden Abonnenten, `completed` um 09:30:51 mit
  `output: "PROBE-OK"` und `usage.input_tokens: 27623`; die Antwort stand
  anschließend als `assistant`-Nachricht in
  `GET /api/sessions/api_…/messages`. Probe-Sitzung danach gelöscht (§3.3).

## 13. Übergabe

**Reihenfolge:**

1. Dieses Dokument (erledigt mit diesem Vorgang; eigener Branch, keine
   Code-Änderung).
2. **K-DETACH-2** (Umsetzung, eigener Vorgang): `ChatRunStreamProvider` gegen
   `ChatStreamProvider`, Turn-Datensatz, Resume-Pfad im `ChatViewModel`,
   Abbruch über `POST …/stop`, Verlust-Text ersetzen, Prüfstand.
3. **K-DETACH-3** (optional): Messung aus §3.3 Punkt 1 und 2 am Gerät; nur bei
   abweichendem Ergebnis wird §5.1 nachgezogen.

**Zwischenstände, an denen ein lauffähiger Stand vorliegen muss:**

- Nach Schritt 1: Dokument vorhanden, `git status` außer dem Dokument leer,
  keine Änderung an `Planer/**`, `Tests/**` oder Hermes.
- Nach Schritt 2: alle bestehenden Chat-Prüfstände grün, A1–A10 grün, M1–M3
  manuell bestanden; ein Turn, der während der Abwesenheit endet, erzeugt keine
  zweite Antwort.
- Nach Schritt 3: Messprotokoll mit Zeitstempeln; bei Abweichung ein
  Folgeauftrag mit neuem Default, kein stilles Nachjustieren.

**Scope-Grenze:** Alles aus §11. Insbesondere: keine Hermes-Änderung, kein
Patchen des Chat-Completions-Schreibers, kein neues Ereignismodell in der
Oberfläche.
