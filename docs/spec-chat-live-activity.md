# Live-Aktivität im Chat: was der Agent gerade tut, während er es tut

**Stand:** 2026-10-23 · **Vorgang:** MARAAA-203 (Delta zu spec-chat Rev 10)
**Art:** Entscheidung und Spezifikation, kein Code. Keine Änderung an `Planer/**`,
`Tests/**` oder an Hermes.
**Gilt für:** `Planer/Features/Chat` auf `origin/main` = `9d6b356`, Hermes 0.21.5
(Checkout `206102314a`, laufendes Gateway auf diesem Host, Prozess 1266).
**Baut auf:** `docs/decision-stream-liveness.md` (MARAAA-193) und
`docs/decision-detached-runs.md` (MARAAA-199). Dieses Dokument ersetzt keines von
beiden; es beantwortet die Anzeigefrage, die beide offen lassen.

---

## 0. Kurzfassung

**Flächen-Annahme (am 2026-10-23 bestätigt):** Gegenstand ist der **Chat-Tab der
Planer-App** (`Planer/Features/Chat`), also die Unterhaltung, die der Nutzer mit
Hermes führt. Das **Paperclip-Board ist nicht Gegenstand** — es ist ein
Fremdprodukt, seine Oberfläche wird hier nicht entworfen. Die Annahme ist vom
Auftraggeber bestätigt worden (Gate-Karte zu diesem Dokument, angenommen am
2026-10-23); alle Befunde unten gelten ausschließlich für den Chat-Tab. Sollte
später doch eine andere Fläche gemeint sein, ist dieses Dokument an der Stelle
falsch und muss zurückgewiesen werden, statt punktuell ergänzt zu werden.

1. **Der Nutzer sieht heute schon etwas — aber nicht das, wonach er fragt.**
   Live vorhanden sind: Text-Deltas, Denk-Spur, Werkzeugkarten und die
   Statuszeile „Werkzeug <name>“. Was **fehlt**, sind **Argumente und
   Ergebnisse** — sie stehen heute nicht auf der Leitung, sondern kommen erst
   mit dem Verlaufs-Merge am Turn-Ende (§2.2, §2.3/U3).
2. **Der Widerspruch „ich sehe erst am Ende etwas“ hat sechs mögliche Ursachen.
   Vier sind aus dem Code entscheidbar, eine ist gemessen und dominant, eine
   betrifft den Build auf dem Gerät:** ein
   Turn auf diesem Host blieb **102 s ohne ein einziges Inhaltsereignis** (nur
   Keepalives), ein zweiter **269 s ohne erstes Token**; erst danach kamen
   Denk- und Text-Deltas (§2.4). In dieser Zeit gibt es technisch nichts zu
   zeigen außer einer Phasenzeile — und genau das nimmt der Nutzer als „lädt
   erst am Ende“ wahr.
3. **Empfehlung: Variante B — Live-Verlaufsabgleich.** Solange ein Werkzeug
   läuft, liest die App den **bestehenden, schreibgeschützten** Verlauf
   (`GET /api/sessions/{id}/messages`, alle 3 s) und füllt damit Argumente und
   Ergebnisse in die **bereits vorhandenen** Live-Karten. Kein Hermes-Patch,
   keine Änderung am Wire-Vertrag, kein zweiter Antwortpfad (§5).
4. **Die Datenquelle dafür existiert schon und ist belegt:** Hermes schreibt den
   Werkzeugaufruf **vor** der Ausführung in die Sitzungsdatenbank
   (`turn_tool_round.py:127–130`) und das Ergebnis **unmittelbar danach**
   (`tool_executor.py:1146–1147`). Der Verlaufs-Endpunkt liefert beides
   (§2.5).
5. **Folge für `/v1/runs` (MARAAA-199):** Die dortige Empfehlung bleibt richtig
   und wird von B **nicht** ersetzt. B liest Historie, nicht Draht — nach dem
   Umstieg ist B der **Wiedereinstieg** nach einem toten Ereignisstrom. Eine
   Aussage aus MARAAA-199 §5.3 ist zu korrigieren: die Run-Fläche liefert live
   **kein** Reasoning, aber **doch** einen Ergebnis-Auszug
   (`tool.completed.preview`, 500 Zeichen), den die Chat-Fläche nicht hat
   (§5.5).
6. **`main` ist `9d6b356`** — bestätigt als `origin/main`. Der lokale Branch
   `main` steht eine Commit hinter (`74e161a`) und ist für Belege nicht zu
   benutzen (§2.1).

| Abnahmepunkt (MARAAA-203) | Beantwortet in |
|---|---|
| 1. Dokument mit §0–§7 | §0 bis §7 (Übergabe in §8) |
| 2. Ist-Aussagen je mit Datei:Zeile, Server gegen `206102314` | §2, §2.1, §5.5 |
| 3a. Was live sichtbar ist und warum der Nutzer es evtl. nicht sieht | §2.2, §2.3 |
| 3b. Argumente/Ergebnisse live, ohne den Wire-Vertrag zu brechen | §3, §4 (B), §5.1 |
| 3c. Auto-Aktualisierung bei serverseitig weiterlaufendem Turn | §3.4, §5.4 |
| 3d. Folgen für `/v1/runs` | §5.5 |
| 4. Ausführbarer Nachweis „kommt live“ gegen „kommt am Ende“ | §6.2 |
| 5. Keine Änderung an `Planer/**`/`Tests/**` | §8.3 |

---

## 1. Ziel und Nicht-Ziel

### 1.1 Ziel (ein Satz)

Der Nutzer erkennt **während** eines Turns, **welche Werkzeuge** der Agent
ausführt, **mit welchen Argumenten** und **mit welchem Ergebnis**, ohne den Turn
abzuwarten und ohne den Verlauf neu zu laden.

### 1.2 Nicht-Ziel

- **Keine Werkzeugausführung im Client.** Werkzeuge laufen serverseitig; die App
  zeigt, sie führt nicht aus.
- **Kein Eingriff in Hermes.** Kein Patch am Checkout, keine neue Wire-Version,
  kein zusätzliches Feld in `hermes.tool.progress` (das wäre Variante C, §4).
- **Keine Änderung an `/v1/runs`.** Die Run-Fläche gehört MARAAA-199; dieses
  Dokument beschreibt nur, wie sich B dazu verhält (§5.5).
- **Kein Push, kein WebSocket, kein Hintergrund-Polling.** Die Anzeige lebt,
  solange der Chat-Tab im Vordergrund ist; im Hintergrund gilt weiter
  `docs/decision-stream-liveness.md`.
- **Keine neuen Werkzeug-Detailflächen.** Die vorhandene `ToolCallCard` bleibt
  die einzige Darstellung; sie bekommt Inhalte, keine neue Form.
- **Keine Status- oder Fortschrittsprozentwerte.** Ein Werkzeug hat keinen
  Fortschritt, den der Server kennt; ein Balken wäre erfunden.

---

## 2. Ist-Beleg

### 2.1 Ausgangsstand: Versionen und Commits

| Prüfung | Ergebnis | Beleg |
|---|---|---|
| `origin/main` | `9d6b356` (R-CH11, 2026-10-23 09:16) | `git log -1 origin/main` |
| lokaler Branch `main` | `74e161a` — **eine Commit hinter `origin/main`** | `git rev-list --left-right --count main...origin/main` → `0 1` |
| `9d6b356` auf `main`? | ja, aber nur auf `origin/main`; lokal nicht | `git merge-base --is-ancestor 9d6b356 main` → nein |
| Hermes-Version | `0.21.5` | `GET http://127.0.0.1:8642/health` |
| Hermes-Commit | `206102314a811b01abb27d24ca6d05fdd1b977b5` | `hermes-agent/install-stamp.json`, `git log -1` im Checkout |
| laufender Prozess | PID 1266, `sys.path` = `/home/user/.hermes/hermes-agent` | `ps`, `gateway_state.json` |

**Folge:** Der Auftrag nennt `main` = `9d6b356` — das ist richtig, sofern
`origin/main` gemeint ist. Der lokale Branch ist veraltet; alle Zeilenangaben
unten gelten für `9d6b356`.

### 2.2 Was heute live sichtbar ist

| Element | Datei:Zeile | Was es zeigt | Wann es erscheint |
|---|---|---|---|
| Phasen-Zeile | `ChatPhaseStatusView.swift:15–33` (Fälle), `:24–32` (Texte) | „Verbindet …“, „Denkt nach …“, „Werkzeug <name>“, „Wartet auf Freigabe …“, „Schreibt …“ | ab `isStreaming` |
| Einbindung der Zeile | `ChatView.swift:35–36`, `:170–173` | außerhalb des Scrollinhalts, oberhalb des Verlaufs | dauerhaft im Turn |
| Arbeitsanzeige | `WorkingIndicatorView.swift:24–57` | „Hermes arbeitet …“ + Sekunden | solange kein Agent-Text |
| Ableitung der Phase | `ChatViewModel.swift:355–384` | `.tool(name:)` nur, wenn eine Karte `.running` ist (`:370–374`) | je Ereignis |
| Arbeitsanzeige-Bedingung | `ChatViewModel.swift:390–401` | true, wenn eine Karte läuft oder der Agent-Text leer ist | je Ereignis |
| Text-Deltas | `ChatViewModel.swift:1335–1340` | `entries[i].text += delta` | je `choices[0].delta.content` |
| Denk-Spur | `ChatViewModel.swift:1320–1333` | `reasoning` wächst, Klappe öffnet einmal (`:1010–1014`) | je `reasoning_content` |
| Werkzeugkarte | `ChatView.swift:323–334` → `ToolCallCard.swift:50–148` | Name, Emoji, Status, Argumente, Ergebnis (aufklappbar) | je `hermes.tool.progress` |
| Karte anlegen/fortschreiben | `ChatViewModel.swift:1430–1458` | setzt **nur** `toolName`, `toolEmoji`, `toolStatus` | je Fortschritts-Ereignis |
| Status einer Karte | `ChatDTOs.swift:250–257`, `ToolCallCard.swift:18–29` | `läuft` / `abgeschlossen` / `wartet auf Freigabe` / `abgelehnt` | — |
| Ereignis-Annahme | `ChatStreamProvider.swift:413–427` | `hermes.tool.progress`, `hermes.status`, `approval.request` | je benanntem SSE-Frame |

### 2.3 Was heute **nicht** live sichtbar ist — und warum

**Der Draht trägt keine Argumente und keine Ergebnisse.** Das ist keine
Vermutung, sondern der Inhalt der beiden Frames:

| Frame | Felder | Datei:Zeile |
|---|---|---|
| `hermes.tool.progress` (Start) | `tool`, `emoji`, `label`, `toolCallId`, `status` | `api_server_openai_routes.py:751–760` |
| `hermes.tool.progress` (Ende) | `tool`, `toolCallId`, `status` — **kein** `label`, **kein** `emoji` | `api_server_openai_routes.py:762–767` |
| App-Annahme dazu | genau diese fünf Felder | `ChatDTOs.swift:138–155` |

`label` ist ein **Vorschau-Text**, den der Server aus den Argumenten baut
(`build_tool_preview`, `:756–757`) — er ersetzt die Argumente nicht. Deshalb
zeigt die Karte live einen Namen und einen Status, und beim Aufklappen
„Argumente nicht geladen“ / „Ergebnis nicht geladen“
(`ToolCallCard.swift:100–111`).

Gefüllt werden beide Felder erst **nach** dem Turn, im Merge:

- Argumente: `ChatViewModel.swift:1669–1697` (`applyMergedAssistant`), Feld
  `toolArgs` aus `tool_calls[].function.arguments` (`ChatDTOs.swift:126–135`).
- Ergebnis: `ChatViewModel.swift:1702–1726` (`applyMergedTool`), Feld
  `toolResult` aus der `tool`-Nachricht.
- Aufruf des Merge: `ChatViewModel.swift:1375–1393`, Definition `:1520`.

**Der Merge ersetzt die Live-Karten nicht, er füllt sie.** Belegt:
`ChatViewModel.swift:1574–1578` entfernt nur `agent`- und `approval`-Einträge
des Turns; Werkzeugkarten bleiben stehen und werden über `toolCallID`
wiedergefunden (`:1675–1685`, `:1707–1714`). Ein laufender Status wird am Ende
auf `.completed` gesetzt (`:1600–1608`), und ein aufgeklappter Zustand bleibt
erhalten (`:1604–1607`, gesammelt in `:1564–1571`).

### 2.4 Der Widerspruch: sechs Ursachen, je mit Beleg

Der Nutzer sagt, er sehe „erst wenn der Agent komplett fertig geladen ist“
etwas. Das ist mit §2.2 nur vereinbar, wenn eine der folgenden Ursachen greift.
Jede ist einzeln geprüft:

| # | Ursache | Beleg | Status |
|---|---|---|---|
| U1 | **Die laufende App ist nicht dieser Stand** (alter Build) | nicht aus dem Repo entscheidbar | **offen** — Prüfung §6.2/D0 |
| U2 | **Das Modell liefert das erste Token erst nach Minuten** | gemessen: 102 s bzw. 269 s ohne ein Inhaltsereignis (§2.4.1) | **belegt, dominant** |
| U3 | **Die Leitung ist detailarm** (keine Argumente/Ergebnisse) | §2.3 | **belegt** |
| U4 | **Der Merge am Ende tauscht Einträge** | `ChatViewModel.swift:1574–1578` (nur agent/approval) | **belegt, aber nicht die Ursache** — Karten bleiben |
| U5 | **Der Verlauf scrollt bei Textwachstum nicht mit** | `ChatView.swift:275–277`: `onChange(of: entries.last?.id)` — eine wachsende Bubble ändert die ID nicht | **belegt** |
| U6 | **Der Server unterdrückt die Fortschritts-Frames** | Schalter `platforms.api_server.tool_progress_events`, Default `true` (`api_server.py:1240–1242`), auf diesem Host nicht gesetzt (`config.yaml` hat keinen `api_server`-Block) | **ausgeschlossen für diesen Host** |

#### 2.4.1 Messung auf diesem Host (2026-10-23, 13:07–13:13)

Zwei echte Ströme gegen `POST /v1/chat/completions` (Bearer
`API_SERVER_KEY`, `X-Hermes-Session-Id` gesetzt, `stream: true`), Frame-Zeiten
clientseitig mitgeschnitten. Modell: `escha-qwen38-27b-w2`
(`config.yaml:1–4`, Provider `http://192.168.9.100:9873/v1`).

| Turn | Prompt | Erstes Inhaltsereignis | Ende | Beobachtung |
|---|---|---|---|---|
| `probe-live-activity-1` | „Antworte mit genau zwei kurzen deutschen Sätzen …“ | `T+101,96 s` (`reasoning_content`) | Client-Abbruch bei `T+102,6 s` (Pipe geschlossen) | **102 s lang ausschließlich Keepalives**, kein `hermes.status`, kein `hermes.tool.progress` |
| `probe-live-activity-2` | „Liste die offenen Aufgaben aus dem Kanban-Board …“ | **nie** | Timeout des Clients bei `T+269 s` | 269 s ohne ein einziges Inhalts-, Status- oder Werkzeug-Ereignis |

Rohbefund Turn 1 (gekürzt, Zeit in s):

```
T+  0.01  chunk      {"delta": {"role": "assistant"}}
T+ 10.02  keepalive  : keepalive
T+ 20.04  keepalive  : keepalive
…         (zehn Keepalives, keine Lücke > 10,2 s)
T+101.96  chunk      {"delta": {"reasoning_content": "The"}}
T+101.98  chunk      {"delta": {"reasoning_content": " user"}}
T+102.01  chunk      {"delta": {"reasoning_content": " is"}}
```

Zwei Dinge sind daran wichtig:

1. **Die Keepalives kommen pünktlich** (10 s, `api_server.py:236`,
   `api_server_openai_routes.py:28–58`). Der Strom lebt; er ist nur leer.
2. **Der Server sendet in dieser Zeit nichts anderes.** Es gibt keinen
   `hermes.status` („warte auf den Anbieter“), obwohl der Schreiber ihn
   durchreichen würde (`api_server_openai_routes.py:915–916`) und der Agent ihn
   erzeugen könnte (`:615–620`).

Der Gateway-Log bestätigt die Zuordnung ohne weitere Aktivität dazwischen:
`13:07:07,907` Turn-Start → `13:08:50,443` „SSE client disconnected; interrupted
agent task chatcmpl-daecfb…“. In diesen 102 s steht **keine** Zeile zum Turn im
Log — kein Werkzeug, kein Status, keine Warteschlange.

**Grenze der Aussage:** Die Latenz liegt **oberhalb** von Hermes (Anbieter/
Modell). Sie ist kein Fehler dieses Repositories und durch keine App-Änderung
heilbar. Sie ist aber der Grund, warum der Nutzer „nichts“ sieht: In den ersten
100–270 s eines Turns gibt es außer der Phasenzeile tatsächlich nichts
anzuzeigen. Genau dort muss die Anzeige ehrlich sein (§3.1/S2) und darf nicht
suggerieren, es passiere nichts.

### 2.5 Die Datenquelle, die Argumente und Ergebnisse schon während des Laufs hat

Der Verlauf ist **kein** Endstand — er wird während des Turns fortgeschrieben:

| Zeitpunkt | Was in die Sitzungsdatenbank geschrieben wird | Datei:Zeile |
|---|---|---|
| Modell hat Werkzeugaufrufe beschlossen, **vor** jeder Ausführung | Assistenten-Nachricht **mit** `tool_calls` (enthält `function.arguments`) | `agent/turn_tool_round.py:127–130` — Kommentar: „Persist the tool-call turn before any tool side effects“ |
| Werkzeugergebnis liegt vor | `tool`-Nachricht mit `tool_call_id` und Inhalt, geflusht **vor** der Fortschritts-Projektion | `agent/tool_executor.py:1146–1147`, Helfer `:195–216` |

Der Endpunkt, der das liest, ist vorhanden und schreibgeschützt:
`GET /api/sessions/{id}/messages` (`ChatConfiguration.swift:28`,
`HermesChatAPI.swift:69`). Die Zeilenform ist im Fixture belegt:
`Tests/Fixtures/wire/hermes_messages.json` enthält eine Assistenten-Zeile mit
`tool_calls` (`display_kind: "tool"`, nicht `hidden`) und eine `tool`-Zeile mit
`tool_call_id` und Inhalt.

**Folge:** Es gibt bereits einen Weg zu Argumenten und Ergebnissen **während**
des Laufs, der weder den Wire-Vertrag noch Hermes anfasst. Variante B (§4) ist
genau dieser Weg.

---

## 3. Soll-Bild aus Nutzersicht

Der Nutzer schickt ab und sieht ab diesem Moment **eine Geschichte**, die
mitläuft — nicht ein Standbild und dann ein Ergebnis.

### 3.1 Die Zustände und was der Nutzer sieht

| # | Zustand | Was sichtbar ist | Spätestens nach |
|---|---|---|---|
| S1 | Turn gestartet, Server noch nicht verbunden | Statuszeile „Verbindet …“, Arbeitsanzeige mit Sekunden | 0 s |
| S2 | Verbunden, Modell rechnet (die gemessenen 100–270 s) | Statuszeile „**Wartet auf das Modell …**“ + Sekunden; darunter die letzte Werkzeugkarte des Turns, falls es eine gibt | 1 s nach dem ersten Ereignis |
| S3 | Denken kommt | Denk-Klappe mit laufendem Text; Statuszeile „Denkt nach …“ | mit dem ersten Delta |
| S4 | Werkzeug beschlossen, läuft | Karte mit **Name + Argumenten** (JSON, gekürzt), Status „läuft“; Statuszeile „Werkzeug <name>“ | ≤ `liveActivityPollInterval` (3 s) nach dem Persistieren |
| S5 | Werkzeug fertig | Karte mit **Ergebnis**, Status „abgeschlossen“; Karte bleibt aufgeklappt, wenn der Nutzer sie aufgeklappt hat | ≤ 3 s nach dem Persistieren |
| S6 | Mehrere Werkzeuge | Karten in Aufrufreihenfolge, jede mit eigenen Argumenten und eigenem Ergebnis; die laufende ist die letzte | wie S4/S5 |
| S7 | Antworttext strömt | Text wächst mit, **der Verlauf folgt dem Text** (nicht nur neuen Zeilen) | mit jedem Delta |
| S8 | Turn zu Ende | Merge; **nichts verschwindet**, Karten behalten Inhalt und Aufklappzustand | mit `finished` |

### 3.2 Die drei Regeln, die das Soll-Bild tragen

1. **Kein leerer Bildschirm ohne Erklärung.** Solange kein Inhalt da ist, steht
   in der Statuszeile, **worauf** gewartet wird (S2 statt „Denkt nach …“).
   „Denkt nach“ ist erst wahr, wenn Denken ankommt.
2. **Was der Server weiß, zeigt die App.** Argumente und Ergebnisse liegen
   während des Laufs im Verlauf (§2.5); sie werden abgeholt, nicht erwartet.
3. **Der Nutzer entscheidet über Details, die App nicht.** Eine Karte öffnet
   sich nie von selbst; der Aufklappzustand überlebt den Merge
   (`ChatViewModel.swift:1604–1607`).

### 3.3 Was sich für den Nutzer **nicht** ändert

- Der Antworttext kommt weiter über den Strom, nicht über den Verlauf.
- Die Denk-Spur bleibt live und wird nicht durch einen Verlaufsstand ersetzt.
- Freigaben (`approval.request`) laufen unverändert.
- Der Verlauf wird weiterhin erst am Turn-Ende endgültig zusammengeführt.

### 3.4 „Auto-Aktualisierung“ — was der Begriff hier bedeutet

Der Nutzer verlangt (MARAAA-202), dass die Anzeige **von selbst** weiterläuft.
Drei Fälle sind zu trennen:

| Fall | Was heute passiert | Was nach Variante B passiert |
|---|---|---|
| Strom lebt (Normalfall) | alles kommt über SSE | SSE **plus** Verlaufsabgleich für Details; kein Nutzereingriff |
| Strom schweigt (langsames Modell) | Keepalives, Phasenzeile, Sekunden | zusätzlich: S2-Text, und der Abgleich zeigt, sobald ein Werkzeug existiert |
| Strom tot, Turn läuft serverseitig weiter | **gibt es heute nicht**: ein Client-Disconnect bricht den Turn ab (`api_server_openai_routes.py:886–889`, `:965–967`; Logzeile `13:13:31` auf diesem Host) | nach MARAAA-199: der Abgleich läuft weiter und füllt die Karten; `/v1/runs/{id}/events?last_seq=` ersetzt den toten Strom (§5.5) |

**Wichtig:** „Auto-Aktualisierung während der Server weiterläuft“ ist heute
**nicht** versprechbar, weil der Server den Turn beim Verbindungsabriss
abbrechen lässt. Variante B legt die Anzeige aber so an, dass sie diesen Fall
später ohne Umbau trägt — sie liest den Verlauf, nicht den Strom.

---

## 4. Variantenvergleich

Vier Wege, das Soll-Bild aus §3 zu erreichen. Alle vier sind geprüft; drei
werden verworfen.

### (A) Anzeige-Feinschliff ohne neue Datenquelle

Nur das, was mit den heutigen Frames möglich ist: Statuszeile „Wartet auf das
Modell …“, Scrollen bei Textwachstum (`ChatView.swift:275–277`), Karte sagt
ausdrücklich „Argumente werden geladen …“ statt „nicht geladen“
(`ToolCallCard.swift:104–110`).

- **Nutzerfolge:** Der Nutzer versteht, *dass* gewartet wird, und verliert nicht
  den Anschluss an den Text. Er sieht weiterhin **keine** Argumente und
  **keine** Ergebnisse während des Laufs.
- **Risiko:** Erfüllt die Anforderung aus MARAAA-202 nur zur Hälfte; der Nutzer
  fragt ein zweites Mal.
- **Aufwand:** klein — `ChatView.swift`, `ChatPhaseStatusView.swift`,
  `ChatViewModel.swift` (Ableitung), `ToolCallCard.swift`.

### (B) Live-Verlaufsabgleich *(empfohlen)*

Während ein Werkzeug läuft, holt die App alle
`liveActivityPollInterval` den Verlauf ab (`GET /api/sessions/{id}/messages`,
`order: latest`, `id > watermark`) und füllt daraus die **vorhandenen**
Live-Karten: Argumente, Ergebnis, Status. Sie fügt nur Werkzeug-Einträge hinzu,
nie Agent-Text und nie Freigaben. Der Abschluss-Merge bleibt unverändert die
Autorität. Dazu der Feinschliff aus (A).

- **Nutzerfolge:** Genau das verlangte Bild — Werkzeugname, Argumente und
  Ergebnis erscheinen während des Laufs, spätestens 3 s nachdem der Server sie
  kennt. Zusätzlich verschwindet eine Klasse hängender Karten: bleibt das
  `completed`-Frame aus, setzt der Abgleich den Status aus dem Verlauf.
- **Risiko:** zusätzliche Last (eine Leseanfrage je 3 s, **nur** solange ein
  Werkzeug läuft); zwei Quellen für denselben Kartenzustand (Strom und
  Verlauf) — beherrschbar, weil beide über `toolCallID` identifizieren und der
  Merge derselbe idempotente Weg ist (`ChatViewModel.swift:1675–1685`,
  `:1707–1714`).
- **Aufwand:** mittel — `ChatViewModel.swift` (Abgleich + Lebenszyklus),
  `ChatConfiguration.swift` (Werte), `ChatView.swift` (Scrollen),
  `ChatPhaseStatusView.swift` (S2-Text), `Tests/verify_chat_live_activity.sh`.

### (C) Wire-Erweiterung in Hermes

`hermes.tool.progress` bekommt `args` und `result`; die App liest sie direkt.

- **Nutzerfolge:** bestmögliche Latenz (ein Frame statt einer Anfrage).
- **Risiko:** Eingriff in ein **fremdes** Repository, das dieses Team nicht
  versioniert; bei jedem Hermes-Update neu abzugleichen. Der Wire-Vertrag wäre
  stillschweigend erweitert, wenn keine Versionsangabe dazukommt — genau das
  verbietet die Entwurfsregel. Zusätzlich: Ergebnis-Texte können beliebig groß
  werden; eine Obergrenze und Redaktion müssten im Server entstehen.
- **Aufwand:** groß (Server-Änderung, Upstream-Abstimmung, Test dort) — und
  dauerhaft.

### (D) Sofortiger Umstieg auf `/v1/runs` (MARAAA-199, Variante a)

- **Nutzerfolge:** Turn überlebt den Client; Ereignisse sind ab Sequenz
  wiederaufsetzbar.
- **Risiko:** **verschlechtert** die Live-Sicht gegenüber heute: keine
  Reasoning-Deltas, keine `hermes.status`-Notizen, kein `toolCallId`, kein
  Emoji (§5.5). Zwei Umstellungen gleichzeitig (Transport **und** Anzeige)
  machen jeden Fehler mehrdeutig.
- **Aufwand:** groß; gehört MARAAA-199, nicht diesem Vorgang.

### Vergleich

| | (A) Feinschliff | **(B) Verlaufsabgleich** | (C) Wire-Erweiterung | (D) `/v1/runs` jetzt |
|---|---|---|---|---|
| Argumente live | nein | **ja, ≤ 3 s** | ja, sofort | nein (nur `preview`) |
| Ergebnis live | nein | **ja, ≤ 3 s** | ja, sofort | ja, Auszug (500 Z.) |
| Denk-Spur live | unverändert | unverändert | unverändert | **entfällt** |
| Hermes-Patch | nein | **nein** | **ja** | nein |
| Wire-Vertrag | unverändert | **unverändert** | erweitert | neuer Pfad |
| Auto-Aktualisierung nach Abriss | nein | vorbereitet | nein | ja |
| Aufwand | klein | **mittel** | groß | groß |
| Risiko | halbe Lösung | zwei Quellen | Fremd-Repo | Rückfall bei Details |

---

## 5. Empfehlung

**Variante B — Live-Verlaufsabgleich, einschließlich der Anzeige-Korrekturen aus
(A).** Kein Hermes-Patch, keine Änderung am Wire-Vertrag, kein zweiter
Antwortpfad.

Begründung in drei Sätzen: Die Daten, nach denen der Nutzer fragt, liegen
während des Laufs bereits in der Sitzungsdatenbank (§2.5); sie sind über einen
vorhandenen, schreibgeschützten Endpunkt erreichbar (`HermesChatAPI.swift:69`);
und der Weg dorthin ist derselbe, den der Abschluss-Merge schon geht — die
Karten werden über `toolCallID` wiedergefunden, nicht ersetzt
(`ChatViewModel.swift:1675–1685`). Damit entsteht **eine** Kartenlogik, nicht
zwei.

### 5.1 Was gebaut wird

1. **`ChatViewModel.applyHistoryDelta(_ messages: [ChatMessage])`** — neu.
   Verarbeitet **nur** `assistant`-Zeilen mit `tool_calls` und `tool`-Zeilen;
   ignoriert `user`/`system`/`hidden`. Für jeden Aufruf:
   - Karte über `toolCallID` suchen; fehlt sie, anlegen und in
     `turnEntryIDs` aufnehmen (sonst zeigt `turnPhase` sie nicht,
     `ChatViewModel.swift:370–374`).
   - `toolArgs` setzen, wenn die Karte noch keine hat.
   - `toolResult` setzen, wenn eine passende `tool`-Zeile in der Seite ist.
   - Status: `toolResult != nil ? .completed : .running`.
   - `toolName` nur setzen, wenn die Karte keinen Namen hat (der Live-Name aus
     `label` ist genauer).
2. **`ChatViewModel.liveActivitySync`** — neu. Eine `Task`-Schleife, gestartet
   mit dem **ersten** Werkzeug-Frame des Turns, beendet im `defer` von
   `streamTurn` (`ChatViewModel.swift:1286–1289` ist das vorhandene Muster).
   Je Runde: `api.messages(sessionID:limit:offset:0, order:.latest)`, dann
   `applyHistoryDelta` auf Zeilen mit `id > watermark`. Kein Schreiben, kein
   zweiter Merge.
3. **Abbruchbedingungen der Schleife** (alle vier, keine Verhandlung):
   Turn-Generation wechselt (`turnGeneration`, vorhandenes Muster
   `ChatViewModel.swift:1295–1300`), `isStreaming` wird falsch,
   `liveActivityMaxConsecutiveFailures` erreicht, `liveActivityMaxPolls`
   erreicht.
4. **Statuszeile S2: ein neuer Phasenfall `.waitingForModel`.** `ChatTurnPhase`
   (`ChatPhaseStatusView.swift:15–33`) bekommt genau **einen** Fall dazu,
   Titel „Wartet auf das Modell …“. Ableitung in `turnPhase`
   (`ChatViewModel.swift:355–384`) in dieser Reihenfolge: Freigabe → laufendes
   Werkzeug → Agent-Text (`writing`) → **kein Denken und kein Text, aber
   `streamStarted` (`waitingForModel`)** → sonst `thinking`.
   *Warum nicht umbenennen:* `.thinking` bedeutet „Denken kommt an“ und ist
   genau dann wahr, wenn Reasoning-Deltas eintreffen (`:1320–1333`). Ein
   umbenannter Fall würde während des Denkens „Wartet auf das Modell“ behaupten
   — die Zeile würde lügen. Zwei Zustände brauchen zwei Worte.
5. **Scrollen bei Textwachstum.** `ChatView.swift:275–277` beobachtet zusätzlich
   die Länge des letzten Agent-Textes (`entries.last?.text.count`), damit der
   Verlauf dem wachsenden Text folgt. Kein Timer, keine Animation ändern.
6. **Karte ohne irreführenden Text.** Solange `toolArgs == nil`, zeigt die
   Karte „Argumente werden geladen …“ statt „Argumente nicht geladen“
   (`ToolCallCard.swift:100–111`). Nach dem Turn bleibt „nicht geladen“ korrekt
   für Karten ohne Argumente.

### 5.2 Defaults (verbindlich, keine Magic Numbers im Code)

Alle Werte gehören nach `HermesChatConfiguration` (`ChatConfiguration.swift`),
nicht in den Ablauf.

| Wert | Default | Ableitung |
|---|---|---|
| `liveActivityPollInterval` | **3 s** | kleiner als der Server-Keepalive (10 s, `api_server.py:236`), damit der Abgleich merkbar früher greift als das nächste Lebenszeichen; groß genug, dass ein 60-s-Werkzeuglauf 20 Anfragen kostet |
| `liveActivityMaxConsecutiveFailures` | **2** | ein Aussetzer ist normal (Gerät wechselt das Netz), zwei in Folge sind ein Zustand |
| `liveActivityMaxPolls` | **200** | 200 × 3 s = 10 min Deckel; länger als jeder gemessene Werkzeuglauf, kürzer als `streamIdleTimeout` (900 s, `ChatConfiguration.swift:48`) |
| `liveActivityPageSize` | **`messagePageSize`** (100) | vorhandener Wert (`ChatConfiguration.swift`); deckt einen Turn mit vielen Werkzeugrunden in einer Seite |
| Startbedingung | erster `hermes.tool.progress`-Frame | vorher gibt es nichts abzugleichen — und der Abgleich soll die 100–270 s Modellwartezeit **nicht** mit Anfragen belegen |
| Endbedingung | `defer` in `streamTurn` | der Turn ist die Einheit, nicht die Karte |

**Bewusst kein** Abgleich vor dem ersten Werkzeug-Frame: In der Wartezeit
existiert keine Zeile, die etwas hinzufügen könnte (§2.4.1); die Anfragen wären
Last ohne Anzeige.

### 5.3 Bedingung, unter der die Empfehlung gilt

1. `GET /api/sessions/{id}/messages` ist für die Sitzung erreichbar und liefert
   Werkzeugzeilen mit `tool_call_id` (belegt: §2.5,
   `Tests/Fixtures/wire/hermes_messages.json`).
2. Die Sitzungs-ID ist bekannt (`currentSession != nil`). Bei einer in genau
   diesem Turn angelegten Sitzung ist sie es ab `prepareSession`.
3. `watermark` ist gesetzt (nicht `nil`) — sonst kein Abgleich, dieselbe Regel
   wie beim Merge (`ChatViewModel.swift:1536`).

Fällt 1 weg (ältere Installation ohne `tool_call_id` in `tool`-Zeilen), bleibt
Variante A: die Karten zeigen weiter Name und Status; nach dem Turn steht dort
„Argumente nicht geladen“, weil sie wirklich nicht geladen wurden. **Kein
stiller Rückfall** — die Karte sagt, was fehlt.

### 5.4 Warum nicht A, C oder D

- **A** erfüllt die Anforderung nicht: der Nutzer fragt nach Werkzeugen **und**
  Zwischenschritten, nicht nach einer freundlicheren Wartezeile.
- **C** ist die schnellste Lösung und die teuerste: ein Patch in einem fremden
  Repository, der bei jedem Update neu abgeglichen werden muss, plus eine
  stille Erweiterung des Wire-Vertrags. Für eine Anzeigequalität ist das der
  falsche Preis — dieselbe Abwägung wie in MARAAA-199 §5.3.
- **D** löst ein anderes Problem (Turn überlebt den Client) und **verschlechtert**
  dabei die Live-Sicht (§5.5). Zwei Umstellungen gleichzeitig sind nicht
  prüfbar.

### 5.5 Folgen für `/v1/runs` aus MARAAA-199

**Die Empfehlung dort bleibt bestehen.** Variante B widerspricht ihr nicht; sie
ist die Anzeigeschicht, die auch nach dem Umstieg gebraucht wird.

| Frage | Antwort |
|---|---|
| Ersetzt B den Run-Pfad? | Nein. B liest Historie; der Run-Pfad ersetzt den **Antwortstrom**. |
| Behindert B den Umstieg? | Nein. `applyHistoryDelta` kennt nur `ChatMessage`-Zeilen — dieselbe Form, die `merge` und `map` schon verarbeiten (`ChatViewModel.swift:1763`, `:1520`). |
| Was wird nach dem Umstieg aus B? | Der **Wiedereinstieg**: Läuft `GET /v1/runs/{id}/events?last_seq=` nicht mehr, hält der Verlaufsabgleich die Karten aktuell, bis der Ereignisstrom wieder hängt. |
| Was liefert der Run-Pfad live **weniger**? | Keine Reasoning-Deltas (`api_server_runs.py:328` verwirft `_thinking`; nur `reasoning.available` mit `preview`, `:97`), kein `toolCallId`, kein Emoji, keine `hermes.status`-Notizen. |
| Was liefert er live **mehr**? | **Ein Ergebnis-Auszug**: `tool.completed` trägt `preview` aus dem Werkzeugergebnis, redigiert und auf 500 Zeichen begrenzt (`api_server_runs.py:98`, `:101–108`, `:333–335`). Das ist eine **Korrektur zu MARAAA-199 §5.3**, wo die Run-Fläche als „ohne Argumente und Ergebnisse“ beschrieben ist. |
| Braucht B dann noch der Run-Pfad? | Ja: `toolCallId` fehlt dort, also ist eine Zuordnung Karte↔Ereignis über die Run-Fläche nicht möglich. B liefert genau diese Zuordnung. |

**Empfehlung an MARAAA-199:** Beim Umstieg `applyHistoryDelta` unverändert
übernehmen und den Ereignisstrom nur für Text, Denken und Freigaben benutzen;
Werkzeugdetails kommen aus dem Verlauf. Damit bleibt die Kartenlogik an einer
Stelle, unabhängig vom Transport.

---

## 6. Testplan (statisch, ohne Swift-Toolchain)

Die Prüfungen folgen der Hausform von `Tests/verify_chat_rev8.sh:1–27`:
`bash`, `grep`/`awk`, keine Swift-Toolchain, kein Netz, Exit 0/1/2, letzte
Zeile `Ergebnis: OK (chat-live-activity)`.

### 6.1 Die Prüfungen

Neu: `Tests/verify_chat_live_activity.sh`. Jede Zeile ist binär.

| # | Prüfung | Datei / Muster | Erwartung |
|---|---|---|---|
| L1 | Abgleichsfunktion existiert genau einmal | `ChatViewModel.swift` ~ `func applyHistoryDelta\(` | 1 Treffer |
| L2 | Abgleich fasst Agent-Text nicht an | Rumpf von `applyHistoryDelta` enthält kein `\.text \+=` | 0 Treffer |
| L3 | Abgleich fasst Freigaben nicht an | Rumpf enthält kein `kind: \.approval` | 0 Treffer |
| L4 | Abgleich schreibt nichts | Rumpf von `func messages(` in `HermesChatAPI.swift` enthält kein `POST` | 0 Treffer |
| L5 | Karten werden über `toolCallID` gefunden | `applyHistoryDelta` enthält `toolCallID ==` | ≥ 1 |
| L6 | Abgleich-Karten landen in `turnEntryIDs` | `applyHistoryDelta` enthält `turnEntryIDs\.insert` | ≥ 1 |
| L7 | Intervall kommt aus der Konfiguration | `ChatViewModel.swift` enthält `liveActivityPollInterval`; kein `sleep`-Aufruf mit Zahlenliteral | 1 Treffer / 0 Treffer |
| L8 | Deckel existiert | `ChatConfiguration.swift` ~ `liveActivityMaxPolls` | 1 Treffer |
| L9 | Fehlerzähler existiert | `ChatConfiguration.swift` ~ `liveActivityMaxConsecutiveFailures` | 1 Treffer |
| L10 | Schleife endet mit dem Turn | `ChatViewModel.swift` ~ `liveActivityTask\?\.cancel\(\)` im `defer` von `streamTurn` | ≥ 1 |
| L11 | Generation wird geprüft | `applyHistoryDelta`-Aufrufstelle enthält `turnGeneration` | ≥ 1 |
| L12 | Warte-Fall vorhanden | `ChatPhaseStatusView.swift` ~ `case waitingForModel` **und** `Wartet auf das Modell` | je ≥ 1 Treffer |
| L12b | Denk-Phase unverändert | `ChatPhaseStatusView.swift` ~ `case \.thinking: return "Denkt nach` | 1 Treffer |
| L13 | Karte sagt „werden geladen“ | `ToolCallCard.swift` enthält `Argumente werden geladen` | 1 Treffer |
| L14 | Scrollen folgt dem Text | `ChatView.swift` ~ `onChange\(of: .*text\.count` | ≥ 1 |
| L15 | Merge unverändert | `git diff` gegen `9d6b356` berührt `func merge(` nicht | 0 Hunks |
| L16 | Keine neue Kartenform | `ToolCallCard.swift` Signatur unverändert (7 Parameter) | 1 Treffer |
| L17 | Aufklappzustand bleibt Nutzerentscheidung | `applyHistoryDelta` enthält kein `toolDetailDisclosure = \.expanded` | 0 Treffer |

**Warum statisch genügt:** Der schwierige Teil ist nicht Rechnung, sondern
Reihenfolge und Zuständigkeit — wer darf welches Feld setzen, wer darf Einträge
anlegen, wer beendet die Schleife. Genau das ist per Text prüfbar. Ob die Karte
im Betrieb flüssig aussieht, ist keine Testfrage (§6.2/D4).

### 6.2 Diagnose: „kommt live“ gegen „kommt am Ende“

Der Nachweis ist auf **diesem Host** ausführbar und beantwortet die einzige
Frage, die Code nicht beantworten kann: Kommen die Frames unterwegs an oder
erst am Schluss?

**D0 — Build-Verdacht (U1) zuerst ausschließen.** In der App: Chat-Tab öffnen,
Turn senden, während des Laufs die Statuszeile beobachten. Steht dort
„Wartet auf das Modell …“, läuft der neue Build; steht „Denkt nach …“, ist die
installierte App älter als diese Änderung, und jeder weitere Befund ist
wertlos. (Nach dem Umbau ist das der billigste Test der ganzen Kette.)

**D1 — Frame-Zeiten eines echten Stroms.** Der folgende Aufruf gibt je Zeile die
Empfangszeit aus; `text/event-stream` wird ungepuffert gelesen
(`curl -N`).

```bash
KEY=$(grep '^API_SERVER_KEY=' ~/.hermes/.env | cut -d= -f2)
SID="probe-$(date +%s)"
curl -sN -H "Authorization: Bearer $KEY" -H 'Content-Type: application/json' \
  -H "X-Hermes-Session-Id: $SID" -H 'Accept: text/event-stream' \
  -d '{"messages":[{"role":"user","content":"Nenne die Zahl 7. Rufe kein Werkzeug auf."}],"stream":true}' \
  http://127.0.0.1:8642/v1/chat/completions \
| while IFS= read -r line; do printf '%s %s\n' "$(date +%s.%N)" "$line"; done
```

Auswertung (die drei Fälle sind unterscheidbar, ohne den Code zu kennen):

| Befund | Bedeutung |
|---|---|
| `event: hermes.tool.progress` **vor** dem ersten `delta.content`, mit Sekunden dazwischen | **kommt live** — die Kette funktioniert; bleibt die Anzeige leer, liegt es an der App (U1/U5). |
| Nur `: keepalive` bis kurz vor `finish_reason`, dann alle Deltas in < 1 s | **kommt am Ende** — der Anbieter puffert; die App kann nichts früher zeigen (U2). |
| Erster `delta.content` früh, aber `hermes.tool.progress` kommt nie | Fortschritts-Frames werden unterdrückt — Schalter prüfen (U6, `api_server.py:1240–1242`). |

**D2 — derselbe Aufruf über den Proxy.** Dasselbe Kommando gegen
`http://127.0.0.1:9180` (Caddy-Front auf diesem Host). Kommen die Zeilen dort
gebündelt, puffert der Proxy, nicht der Server. (Die App spricht je nach
Einstellung direkt oder über den Proxy; `ChatConfiguration.swift:156–170`
erlaubt nur einen Origin ohne Pfad.)

**D3 — Werkzeuglauf mit Argumenten.** Prompt, der ein harmloses Werkzeug
auslöst (z. B. „Liste die offenen Aufgaben, ändere nichts“), plus **parallel**
`GET /api/sessions/$SID/messages?order=latest` im Sekundentakt. Erwartung nach
Variante B: Die `assistant`-Zeile mit `tool_calls` erscheint **vor** der
`tool`-Zeile, und beide erscheinen **vor** `finish_reason`. Das ist der Beweis,
dass der Abgleich etwas zu holen hat, während das Werkzeug läuft.

**D4 — Sichtprüfung.** Ein Turn mit mindestens zwei Werkzeugen: Karten
erscheinen einzeln, jede mit Argumenten; ein aufgeklappter Zustand überlebt das
Turn-Ende; der Verlauf folgt dem wachsenden Text, ohne dass der Nutzer scrollt.

### 6.3 Was der Testplan **nicht** prüft

- Ob die Anzeige „gut“ aussieht (Geschmack, kein Kriterium).
- Ob die 3 s im Mobilfunk halten — das ist eine Messung am Gerät, nicht im
  Repo; sie ändert nur den Default, nicht die Bauform.
- Ob Hermes in einer künftigen Version andere Felder schickt; dafür gibt es
  `Tests/verify_wire_contracts.sh` und die Annahme in `ChatDTOs.swift:138–155`.

---

## 7. Offene Punkte

Keiner dieser Punkte blockiert die Umsetzung. **O1 ist entschieden** (Gate
angenommen am 2026-10-23, siehe §0). Die übrigen haben eine **Vorentscheidung**;
der Auftraggeber kann sie jederzeit kippen, ohne dass das Dokument neu
geschrieben werden muss.

| # | Punkt | Vorentscheidung (gilt, wenn niemand widerspricht) | Kosten der Kehrtwende |
|---|---|---|---|
| O1 | **Fläche**: Chat-Tab der Planer-App, nicht das Paperclip-Board | **entschieden und bestätigt** (§0) | hoch — das ganze Dokument wäre am falschen Gegenstand; Board-Anzeige bräuchte einen eigenen Vorgang |
| O2 | **Intervall 3 s** statt 2 s oder 5 s | 3 s (§5.2) | klein — ein Wert in `ChatConfiguration`; 2 s verdoppelt die Last, 5 s lässt Karten träger wirken als der Keepalive |
| O3 | **Abgleich erst ab dem ersten Werkzeug-Frame** statt ab Turn-Start | ab erstem Frame (§5.2) | klein — eine Bedingung; früher zu starten kostet 30–90 Anfragen pro Turn ohne Anzeigegewinn |
| O4 | **`.waitingForModel` als eigener Phasenfall** statt Umbenennung von `.thinking` | eigener Fall (§5.1/4) | klein — ein Enum-Fall, ein Titel, eine Ableitungszeile; die Umbenennung wäre billiger, würde aber während des Denkens das falsche Wort zeigen |
| O5 | **Ergebnis-Auszug** in der Karte kürzen auf `maxToolDetailCharacters` (4 000) | ja, vorhandener Wert (`ChatConfiguration.swift`) | klein — nur die Kürzungsstelle |
| O6 | **Run-Fläche**: B als Wiedereinstieg übernehmen (Empfehlung an MARAAA-199) | ja (§5.5) | mittel — sonst entstehen zwei Kartenlogiken |

**Nicht offen, sondern entschieden:** kein Hermes-Patch (C), kein sofortiger
`/v1/runs`-Umstieg (D), kein Push-Kanal, keine Fortschrittsbalken.

---

## 8. Übergabe an die Umsetzung

### 8.1 Reihenfolge

1. **W1 — Anzeige ohne neue Quelle (A).** Statuszeile „Wartet auf das Modell …“,
   Scrollen bei Textwachstum, Karte sagt „Argumente werden geladen …“.
   *Zwischenstand:* Der Nutzer versteht die Wartezeit; Karten haben weiterhin
   keine Inhalte. Prüfbar mit L12–L14.
2. **W2 — Abgleich als reine Funktion.** `applyHistoryDelta` plus Einheitstests
   auf Zeilenebene (Fixture `Tests/Fixtures/wire/hermes_messages.json`).
   *Zwischenstand:* Die Funktion füllt Karten aus einer mitgelieferten
   Nachrichtenliste; nichts ruft sie auf. Prüfbar mit L1–L6, L17.
3. **W3 — Lebenszyklus.** Start mit dem ersten Werkzeug-Frame, Ende im `defer`,
   Fehlerzähler, Deckel, Generation. *Zwischenstand:* Ein echter Turn zeigt
   Argumente und Ergebnisse während des Laufs; ein abgebrochener Turn lässt
   keine Schleife zurück. Prüfbar mit L7–L11 und D3.
4. **W4 — Prüfstand.** `Tests/verify_chat_live_activity.sh` mit L1–L17,
   Exit-Codes wie `verify_chat_rev8.sh`. *Zwischenstand:* Der Prüfstand ist
   grün und in der Suite aufrufbar.

Nach W3 ist das Nutzerziel erreicht; W4 ist die Absicherung.

### 8.2 Zwischenstände, an denen ein lauffähiger Stand vorliegen muss

| Nach | Lauffähig heißt |
|---|---|
| W1 | App startet, Chat sendet, Statuszeile zeigt den neuen Text, Verlauf scrollt mit dem Text |
| W2 | App startet unverändert; die neue Funktion ist vorhanden, aber tot |
| W3 | Ein Turn mit zwei Werkzeugen zeigt beide Karten mit Argumenten und Ergebnissen, **bevor** die Antwort fertig ist; Abbruch mitten im Werkzeug hinterlässt keine Anfragen |
| W4 | `bash Tests/verify_chat_live_activity.sh` endet mit `Ergebnis: OK (chat-live-activity)` |

### 8.3 Was ausdrücklich **nicht** gebaut wird

- **Keine Änderung an Hermes** — kein Feld in `hermes.tool.progress`, kein
  neuer Endpunkt, kein Patch im Checkout.
- **Keine Änderung an `/v1/runs`** und kein Umstieg des Antwortpfads.
- **Kein Push, kein WebSocket, kein Hintergrund-Polling**, keine
  Benachrichtigung bei Turn-Ende.
- **Keine neue Karte, kein neues Sheet, keine Detailansicht** — die vorhandene
  `ToolCallCard` bekommt Inhalte, keine neue Form.
- **Keine Änderung an `Planer/**` außerhalb** von `ChatViewModel`,
  `ChatConfiguration`, `ChatView`, `ChatPhaseStatusView`, `ToolCallCard`.
- **Keine Änderung an bestehenden Tests** außer dem neuen Prüfstand; `merge`,
  `map` und die Freigabe-Logik bleiben unangetastet.

### 8.4 Belege dieses Dokuments (zum Nachschlagen)

**App (`origin/main` = `9d6b356`):**

- `Planer/Features/Chat/ChatView.swift:35–44, 170–173, 230–279, 275–277, 323–334`
- `Planer/Features/Chat/ChatViewModel.swift:355–384, 390–401, 1010–1014,
  1280–1394, 1430–1458, 1520–1625, 1647–1726, 1734–1756, 1763–1772,
  1824–1849`
- `Planer/Features/Chat/ChatPhaseStatusView.swift:15–33`
- `Planer/Features/Chat/ToolCallCard.swift:18–29, 50–148`
- `Planer/Features/Chat/ChatDTOs.swift:126–155, 250–257`
- `Planer/Features/Chat/ChatStreamProvider.swift:97–122, 321–334, 396, 413–427`
- `Planer/Features/Chat/ChatConfiguration.swift:27–28, 48, 67, 91, 113, 156–170`
- `Planer/Features/Chat/HermesChatAPI.swift:69`
- `Planer/Features/Chat/WorkingIndicatorView.swift:24–57`
- `Tests/Fixtures/wire/hermes_messages.json` (Assistentenzeile mit
  `tool_calls`, `tool`-Zeile mit `tool_call_id`)
- `Tests/verify_chat_rev8.sh:1–27` (Hausform des Prüfstands)

**Hermes 0.21.5 (Checkout `206102314a`, Prozess 1266):**

- `gateway/platforms/api_server_openai_routes.py:28–58` (Keepalive-Schleife),
  `:615–620` (Status-Callback), `:751–760` (Werkzeug-Start), `:762–767`
  (Werkzeug-Ende), `:886–889` (Abbruch bei Disconnect), `:903–918`
  (Frame-Schreiber), `:965–967` (Disconnect-Behandlung)
- `gateway/platforms/api_server.py:236` (Keepalive 10,0 s), `:1240–1242`
  (`tool_progress_events`, Default `true`), `:68–76` (`_STATIC_FEATURE_FLAGS`,
  dort steht `tool_progress_events` **immer** auf `true` — die Capability sagt
  nichts über die wirksame Konfiguration), `:2550–2551` (`/v1/capabilities`)
- `gateway/platforms/api_server_runs.py:93–97` (`_FIXED_EVENT_FIELDS`), `:98`
  (500-Zeichen-Grenze), `:101–108` (Ergebnis-Auszug), `:328` (`_thinking`
  verworfen), `:333–335` (Auszug am `tool.completed`)
- `agent/turn_tool_round.py:106–130` (Werkzeugaufruf wird **vor** der
  Ausführung persistiert)
- `agent/tool_executor.py:195–216, 1146–1147` (Ergebnis wird **vor** der
  Fortschritts-Projektion persistiert)

**Betrieb (2026-10-23):**

- `GET http://127.0.0.1:8642/health` → `0.21.5`
- Frame-Messung 13:07–13:13 (§2.4.1); Logzeilen `13:07:07,907`,
  `13:08:50,443`, `13:09:02,451`, `13:13:31,427` in
  `/home/user/.hermes/logs/gateway.log`
- `~/.hermes/config.yaml` ohne `api_server`-Block (→ `tool_progress_events`
  Default `true`), Modell `escha-qwen38-27b-w2`
