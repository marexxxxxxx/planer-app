#!/usr/bin/env bash
#
# Statische Abnahme der Live-Aktivitaet im Chat (MARAAA-204, W1-W4).
#
# Grundlage: `docs/spec-chat-live-activity.md` (MARAAA-203), §5.1 (Bausteine),
# §5.2 (Defaults) und §6.1 (Pruefungen L1-L17). Die Pruefungen sind woertlich
# aus §6.1 uebernommen; L18-L20 sind der Nachtrag aus MARAAA-208 (Review F1/F4).
#
# Rein statisch: grep/awk/git, keine Swift-Toolchain, kein Netz, kein Aufruf
# anderer Tests.
#
#   bash Tests/verify_chat_live_activity.sh
#
# Exit 0 = alle Pruefungen gruen
# Exit 1 = mindestens eine rot
# Exit 2 = falscher Aufruf
# Letzte Zeile bei Erfolg: Ergebnis: OK (chat-live-activity)
# Letzte Zeile bei Fehler: Ergebnis: FEHLGESCHLAGEN (chat-live-activity)
#
set -euo pipefail

if [[ $# -gt 0 ]]; then
    echo "Aufruf: bash Tests/verify_chat_live_activity.sh" >&2
    exit 2
fi

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$root"

chat="Planer/Features/Chat"
vm="$chat/ChatViewModel.swift"
cfg="$chat/ChatConfiguration.swift"
view="$chat/ChatView.swift"
phase="$chat/ChatPhaseStatusView.swift"
card="$chat/ToolCallCard.swift"
api="$chat/HermesChatAPI.swift"

fail=0

pass() { echo "ok:   $1"; }
bad()  { echo "FAIL: $1"; fail=1; }

need() { if grep -qE "$2" "$1"; then pass "$3"; else bad "$3  [$1 ~ /$2/]"; fi; }
ban() { if grep -qE "$2" "$1"; then bad "$3  [$1 ~ /$2/]"; else pass "$3"; fi; }

# `grep -c` endet bei 0 Treffern mit Status 1; unter `pipefail` darf das den
# Zaehler nicht verfaelschen. Deshalb erst den Status schlucken, dann zaehlen.
count_matches() {
    local n
    n="$(grep -cE "$2" "$1" 2>/dev/null || true)"
    echo "${n:-0}" | tr -d ' '
}

exactly() {
    local file="$1" pattern="$2" want="$3" label="$4" n
    n="$(count_matches "$file" "$pattern")"
    if [[ "$n" -eq "$want" ]]; then
        pass "$label (Treffer: $n)"
    else
        bad "$label (Treffer: $n, erwartet: $want)  [$file ~ /$pattern/]"
    fi
}

at_least() {
    local file="$1" pattern="$2" min="$3" label="$4" n
    n="$(count_matches "$file" "$pattern")"
    if [[ "$n" -ge "$min" ]]; then
        pass "$label (Treffer: $n)"
    else
        bad "$label (Treffer: $n, erwartet: >= $min)  [$file ~ /$pattern/]"
    fi
}

# Abschnitt einer Datei: von der Zeile, die $2 enthaelt, bis zur ersten Zeile,
# die $3 enthaelt (beide Grenzen eingeschlossen). Grenzen sind woertlich und
# werden mit index() verglichen — ein Regex wuerde bei jedem `\(` in awk
# warnen und die Grenze unschaerfer machen.
section() {
    awk -v s="$2" -v e="$3" '!f && index($0, s) > 0 { f=1 } f { print; if (index($0, e) > 0) exit }' "$1"
}

section_has() {
    local file="$1" start="$2" end="$3" pattern="$4" label="$5" body
    body="$(section "$file" "$start" "$end")"
    if [[ -z "$body" ]]; then
        bad "$label  [$file: Abschnitt /$start/../$end/ nicht gefunden]"
        return
    fi
    if grep -qE "$pattern" <<<"$body"; then
        pass "$label"
    else
        bad "$label  [$file, Abschnitt /$start/../$end/ ~ /$pattern/]"
    fi
}

section_lacks() {
    local file="$1" start="$2" end="$3" pattern="$4" label="$5" body
    body="$(section "$file" "$start" "$end")"
    if [[ -z "$body" ]]; then
        bad "$label  [$file: Abschnitt /$start/../$end/ nicht gefunden]"
        return
    fi
    if grep -qE "$pattern" <<<"$body"; then
        bad "$label  [$file, Abschnitt /$start/../$end/ ~ /$pattern/]"
    else
        pass "$label"
    fi
}

# Trefferzahl innerhalb eines Abschnitts. Fuer Zaehlungen, die nur im Rumpf
# einer Funktion gelten sollen (z. B. der lokale Cursor, F1).
section_count() {
    local file="$1" start="$2" end="$3" pattern="$4" n
    n="$(section "$file" "$start" "$end" | grep -cE "$pattern" 2>/dev/null || true)"
    echo "${n:-0}" | tr -d ' '
}

# Klammerblock ab der ersten Zeile eines Abschnitts, die $4 enthaelt, bis zur
# Zeile, auf der die Klammerung wieder auf 0 steht. So laesst sich ein `defer`
# von gleichnamigen Bloecken davor und dahinter unterscheiden. Die Grenze ist
# woertlich (index()); `-v` bekommt deshalb kein Regex-Escaping.
#
# Bewusst ein einziger awk-Lauf ueber die Datei statt `section | awk`:
# der fruehere `exit` des Lesers beendete den Schreiber nicht, dieser lief
# in eine geschlossene Pipe und der Lauf starb mit rc=141 (SIGPIPE, Flake
# F7/F1 in L10a). Ein Prozess kann sich nicht selbst die Pipe schliessen.
section_block() {
    awk -v s="$2" -v e="$3" -v o="$4" '
        !in_section && index($0, s) > 0 { in_section = 1 }
        in_section {
            if (!f) {
                if (index($0, o) > 0) {
                    f = 1
                } else {
                    if (index($0, e) > 0) in_section = 0
                    next
                }
            }
            print
            line = $0
            opens = gsub(/\{/, "{", line)
            closes = gsub(/\}/, "}", line)
            if (opens > 0) seen = 1
            depth += opens - closes
            if (seen && depth <= 0) exit
        }' "$1"
}

section_block_has() {
    local file="$1" start="$2" end="$3" open="$4" pattern="$5" label="$6" body
    body="$(section_block "$file" "$start" "$end" "$open")"
    if [[ -z "$body" ]]; then
        bad "$label  [$file: Block /$open/ in /$start/../$end/ nicht gefunden]"
        return
    fi
    if grep -qE "$pattern" <<<"$body"; then
        pass "$label"
    else
        bad "$label  [$file, Block /$open/ in /$start/../$end/ ~ /$pattern/]"
    fi
}

# Rumpf zwischen zwei woertlichen Zeilenmarken eines Abschnitts: ab der Zeile
# **nach** $4 bis **vor** die Zeile mit $5. Fuer Verzweigungen, deren Koerper
# nur eine Zeile belegt (`} else {` .. `polls += 1`), wo section_block wegen
# der Klammerung auf derselben Zeile nichts liefern kann.
#
# Wie section_block ein einziger awk-Lauf: ein `section | awk` mit fruehem
# `exit` wuerde den Schreiber wieder in eine geschlossene Pipe laufen lassen
# (rc=141, Flake F7/F1).
section_between() {
    awk -v s="$2" -v e="$3" -v a="$4" -v b="$5" '
        !in_section && index($0, s) > 0 { in_section = 1 }
        in_section {
            if (!f) {
                if (index($0, a) > 0) { f = 1; next }
                if (index($0, e) > 0) in_section = 0
                next
            }
            if (index($0, b) > 0) exit
            print
        }' "$1"
}

section_between_has() {
    local file="$1" start="$2" end="$3" from="$4" to="$5" pattern="$6" label="$7" body
    body="$(section_between "$file" "$start" "$end" "$from" "$to")"
    if [[ -z "$body" ]]; then
        bad "$label  [$file: Rumpf /$from/../$to/ in /$start/../$end/ nicht gefunden]"
        return
    fi
    if grep -qE "$pattern" <<<"$body"; then
        pass "$label"
    else
        bad "$label  [$file, Rumpf /$from/../$to/ ~ /$pattern/]"
    fi
}

# Erste Zeilennummer (relativ zum Abschnitt) einer woertlichen Zeile. Fuer
# Reihenfolge-Aussagen wie "Cursor erst nach dem Filter fortschreiben".
section_line() {
    local file="$1" start="$2" end="$3" needle="$4" body
    body="$(section "$file" "$start" "$end")"
    awk -v p="$needle" 'index($0, p) > 0 { print NR; exit }' <<<"$body"
}

# Trefferzahl im Rumpf zwischen zwei Zeilenmarken (siehe section_between_has).
section_between_count() {
    local file="$1" start="$2" end="$3" from="$4" to="$5" pattern="$6" body n
    body="$(section_between "$file" "$start" "$end" "$from" "$to")"
    n="$(grep -cE "$pattern" <<<"$body" 2>/dev/null || true)"
    echo "${n:-0}" | tr -d ' '
}

# ---------------------------------------------------------------------------
# L1-L6, L17: der Abgleich als reine Funktion (W2).
# ---------------------------------------------------------------------------

delta_start='private func applyHistoryDelta('
delta_end='private func apply(_ approval:'

# L1: genau eine Definition.
exactly "$vm" 'func applyHistoryDelta\(' 1 'L1 applyHistoryDelta existiert genau einmal'

# L2: kein Agent-Text.
section_lacks "$vm" "$delta_start" "$delta_end" '\.text \+=' \
    'L2 Abgleich fasst Agent-Text nicht an'

# L3: keine Freigaben.
section_lacks "$vm" "$delta_start" "$delta_end" 'kind: \.approval' \
    'L3 Abgleich fasst Freigaben nicht an'

# L2b: kein Merge — der Turn-Abschluss bleibt die Autoritaet (§5.1).
section_lacks "$vm" "$delta_start" "$delta_end" 'merge\(' \
    'L2b Abgleich ruft keinen Merge auf'

# L4: der Verlaufs-GET bleibt ein GET.
section_has "$api" 'func messages(' '    }' 'method: \.get' \
    'L4a Verlaufsabruf ist ein GET'
section_lacks "$api" 'func messages(' '    }' '(\.post|POST)' \
    'L4b Verlaufsabruf schreibt nichts'

# L5: Karten werden ueber toolCallID gefunden.
section_has "$vm" "$delta_start" "$delta_end" 'toolCallID ==' \
    'L5 Karten werden ueber toolCallID gefunden'

# L6: neue Karten landen in turnEntryIDs.
section_has "$vm" "$delta_start" "$delta_end" 'turnEntryIDs\.insert' \
    'L6 Abgleich-Karten landen in turnEntryIDs'

# L17: der Aufklappzustand bleibt Nutzerentscheidung.
section_lacks "$vm" "$delta_start" "$delta_end" 'toolDetailDisclosure = \.expanded' \
    'L17 Abgleich oeffnet keine Karte'

# ---------------------------------------------------------------------------
# L7-L11: Lebenszyklus und Defaults (W3).
# ---------------------------------------------------------------------------

# L7: Takt aus der Konfiguration, kein Zahlenliteral im Ablauf.
exactly "$vm" 'liveActivityPollInterval\b' 1 'L7a Takt kommt aus der Konfiguration'
section_lacks "$vm" 'private func liveActivitySync(' 'private func applyHistoryDelta(' \
    'sleep\([^)]*[0-9]' 'L7b kein sleep mit Zahlenliteral'

# L9/L8: Deckel und Fehlerzaehler stehen in der Konfiguration und wirken.
exactly "$cfg" 'liveActivityMaxPolls\b' 1 'L8a Deckel steht in HermesChatConfiguration'
exactly "$cfg" 'liveActivityMaxConsecutiveFailures\b' 1 \
    'L9a Fehlerzaehler steht in HermesChatConfiguration'
section_has "$vm" 'private func liveActivitySync(' 'private func applyHistoryDelta(' \
    'liveActivityMaxPolls' 'L8b Schleife prueft den Deckel'
section_has "$vm" 'private func liveActivitySync(' 'private func applyHistoryDelta(' \
    'liveActivityMaxConsecutiveFailures' 'L9b Schleife prueft den Fehlerzaehler'

# L10: die Schleife startet mit dem Werkzeug-Frame und endet im defer.
section_block_has "$vm" 'private func streamTurn(' 'F15: Der Server' 'defer {' \
    'liveActivityTask\?\.cancel\(\)' 'L10a Abgleich endet mit dem Turn'
section_has "$vm" 'private func streamTurn(' 'F15: Der Server' \
    'case .toolProgress' 'L10b Werkzeug-Frame ist die Startbedingung'
section_has "$vm" 'case .toolProgress' 'case .status' \
    'startLiveActivitySync\(' 'L10c Werkzeug-Frame startet den Abgleich'

# L11: die Aufrufstelle prueft die Generation.
section_has "$vm" 'private func liveActivitySync(' 'private func applyHistoryDelta(' \
    'turnGeneration' 'L11a Generation wird geprueft'
section_has "$vm" 'private func liveActivitySync(' 'private func applyHistoryDelta(' \
    'applyHistoryDelta\(' 'L11b Abgleich ruft applyHistoryDelta auf'

# ---------------------------------------------------------------------------
# L12-L14: Anzeige (W1).
# ---------------------------------------------------------------------------

need "$phase" 'case waitingForModel$' 'L12a Warte-Fall vorhanden'
need "$phase" 'Wartet auf das Modell' 'L12b Warte-Text vorhanden'
exactly "$phase" 'case \.thinking: return "Denkt nach' 1 \
    'L12c Denk-Phase bleibt woertlich'

exactly "$card" 'Argumente werden geladen' 1 'L13 Karte sagt „werden geladen“'

at_least "$view" 'onChange\(of: .*text\.count' 1 'L14 Scrollen folgt dem Text'

# ---------------------------------------------------------------------------
# L15/L16: nichts Bestehendes wird umgebaut.
# ---------------------------------------------------------------------------

# Basis: der Stand, gegen den die Spezifikation prueft (9d6b356), sonst der
# Merge-Base mit origin/main, sonst der Spezifikations-Commit. Ohne Basis ist
# die Pruefung rot — ein stiller Freibrief waere schlimmer als ein Fehlschlag.
base=""
for candidate in 9d6b356 "$(git merge-base HEAD origin/main 2>/dev/null || true)" \
                 28d5ca4 "$(git merge-base HEAD origin/docs/spec-chat-live-activity 2>/dev/null || true)"; do
    if [[ -n "$candidate" ]] && git cat-file -e "$candidate^{commit}" 2>/dev/null; then
        base="$candidate"
        break
    fi
done

if [[ -z "$base" ]]; then
    bad "L15 keine Basis fuer den Merge-Vergleich gefunden"
else
    base_copy="$(mktemp "${TMPDIR:-/tmp}/live-activity-base.XXXXXX")"
    git show "$base:$vm" > "$base_copy"
    base_merge="$(awk '/private func merge\(/{f=1} f{print} f&&/^    }$/{exit}' "$base_copy")"
    rm -f "$base_copy"
    head_merge="$(awk '/private func merge\(/{f=1} f{print} f&&/^    }$/{exit}' "$vm")"
    if [[ -n "$base_merge" && "$base_merge" == "$head_merge" ]]; then
        pass "L15 merge unveraendert gegen ${base:0:7}"
    else
        bad "L15 merge wurde gegen ${base:0:7} beruehrt"
    fi
fi

# L16: die Karte behaelt ihre Form — sieben Parameter, woertlich verglichen.
# F4/MARAAA-208: die blosse Anzahl genuegt nicht; eine Typaenderung
# (`argumentsText: String?` -> `String`) muss rot werden.
card_sig="$(section "$card" 'struct ToolCallCard: View {' 'var body:' \
    | grep -E '^    let [A-Za-z]+: ' || true)"
expected_card_sig='    let name: String
    let emoji: String?
    let status: ToolCallStatus
    let argumentsText: String?
    let resultText: String?
    let isExpanded: Bool
    let onToggle: () -> Void'
if [[ "$card_sig" == "$expected_card_sig" ]]; then
    pass "L16 ToolCallCard-Signatur woertlich unveraendert (7 Parameter)"
else
    bad "L16 ToolCallCard-Signatur geaendert (erwartet: 7 Parameter woertlich)"
fi

# ---------------------------------------------------------------------------
# L18-L20: Abgleich nur waehrend eines Werkzeuglaufs + lokaler Cursor
# (Nachtrag MARAAA-208, Review F1).
# ---------------------------------------------------------------------------

sync_start='private func liveActivitySync('
sync_end='private func applyHistoryDelta('
running_start='private var hasRunningToolCard'

# L18: der Laufzustand wird vor jeder Anfrage abgefragt, und nur eine Karte
# dieses Turns mit Status .running haelt den Abgleich wach.
section_has "$vm" "$sync_start" "$sync_end" 'let running = hasRunningToolCard' \
    'L18a Abgleich fragt den Laufzustand ab'
section_has "$vm" "$running_start" "$sync_start" 'turnEntryIDs\.contains' \
    'L18b nur Karten des laufenden Turns zaehlen'
section_has "$vm" "$running_start" "$sync_start" 'toolStatus == \.running' \
    'L18c nur laufende Karten halten den Abgleich wach'
# M1: die Anfrage steht unter `if running`; `if true` pollt jeden Takt und
# hebt die Pause auf (Wartezeit auf das Modell bleibt nicht lastfrei).
section_has "$vm" "$sync_start" "$sync_end" '^[[:space:]]*if running \{' \
    'L18d Anfrage nur bei laufendem Werkzeug: Verzweigung prueft `running`, nicht `true`'

# L19: ein lokaler Cursor begrenzt die Uebernahme; er wird einmal aus dem
# Wasserstand gesetzt, wandert vorwaerts und laesst den Merge-Wasserstand in Ruhe.
cursor_init="$(section_count "$vm" "$sync_start" "$sync_end" 'cursor = watermark \?\? -1')"
if [[ "$cursor_init" -eq 1 ]]; then
    pass "L19a Cursor wird genau einmal aus dem Wasserstand gesetzt"
else
    bad "L19a Cursor wird je Runde zurueckgesetzt (Treffer: $cursor_init, erwartet: 1)"
fi
section_has "$vm" "$sync_start" "$sync_end" '\$0\.id > cursor' \
    'L19b Cursor begrenzt die neuen Zeilen'
# M3: der Cursor muss auf die neueste gesehene ID wandern; `max(cursor,
# cursor)` laesst ihn stehen und jede Runde uebernimmt alle Zeilen erneut.
section_has "$vm" "$sync_start" "$sync_end" 'cursor = max\(cursor, newest\)' \
    'L19c Cursor wandert auf die neueste ID fort (`cursor = max(cursor, newest)`)'
# M4: erst filtern, dann fortschreiben. Zieht die Fortschreibung vor den
# Filter, ist `fresh` immer leer und die Zeilen werden uebersprungen.
fresh_line="$(section_line "$vm" "$sync_start" "$sync_end" 'let fresh = page.messages')"
cursor_line="$(section_line "$vm" "$sync_start" "$sync_end" 'cursor = max(cursor')"
if [[ -n "$fresh_line" && -n "$cursor_line" && "$fresh_line" -lt "$cursor_line" ]]; then
    pass "L19e Filter liest den Cursor vor der Fortschreibung (Zeile $fresh_line < $cursor_line)"
else
    bad "L19e Cursor wird vor dem Filter fortgeschrieben (fresh: ${fresh_line:-fehlt}, cursor: ${cursor_line:-fehlt})"
fi
# M6: auch `watermark=...` ohne Leerzeichen ist eine Schreibzugriff auf den
# Wasserstand des Abschluss-Merges und muss rot werden.
section_lacks "$vm" "$sync_start" "$sync_end" 'watermark[[:space:]]*=[^=]' \
    'L19d Wasserstand des Abschluss-Merges bleibt unberuehrt (auch `watermark=` ohne Leerzeichen)'

# L20: nach dem letzten Werkzeug genau eine Abschlussrunde, dann Pause.
section_has "$vm" "$sync_start" "$sync_end" 'else if finalRoundPending \{' \
    'L20a Abschlussrunde nach dem letzten Werkzeug ist vorhanden'
section_has "$vm" "$sync_start" "$sync_end" 'var finalRoundPending = true' \
    'L20b Abschlussrunde ist ab dem Start offen'
final_consume="$(section_between_count "$vm" "$sync_start" "$sync_end" \
    '} else if finalRoundPending {' '} else {' 'finalRoundPending = false')"
if [[ "$final_consume" -eq 1 ]]; then
    pass "L20c Abschlussrunde wird im Abschlusszweig genau einmal verbraucht"
else
    bad "L20c Abschlussrunde wird nicht genau einmal verbraucht (Treffer: $final_consume, erwartet: 1)"
fi
# M2: ein spaeteres Werkzeug muss die Abschlussrunde erneut scharf stellen.
# Neutralisiert man dieses Wieder-Scharfstellen, verliert der letzte Lauf sein
# Ergebnis. Der Block haengt an `let running`, nicht an `if running` — damit
# bleibt dieser Befund unabhaengig von M1.
section_block_has "$vm" "$sync_start" "$sync_end" 'let running = hasRunningToolCard' \
    'finalRoundPending = true' \
    'L20d laufendes Werkzeug schaerft die Abschlussrunde erneut scharf'
# M7: ohne Werkzeug und ohne offene Abschlussrunde endet die Runde vor der
# Anfrage. Fehlt das `continue`, faellt der Ablauf in `polls += 1` und pollt
# weiter — die Pause entfaellt.
section_between_has "$vm" "$sync_start" "$sync_end" '} else {' 'polls += 1' \
    '^[[:space:]]*continue$' \
    'L20e Pause beendet die Runde vor der Anfrage (`continue` im else-Zweig)'

# ---------------------------------------------------------------------------
# E1-E4, E9: die fuenf in MARAAA-213 benannten Restluecken.
# ---------------------------------------------------------------------------

# E1: `polls += 1` steht hinter dem Gate. Zieht man es davor, verbrauchen
# uebersprungene Takte (kein laufendes Werkzeug, keine offene Abschlussrunde)
# Budget — die erlaubten Anfragen fehlen dann am Ende des Laufs.
poll_line="$(section_line "$vm" "$sync_start" "$sync_end" 'polls += 1')"
gate_line="$(section_line "$vm" "$sync_start" "$sync_end" 'let running = hasRunningToolCard')"
if [[ -n "$poll_line" && -n "$gate_line" && "$poll_line" -gt "$gate_line" ]]; then
    pass "E1 Budget wird erst nach dem Gate verbraucht (polls: Zeile $poll_line > Gate: $gate_line)"
else
    bad "E1 Budget wird vor dem Gate verbraucht (polls: ${poll_line:-fehlt}, Gate: ${gate_line:-fehlt}; erwartet: polls nach dem Gate)"
fi

# E2: nach einer erfolgreichen Anfrage wird der Fehlerzaehler zurueckgesetzt.
# Ohne den Reset beenden zwei **nicht aufeinanderfolgende** Fehler den Abgleich.
section_between_has "$vm" "$sync_start" "$sync_end" \
    'let page = try await api.messages(' '} catch {' \
    'consecutiveFailures = 0' \
    'E2 Erfolg setzt den Fehlerzaehler zurueck (kein Abbruch nach zwei nicht aufeinanderfolgenden Fehlern)'

# E3: angewandt wird die gefilterte Menge, nicht die ganze Seite. Mit
# `applyHistoryDelta(page.messages)` waere der Cursor wirkungslos und jede
# Runde uebernaehme erneut alle Zeilen.
delta_body="$(section "$vm" "$sync_start" "$sync_end")"
if [[ -z "$delta_body" ]]; then
    bad "E3 Abgleich wendet die gefilterten Zeilen an  [$vm: Abschnitt /$sync_start/../$sync_end/ nicht gefunden]"
elif grep -qE 'applyHistoryDelta\(fresh\)' <<<"$delta_body" \
     && ! grep -qE 'applyHistoryDelta\(page\.messages\)' <<<"$delta_body"; then
    pass "E3 Abgleich wendet nur die gefilterten Zeilen an (applyHistoryDelta(fresh))"
else
    bad "E3 Abgleich wendet die ganze Seite an (erwartet: applyHistoryDelta(fresh), verboten: applyHistoryDelta(page.messages))"
fi

# E4: hoechstens ein Abgleich-Task je Turn. Ohne den Guard legt jedes
# `.toolProgress`-Frame einen weiteren Task an und die Last vervielfacht sich.
start_start='private func startLiveActivitySync('
start_end='private func liveActivitySync('
section_has "$vm" "$start_start" "$start_end" \
    'guard liveActivityTask == nil else \{ return \}' \
    'E4 hoechstens ein Abgleich-Task je Turn (guard liveActivityTask == nil)'

# E9: der Guard **nach** dem `await` schuetzt den neuen Turn. Fehlt er, kann
# ein spaetes Ergebnis des alten Laufs in den inzwischen begonnenen Turn
# schreiben. Die frueheren Guards davor decken diesen Fall nicht ab.
after_await="$(section_between "$vm" "$sync_start" "$sync_end" \
    'let page = try await api.messages(' 'let fresh = page.messages')"
if [[ -z "$after_await" ]]; then
    bad "E9 Guard nach dem await schuetzt den neuen Turn  [$vm: Rumpf /let page = try await api.messages(/../let fresh = page.messages/ nicht gefunden]"
elif grep -qE 'generation == turnGeneration' <<<"$after_await" \
     && grep -qE 'abandonedGeneration != generation' <<<"$after_await"; then
    pass "E9 Guard nach dem await schuetzt den neuen Turn (generation + abandonedGeneration)"
else
    bad "E9 Guard nach dem await fehlt (erwartet: generation == turnGeneration und abandonedGeneration != generation vor dem Anwenden)"
fi

# ---------------------------------------------------------------------------

echo "HEAD: $(git rev-parse --short HEAD 2>/dev/null || echo unbekannt)"

if [[ "$fail" -ne 0 ]]; then
    echo "Ergebnis: FEHLGESCHLAGEN (chat-live-activity)"
    exit 1
fi
echo "Ergebnis: OK (chat-live-activity)"
exit 0
