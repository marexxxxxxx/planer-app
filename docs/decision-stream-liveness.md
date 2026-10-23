# Entscheidung: Wann gilt ein stiller Antwortstrom nach der Rückkehr als tot?

**Stand:** 2026-10-23 · **Vorgang:** MARAAA-193 (Befund 4 aus G-CH11/MARAAA-189)
**Art:** Entscheidung, kein Code. Keine Änderung an `Planer/**` oder `Tests/**`.
**Gilt für:** `Planer/Features/Chat` auf `74e161a` (in `main` gemerged als `a8d6b59`),
Hermes 0.21.5.

## Kurzfassung

1. Hermes 0.21.5 sendet auf `POST /v1/chat/completions` alle **10 s** eine
   SSE-Kommentarzeile `: keepalive` — auch während eines langen Werkzeuglaufs.
   Die App zählt jede gelesene Zeile als Lebenszeichen (`ChatStreamProvider.swift:332`).
2. Ein Client-Disconnect beendet den Agentenlauf serverseitig: der Server ruft
   `request_hard_interrupt` und `agent_task.cancel()` (`api_server.py:699–714`).
   Der Serverlog dieses Hosts enthält zehn solche Abbrüche, den letzten am
   **2026-10-23 um 06:39:01**. Die App sendet keinen expliziten Abbruch; ihr
   `Task.cancel()` schließt die Verbindung — das ist der „Abbruch-Befehl“, den
   der Nutzer beobachtet.
3. **Entscheidung:** Der Watchdog bleibt ein Abbruch mit anschließendem
   Verlaufsabgleich, aber die Schonfrist steigt von 12 s auf **25 s**. 12 s lag
   nur rund 1,5 s über dem Worst-Case-Abstand zwischen zwei Keepalives (10 s +
   0,5 s Poll) und konnte damit auch einen gesunden Strom abreißen. 25 s sind zwei
   verpasste Keepalives plus Reserve.

## 1. Frage

Der Resume-Watchdog (`ChatViewModel.swift:809–843`) bricht einen Strom ab, wenn
seit der Rückkehr aus dem Hintergrund eine volle Schonfrist
(`backgroundResumeGracePeriod`) ohne Lebenszeichen verging. Zu entscheiden war:

- Sendet Hermes während eines langen Werkzeuglaufs überhaupt Lebenszeichen?
- Beendet ein Client-Disconnect den Turn serverseitig?
- Ab welcher Frist und mit welchem Verhalten nach der Rückkehr darf die App
  abbrechen — und was sieht der Nutzer je Variante?

## 2. Belege

### 2.1 Der laufende Server ist 0.21.5 und läuft aus diesem Checkout

Am 2026-10-23 geprüft:

| Prüfung | Ergebnis |
|---|---|
| `GET http://127.0.0.1:8642/health` | `{"status":"ok","platform":"hermes-agent","version":"0.21.5"}` |
| Prozess 1266, `sys.path` | `sys.path.insert(0, '/home/user/.hermes/hermes-agent')` |
| `readlink /proc/1266/cwd` | `/home/user/.hermes` |
| `install-stamp.json` | `commit 206102314a…`, `baseVersion 0.21.5`, `displayVersion 0.21.5+7547.g2061023` |
| `git log -1` im Checkout | `206102314a…` — derselbe Commit |

Die Zeilenangaben unten gelten damit für den **laufenden** Code, nicht für eine
andere Version. Ein Update seit dem Start ist am Abgleich von `install-stamp`
und Checkout nicht erkennbar.

### 2.2 Keepalive alle 10 s — auch im Werkzeuglauf

**Servercode:**

- `gateway/platforms/api_server.py:236`:
  `CHAT_COMPLETIONS_SSE_KEEPALIVE_SECONDS = 10.0`.
- `gateway/platforms/api_server_openai_routes.py:28–58` (`_iter_stream_items`):
  Die Schleife wartet höchstens 0,5 s auf ein Queue-Element. Ist seit der
  letzten Aktivität mindestens der Keepalive-Wert vergangen, schreibt sie
  `b": keepalive\n\n"` (Zeile 51) und setzt den Zeitstempel neu.
- `gateway/platforms/api_server_openai_routes.py:886–967`
  (`_write_sse_chat_completion`): genau dieser Schreiber bedient
  `POST /v1/chat/completions` mit `stream: true`; der Aufruf steht in Zeile 903.
  Das ist die Route der App (`ChatConfiguration.chatPath`).
- **Werkzeuglauf:** `_on_tool_start` und `_on_tool_complete` legen nur je ein
  `hermes.tool.progress`-Ereignis in die Queue. Zwischen Start und Ende ist die
  Queue leer; die Schleife schreibt daher alle 10 s ein Keepalive. Der Agent
  läuft in einem Worker-Thread (`_spawn_stream_agent`, Zeilen 598–634; der
  Kommentar in Zeile 605 nennt den Worker-Thread), ein normales I/O-Werkzeug
  blockiert den Schreiber-Loop also nicht.

**Upstream-Test:** `tests/gateway/test_api_server_sse_keepalive.py:1–8`
dokumentiert die Absicht: entfernte OpenAI-kompatible Clients verwerfen einen
untätigen Strom nach etwa 20 s, und der Disconnect unterbricht den Turn;
deshalb muss jeder SSE-Schreiber vor diesem Fenster einen Kommentarrahmen
senden. Zeile 38 prüft `CHAT_COMPLETIONS_SSE_KEEPALIVE_SECONDS <= 20`.

**App-Seite:** `ChatStreamProvider.swift:97–121` (`ChatStreamLiveness`) zählt
jede gelesene Zeile; `:332` ruft `liveness?.recordLine()` **vor** `consume`,
also auch für Kommentare, Leerzeilen und verworfene Ereignisse. Ein Keepalive
ist damit ein Lebenszeichen im Sinne des Watchdogs.

**Folge für Befund 4:** Die dort als unbelegt bezeichnete Annahme ist für
Hermes 0.21.5 **belegt**. Ein langer Werkzeuglauf ohne Zwischen-Event ist nicht
still; er erhält alle 10 s ein Keepalive. Der verbleibende Fehler ist die
Spanne der Frist (12 s gegen 10 s + Poll), nicht das Fehlen eines Signals.

**Nicht belegt:** die drahtseitige Zustellung unter iOS-Suspension. Der Code
beweist das Serververhalten, nicht das Verhalten von Funk, TCP und URLSession
auf dem Gerät. Je nach Betriebsart läuft der Verkehr zusätzlich über Caddy
und/oder Cloudflare (`docs/hermes-405-diagnose.md`); ob ein Proxy die
10-s-Kommentare ungepuffert weiterreicht, ist nicht gemessen. Dafür §6.

### 2.3 Ein Client-Disconnect beendet den Lauf serverseitig

**Servercode:**

- `api_server_openai_routes.py:886–889` (Docstring von
  `_write_sse_chat_completion`): „On client disconnect the agent is interrupted
  (stops LLM calls), then its task wrapper cancelled.“
- `api_server_openai_routes.py:965–967`: `ConnectionResetError`,
  `ConnectionAbortedError`, `BrokenPipeError`, `OSError` werden gefangen; der
  Server ruft `_abandon_agent_task(agent_ref, agent_task, "SSE client
  disconnected")` und schreibt die Logzeile.
- `api_server.py:699–714` (`_abandon_agent_task`): Zeile 708
  `request_hard_interrupt(agent, reason, …)`, Zeile 711 `agent_task.cancel()`,
  Zeilen 713–714 warten auf den abgebrochenen Task.

**Beleg aus dem laufenden Betrieb:** `/home/user/.hermes/logs/gateway.log`
enthält **zehn** Zeilen des Musters

```
INFO gateway.platforms.api_server: SSE client disconnected; interrupted agent task chatcmpl-…
```

Erste: `2026-10-21 16:48:24,392`; letzte: `2026-10-23 06:39:01,467`. Am
2026-10-23 liegen fünf zwischen `05:34:38` und `06:39:01`. Der Pfad wird auf
diesem Host also tatsächlich ausgeführt.

**Grenzen der Aussage:**

1. Die Logzeile nennt keinen Client. Sie belegt den Mechanismus, nicht dass
   jeder dieser Abbrüche von der iOS-App kam.
2. Die Erkennung passiert beim **nächsten Schreibversuch**, nicht im Moment des
   TCP-FIN. Ein halb offener Socket kann den Lauf weiterlaufen lassen, bis ein
   Keepalive-Schreibvorgang fehlschlägt oder das Betriebssystem die Verbindung
   aufgibt.
3. Ist der Socket der App bereits tot, erreicht ihr `Task.cancel()` den Server
   möglicherweise nicht mehr. Dann kann der Lauf den lokalen Abbruch
   überleben — der einzige Fall, in dem „der Turn kann auf dem Server
   weiterlaufen“ zutrifft.

**Folge:** Im Normalfall (Socket lebt) ist der lokale Abbruch der App ein
serverseitiger Abbruch. Die Beobachtung des Nutzers ist im Ergebnis richtig.
Einen expliziten Abbruch-Endpunkt sendet die App nicht; der Vertrag lautet
ausdrücklich „Abbruch über `Task.cancel()`“ (`ChatStreamProvider.swift:133–135`).

### 2.4 Was der Watchdog heute tut

Auf `74e161a`:

- `scheduleResumeWatchdog` (`ChatViewModel.swift:809–843`): **eine** Task mit
  Schleife; je Runde ein Schnappschuss aus Lebenszeichen und Schonfrist,
  `sleep(grace)`, danach Generations- und `isStreaming`-Prüfung, Aussetzen bei
  entscheidbarer Freigabe, Vergleich des Lebenszeichens. Ohne Änderung:
  `abandonDeadStreamIfNeeded`.
- `resumeWatchdogSnapshot` (`:845–856`): liest
  `configuration.backgroundResumeGracePeriod`.
- `abandonDeadStreamIfNeeded` (`:910–962`): Generationsprüfung, `streamTask`
  abbrechen, höchstens `streamStopWaitLimit` (3 s) warten, Turn-Zustand hart
  schließen, `reconcileAfterBackground(announcesResume: false)`, danach
  Verlust-Text und Wiederholweg.
- `backgroundResumeGracePeriod` (`ChatConfiguration.swift:62`): **12** s. Der
  Kommentar behauptet, die 12 s lägen „bewusst über der kürzesten plausiblen
  Server-Pause“, nennt aber keine Zahl und keine Quelle. Das ist jetzt
  nachholbar (10 s Keepalive).
- Der Verlust-Text (`ChatViewModel.swift:47`) sagt: „Der Turn kann auf dem
  Server weiterlaufen“. Nach 2.3 stimmt das nur im halb offenen Grenzfall; im
  Normalfall hat der lokale Abbruch den Lauf bereits beendet. Der Text muss
  ehrlicher werden (Folgeauftrag, nicht Teil dieses Dokuments).

## 3. Optionen

| Variante | Was passiert | Vorteil | Nachteil | Nutzerfolge |
|---|---|---|---|---|
| **A. Abbrechen nach Frist, dann Verlauf laden** (heute, mit neuer Frist) | Nach einer vollen stillen Fensterlänge: `Task.cancel()`, begrenzt warten, hart schließen, `openSession`, Verlust-Text | Einfach, ein Zustand, kein zweiter Strom; der Server beendet den Lauf ohnehin beim Disconnect; Composer ist garantiert wieder frei | Ein gesunder, aber länger als die Frist stiller Strom würde abgebrochen; der Live-Text geht verloren | Composer nach ≤ Frist + 3 s frei; Live-Antwort weg, soweit sie nicht serverseitig gespeichert war; Teilstand über „Verlauf neu laden“ |
| **B. Weiter warten bis `streamIdleTimeout` (900 s)** | Kein Watchdog-Abbruch; der Strom darf bis zum Idle-Timeout leben | Kein falscher Abbruch; eine lebende Antwort kommt an | Bei totem Strom bleibt der Composer bis zu 15 Minuten gesperrt oder bis zum App-Neustart; genau der gemeldete Fehler | Nutzer kann nicht senden; im schlechten Fall hilft nur ein Neustart |
| **C. Verlauf abgleichen und Strom weiterlaufen lassen** | Beim Zurückkehren `GET /api/sessions/{id}/messages` lesen, in die laufende Liste mergen, Strom nicht abbrechen | Eine lebende Antwort bleibt live; der Verlauf zeigt den Serverstand | `openSession` leert heute `entries` und würde den Live-Text zerstören; es braucht eine zweite Merge-Logik, Duplikat- und Reihenfolge-Regeln und eine Antwort auf späte Merges (Befund 1, MARAAA-192); bei totem Strom fehlt weiterhin ein Ende | Antwort bleibt erhalten; Composer bleibt während des Stroms gesperrt; doppelte oder falsch sortierte Einträge möglich; deutlich mehr Code und Testfläche |
| **D. Serverstatus abfragen** (verworfen) | Vor dem Abbruch prüfen, ob der Run serverseitig noch läuft | Würde den halb offenen Fall erkennen | Für `POST /v1/chat/completions` gibt es keinen stabilen, dokumentierten Status-Endpunkt je Completion-ID; die App müsste die ID aus dem Strom speichern und eine neue REST-Fläche einführen; das Ergebnis wäre wieder nur ein Zeitpunkt, kein Zustand | Kein Gewinn gegenüber A, zusätzliche Abhängigkeit |

## 4. Entscheidung

**Variante A mit genau einem Default-Wert: `backgroundResumeGracePeriod = 25`
Sekunden.**

### Bedingung, unter der der Wert gilt

1. Nur nach der Rückkehr aus dem Hintergrund (`handleWillEnterForeground`) und
   nur, solange `isStreaming == true` — wie heute.
2. Die Frist ist **keine Turn-Grenze**, sondern ein volles stilles Fenster je
   Runde. Jedes neue Lebenszeichen (Ereignis **oder** gelesene Zeile) beginnt
   ein neues Fenster. Der Abbruch erfolgt erst, wenn eine ganze Fensterlänge
   ohne Änderung verging.
3. Nur die aktuelle Turn-Generation darf abgebrochen werden; die bestehende
   Generationsprüfung bleibt bindend.
4. Solange eine **entscheidbare** Freigabe offen ist (`hasDecidableApproval`),
   wird nicht abgebrochen. Eine abgelaufene Freigabe verlängert die Frist
   nicht (bestehendes V1-Verhalten).
5. Der Wert gilt für Hermes 0.21.5 mit 10 s Keepalive. Ändert der Server sein
   Intervall, wird die Frist neu abgeleitet: **2 × Keepalive-Intervall + 4 s
   Reserve**. Bei 10 s sind das 24 s; 25 s ist der aufgerundete Default.

### Warum 25 s

- Worst Case zwischen zwei Keepalives: 10 s Wartezeit + 0,5 s Poll-Granularität
  = **10,5 s**.
- Zwei verpasste Keepalives: **21 s**. Dazu 4 s für iOS-Aufwachen,
  URLSession-Puffer und Timer-Jitter: **25 s**.
- Ein gesunder Strom kann 25 s nicht erreichen, weil spätestens nach 10,5 s
  eine Zeile kommt. Ein toter Strom gibt den Composer nach 25 s (+ höchstens
  3 s `streamStopWaitLimit`) frei.
- 12 s lagen nur 1,5 s über dem Worst Case. Das ist keine Reserve, sondern eine
  Wette auf den Timer.

### Verhalten nach der Rückkehr

Der Ablauf bleibt **abbrechen → begrenzt warten → hart schließen → Verlauf
laden → ehrlicher Verlust-Text**. Kein zweiter Strom, keine zweite
Merge-Logik. Nach dem Abbruch ist der Lauf im Normalfall serverseitig beendet;
„weiter warten“ ist dann keine Option mehr. Deshalb muss der Text den Verlust
benennen und darf nicht behaupten, der Turn laufe weiter.

### Was mit dem Wert geändert werden muss (Folgeauftrag, nicht dieses Dokument)

- `ChatConfiguration.swift:52–62`: Wert auf 25; Kommentar mit Quelle
  (`CHAT_COMPLETIONS_SSE_KEEPALIVE_SECONDS = 10.0`,
  `api_server_openai_routes.py:28–58`) und der Ableitung 2 × 10,5 + 4.
- `Tests/verify_chat_ux2.sh:638–644` (B31): prüft heute einen Bereich
  **10–15 s**. Nach der Entscheidung muss dort der exakte Wert 25 stehen —
  und zusätzlich die Verwendungsstelle im Watchdog, nicht nur die Deklaration
  (Befund 3 aus G-CH11).
- `ChatViewModel.swift:47`: Verlust-Text an 2.3 anpassen.

## 5. Nutzerfolgen je Variante

| | A (25 s, empfohlen) | B (900 s warten) | C (Verlauf + Strom) |
|---|---|---|---|
| Composer-Sperre nach Rückkehr | höchstens 25 s + 3 s | bis 900 s oder Neustart | während des Stroms; bei totem Strom unbegrenzt ohne zweiten Watchdog |
| Live-Antwort | geht verloren, wenn der Strom wirklich tot war | bleibt erhalten, wenn er lebt | bleibt erhalten |
| Teilstand | wird nach dem Abbruch geladen; ein zweiter Reload kann mehr zeigen | wird nicht automatisch geladen | wird gemergt; Duplikate möglich |
| Serverlauf | wird durch den lokalen Abbruch beendet (Normalfall) | läuft weiter | läuft weiter |
| Ehrlichkeit der Meldung | Verlust muss benannt werden | keine Meldung, aber Sperre | schwierig: „läuft noch“ vs. „hängt“ |

## 6. Messung, die der Nutzer liefern muss (optional, nicht entscheidungsblockierend)

Die Entscheidung steht auf Servercode, Upstream-Test und Serverlog. Offen ist
nur die **drahtseitige** Zustellung auf dem Gerät. Wer sie schließen will,
liefert:

1. Einen Werkzeuglauf von mindestens 60 s (harmlos, z. B. ein Schlaf-Befehl)
   in einem Vordergrund-Strom, dann Hintergrund bei **T2**, Rückkehr bei **T3**.
2. Client-Zeitstempel jeder gelesenen Zeile (OSLog in `consumeEventStream`
   oder ein Proxy) und die Serverzeilen aus `~/.hermes/logs/gateway.log`.
3. Die exakte Serverzeile:
   `SSE client disconnected; interrupted agent task <completion-id>` sowie die
   zugehörige Trace-Zeile `started trace … for task:…:turn:…`.
4. Die Reihenfolge mit Zeitstempeln: **T0** POST; **T1** Tool-Start-Ereignis;
   **T1+10/+20/+30** Keepalive-Zeilen; **T2** Hintergrund; **T3** Rückkehr;
   **T4** entweder nächstes Keepalive (lebt) oder Server-Disconnect-Zeile (tot);
   **T5** `GET /api/sessions/{id}/messages` und ob der Teilstand enthalten ist.

Was die Messung ändern würde: Kommen Keepalives auf dem Gerät nachweislich
seltener als 20 s, muss die Reserve erhöht werden. Erscheint die
Disconnect-Zeile schon wenige Sekunden nach T2, war der Lauf bereits tot und
der lokale Abbruch ist nur noch Aufräumen. Fehlt der Teilstand bei T5, muss der
Verlust-Text das sagen. Ohne diese Messung bleibt es bei 25 s.

## 7. Risiken

| Risiko | Wirkung | Begrenzung |
|---|---|---|
| 25 s Composer-Sperre bei totem Strom | Nutzer wartet länger als heute | begrenzt und angekündigt; 3 s Stop-Wartezeit obendrauf; kein Neustart nötig |
| Keepalive ist Implementierungsdetail von 0.21.5 | Ein Serverupdate kann das Intervall ändern | Wert und Quelle stehen an einer Stelle; bei Hermes-Update `CHAT_COMPLETIONS_SSE_KEEPALIVE_SECONDS` und den 20-s-Test gegenprüfen |
| CPU-gebundenes Werkzeug hält den Event-Loop | Keepalives verspäten sich | 25 s deckt zwei Intervalle; bei dauerhafter Überschreitung Server-Timer entkoppeln (nicht dieses Repo) |
| Halb offener Socket | Serverlauf überlebt den lokalen Abbruch; T5 ist unvollständig | Verlust-Text darf keinen laufenden Turn behaupten; „Verlauf neu laden“ bleibt sichtbar |
| B31 ist an 10–15 s gebunden | Suite wird nach der Wertänderung rot | Test im selben Folgeauftrag auf den exakten Wert 25 und die Verwendungsstelle umstellen |
| Kein Client-Keepalive, kein Reconnect | App bleibt vom Serverrhythmus abhängig | bewusst: keine zweite Liveness-Quelle, kein `Last-Event-ID`-Umbau in diesem Schritt |

## 8. Quellen

**App (`74e161a`):**

- `Planer/Features/Chat/ChatConfiguration.swift:52–62` — `backgroundResumeGracePeriod = 12`, Kommentar ohne Quelle.
- `Planer/Features/Chat/ChatViewModel.swift:47` — Verlust-Text.
- `Planer/Features/Chat/ChatViewModel.swift:809–843` — Watchdog-Schleife.
- `Planer/Features/Chat/ChatViewModel.swift:845–856` — Schnappschuss/Frist.
- `Planer/Features/Chat/ChatViewModel.swift:910–962` — Abbruch und Nachladen.
- `Planer/Features/Chat/ChatStreamProvider.swift:97–121, 332` — Lebenszeichen.
- `Planer/Features/Chat/ChatStreamProvider.swift:133–135` — Abbruchvertrag.
- `Tests/verify_chat_ux2.sh:638–644` — B31, Bereich 10–15 s.

**Hermes 0.21.5 (Checkout `206102314a`, laufender Prozess 1266):**

- `gateway/platforms/api_server.py:236` — Keepalive-Konstante 10,0 s.
- `gateway/platforms/api_server.py:699–714` — `_abandon_agent_task`.
- `gateway/platforms/api_server_openai_routes.py:28–58` — Keepalive-Schleife.
- `gateway/platforms/api_server_openai_routes.py:598–634` — Worker-Thread und Queue.
- `gateway/platforms/api_server_openai_routes.py:886–967` — Chat-Completions-Schreiber und Disconnect.
- `tests/gateway/test_api_server_sse_keepalive.py:1–8, 38` — 20-s-Client-Frist, 10-s-Keepalive.

**Betrieb:**

- `GET http://127.0.0.1:8642/health` → Version 0.21.5 (2026-10-23).
- `/home/user/.hermes/logs/gateway.log` — zehn `SSE client disconnected; interrupted agent task …`-Zeilen, 2026-10-21 16:48:24 bis 2026-10-23 06:39:01.

## 9. Übergabe

**Reihenfolge:**

1. Dieses Dokument committen (erledigt mit diesem Vorgang).
2. Folgeauftrag „P-LIVE-2“: `backgroundResumeGracePeriod` auf 25 setzen,
   Kommentar mit Quelle und Ableitung, B31 auf den exakten Wert und die
   Verwendungsstelle umstellen, Verlust-Text an 2.3 anpassen.
3. Optional: Messung aus §6; nur bei abweichendem Ergebnis wird der Wert neu
   abgeleitet.

**Zwischenstände, an denen ein lauffähiger Stand vorliegen muss:**

- Nach Schritt 1: Dokument vorhanden, kein Code geändert, `git status` außer
  dem Dokument leer.
- Nach Schritt 2: `Tests/verify_chat_ux2.sh` grün; alle übrigen Chat-Skripte
  unverändert grün; manuell: ein toter Strom gibt den Composer nach ≤ 25 s
  frei, ein lebender Strom mit 10-s-Keepalives wird nie abgebrochen.

**Was ausdrücklich nicht gebaut wird:**

- Keine Änderung an der Watchdog-Struktur, der Generationen- oder
  Freigabe-Logik.
- Keine zweite Merge-Logik, kein Verlaufs-Merge während des Stroms.
- Kein neuer Server-Endpunkt, keine Server-Installation, keine Änderung an
  Hermes.
- Kein Client-Keepalive, kein `Last-Event-ID`/Reconnect, keine Änderung an
  `streamIdleTimeout`.
- Keine Änderung an `Planer/**` oder `Tests/**` in diesem Vorgang.
