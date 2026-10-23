#!/usr/bin/env bash
#
# Statische Abnahme der zwei Rev-8-Leistungen R1 (Turn-Rettung) und R2
# (Generierungsdauer) fuer CH4 auf `ac109f0`.
#
# Grundlage: `spec-chat-rev8-delta` (MARAAA-177) in der durch
# `spec-chat-rev8-delta-erratum-e1` (MARAAA-181, Revision 3) korrigierten
# Fassung. Das Erratum ersetzt ausschliesslich die Zeilen R7, R8, R9 (§7.3.1)
# und D7, D9 (§7.3.2) sowie die Lesefassung der Signaturen; alle uebrigen
# Zeilen gelten wie in Rev 8 §7.3 geschrieben. Die Ersatzzeilen und die
# Abschnittsgrenzen sind aus Erratum §4.3/§4.2 woertlich uebernommen.
#
# Rein statisch: grep/awk/Dateipruefungen, keine Swift-Toolchain, kein Netz,
# kein Aufruf anderer Tests.
#
#   bash Tests/verify_chat_rev8.sh [rescue|duration|all]     # Default: all
#
# Exit 0 = alle Pruefungen des gewaehlten Abschnitts gruen
# Exit 1 = mindestens eine rot
# Exit 2 = falscher Aufruf
# Letzte Zeile bei Erfolg: Ergebnis: OK (chat-rev8)
# Letzte Zeile bei Fehler: Ergebnis: FEHLGESCHLAGEN (chat-rev8)
#
set -euo pipefail

case "${1:-all}" in
    rescue|duration|all) mode="${1:-all}" ;;
    *)
        echo "Aufruf: bash Tests/verify_chat_rev8.sh [rescue|duration|all]" >&2
        exit 2
        ;;
esac
if [[ $# -gt 1 ]]; then
    echo "Aufruf: bash Tests/verify_chat_rev8.sh [rescue|duration|all]" >&2
    exit 2
fi

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$root"

chat="Planer/Features/Chat"
vm="$chat/ChatViewModel.swift"
view="$chat/ChatView.swift"
cfg="$chat/ChatConfiguration.swift"
prov="$chat/ChatStreamProvider.swift"
sse="$chat/ChatSSE.swift"
dtos="$chat/ChatDTOs.swift"

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

at_least() {
    local file="$1" pattern="$2" min="$3" label="$4" n
    n="$(count_matches "$file" "$pattern")"
    if [[ "$n" -ge "$min" ]]; then
        pass "$label (Treffer: $n)"
    else
        bad "$label (Treffer: $n, erwartet: >= $min)  [$file ~ /$pattern/]"
    fi
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

# Abschnitt einer Datei: von der Zeile, die $2 enthaelt, bis zur ersten Zeile,
# die $3 enthaelt (beide Grenzen eingeschlossen). Grenzen sind **woertlich**
# und werden mit index() verglichen — ein Regex wuerde bei jedem `\(` in awk
# warnen und die Grenze unschaerfer machen.
section() {
    awk -v s="$2" -v e="$3" '!f && index($0, s) > 0 { f=1 } f { print; if (index($0, e) > 0) exit }' "$1"
}

section_has() {
    local file="$1" start="$2" end="$3" pattern="$4" label="$5" body
    body="$(section "$file" "$start" "$end")"
    if grep -qE "$pattern" <<<"$body"; then
        pass "$label"
    else
        bad "$label  [$file, Abschnitt /$start/../$end/ ~ /$pattern/]"
    fi
}

section_lacks() {
    local file="$1" start="$2" end="$3" pattern="$4" label="$5" body
    body="$(section "$file" "$start" "$end")"
    if grep -qE "$pattern" <<<"$body"; then
        bad "$label  [$file, Abschnitt /$start/../$end/ ~ /$pattern/]"
    else
        pass "$label"
    fi
}

# Erratum §4.1: semantisch `exactly`, nur auf dem Abschnitt statt auf der Datei.
# Der leere Abschnitt ist ausdruecklich rot — sonst waere eine umbenannte
# Grenze ein stiller Freibrief.
section_exactly() {
    local file="$1" start="$2" end="$3" pattern="$4" want="$5" label="$6" body n
    body="$(section "$file" "$start" "$end")"
    if [[ -z "$body" ]]; then
        bad "$label  [$file: Abschnitt /$start/../$end/ nicht gefunden]"
        return
    fi
    n="$(grep -cE "$pattern" <<<"$body" 2>/dev/null || true)"
    n="${n:-0}"
    if [[ "$n" -eq "$want" ]]; then
        pass "$label (Treffer: $n)"
    else
        bad "$label (Treffer: $n, erwartet: $want)  [$file, Abschnitt /$start/../$end/ ~ /$pattern/]"
    fi
}

section_at_least() {
    local file="$1" start="$2" end="$3" pattern="$4" min="$5" label="$6" body n
    body="$(section "$file" "$start" "$end")"
    if [[ -z "$body" ]]; then
        bad "$label  [$file: Abschnitt /$start/../$end/ nicht gefunden]"
        return
    fi
    n="$(grep -cE "$pattern" <<<"$body" 2>/dev/null || true)"
    n="${n:-0}"
    if [[ "$n" -ge "$min" ]]; then
        pass "$label (Treffer: $n)"
    else
        bad "$label (Treffer: $n, erwartet: >= $min)  [$file, Abschnitt /$start/../$end/ ~ /$pattern/]"
    fi
}

# Reihenfolge zweier woertlicher Marken **innerhalb** eines Abschnitts: gruen
# nur, wenn beide vorkommen und $5 nach $4 steht.
section_order() {
    local file="$1" start="$2" end="$3" first="$4" second="$5" label="$6" body
    body="$(section "$file" "$start" "$end")"
    if awk -v a="$first" -v b="$second" '
        index($0, a) > 0 && !ia { ia = NR }
        index($0, b) > 0 && !ib { ib = NR }
        END { exit !(ia && ib && ib > ia) }' <<<"$body"; then
        pass "$label"
    else
        bad "$label  [$file, Abschnitt /$start/../$end/: »$first« muss vor »$second« stehen]"
    fi
}

# Rumpf ab der Zeile mit $2 bis zur schliessenden Klammer derselben
# Verschachtelungstiefe (`{`/`}` je Zeile gezaehlt).
brace_block() {
    awk -v s="$2" '
        !on && index($0, s) > 0 { on = 1 }
        on {
            print
            line = $0
            o = gsub(/\{/, "", line)
            c = gsub(/\}/, "", line)
            depth += o - c
            if (seen && depth <= 0) exit
            if (o > 0) seen = 1
        }' "$1"
}

block_has() {
    local file="$1" start="$2" pattern="$3" label="$4" body
    body="$(brace_block "$file" "$start")"
    if [[ -z "$body" ]]; then
        bad "$label  [$file: Rumpf ab »$start« nicht gefunden]"
        return
    fi
    if grep -qE "$pattern" <<<"$body"; then
        pass "$label"
    else
        bad "$label  [$file, Rumpf ab »$start« ~ /$pattern/]"
    fi
}

block_lacks() {
    local file="$1" start="$2" pattern="$3" label="$4" body
    body="$(brace_block "$file" "$start")"
    if [[ -z "$body" ]]; then
        bad "$label  [$file: Rumpf ab »$start« nicht gefunden]"
        return
    fi
    if grep -qE "$pattern" <<<"$body"; then
        bad "$label  [$file, Rumpf ab »$start« ~ /$pattern/]"
    else
        pass "$label"
    fi
}

# Rumpf eines Blockes **innerhalb** eines Abschnitts: $2/$3 grenzen den
# Abschnitt (woertlich, wie `section`), $4 ist die Zeile, ab der die
# Klammerbilanz gezaehlt wird (z.B. `defer {`). Ein leerer Rumpf ist rot —
# sonst waere eine umbenannte Grenze ein stiller Freibrief.
section_block_has() {
    local file="$1" start="$2" end="$3" blockstart="$4" pattern="$5" label="$6" body
    body="$(awk -v sec="$start" -v fin="$end" -v s="$blockstart" '
        !sec_on && index($0, sec) > 0 { sec_on = 1 }
        sec_on && index($0, fin) > 0 { exit }
        sec_on && !on && index($0, s) > 0 { on = 1 }
        on {
            print
            line = $0
            o = gsub(/\{/, "", line)
            c = gsub(/\}/, "", line)
            depth += o - c
            if (seen && depth <= 0) exit
            if (o > 0) seen = 1
        }' "$file")"
    if [[ -z "$body" ]]; then
        bad "$label  [$file: Block »$blockstart« im Abschnitt /$start/../$end/ nicht gefunden]"
        return
    fi
    if grep -qE "$pattern" <<<"$body"; then
        pass "$label"
    else
        bad "$label  [$file, Block »$blockstart« im Abschnitt /$start/../$end/ ~ /$pattern/]"
    fi
}

# Basisstand 3c80baa als Vergleichsdateien (Rev 8 §7.3.3 X7/X8).
tmp_base="$(mktemp)"
tmp_base_view="$(mktemp)"
trap 'rm -f "$tmp_base" "$tmp_base_view"' EXIT

# ---------------------------------------------------------------------------
# R1 — Turn-Rettung (§7.3.1, R7/R8/R9 in der Ersatzfassung des Erratums)
# ---------------------------------------------------------------------------
rescue_section() {
    echo "--- R1 Turn-Rettung (Rev 8 §7.3.1, Erratum §4.3) ---"

    # R1: genau eine Deklaration, privat und nicht @Published.
    exactly "$vm" 'private var streamRequested' 1 "R1 genau 1 Deklaration private var streamRequested"
    exactly "$vm" '@Published.*streamRequested' 0 "R1a streamRequested ist nicht @Published"

    # R2: Flag vor dem Strom gesetzt.
    section_order "$vm" \
        'private func streamTurn(' 'private func adoptSessionID(' \
        'streamRequested = true' 'provider.stream(' \
        "R2 streamRequested = true steht vor provider.stream( in streamTurn"

    # R3: in send() zurueckgesetzt.
    section_exactly "$vm" 'func send()' 'func cancel()' \
        'streamRequested = false' 1 "R3 streamRequested = false genau 1x in send()"

    # R4: genau ein Aufrufort des Stroms in der ganzen Datei.
    exactly "$vm" 'provider\.stream\(' 1 "R4 provider.stream( genau 1x in der Datei"

    # R5: Deklaration + genau ein Aufruf.
    exactly "$vm" 'private func rescueEmptyTurn\(\) async -> Bool' 1 \
        "R5a rescueEmptyTurn deklariert"
    exactly "$vm" 'await rescueEmptyTurn\(\)' 1 "R5b rescueEmptyTurn genau 1x aufgerufen"

    # R6: der Rettungsrumpf benutzt genau einen merge und sonst keinen Weg.
    section_exactly "$vm" \
        'private func rescueEmptyTurn() async -> Bool' 'private func prepareSession' \
        'merge\(' 1 "R6a Rettung ruft merge genau 1x"
    section_exactly "$vm" \
        'private func rescueEmptyTurn() async -> Bool' 'private func prepareSession' \
        'provider\.stream|reloadHistory|openSession|Task\.sleep|Button\(|onTapGesture|for |while |repeat ' 0 \
        "R6b Rettung ohne zweiten Strom, ohne Neuladen, ohne Schleife"

    # R7 (Erratum §4.4): 4 gesamt; 2/1/1/0 in den vier Abschnitten.
    exactly "$vm" '\.emptyResponse' 4 "R7a .emptyResponse genau 4"
    section_exactly "$vm" 'private func isEmptyStream(' 'private func isTimeout(' \
        '\.emptyResponse' 2 "R7b davon 2 in isEmptyStream"
    section_exactly "$vm" \
        'private func rescueEmptyTurn() async -> Bool' 'private func prepareSession' \
        '\.emptyResponse' 1 "R7c davon 1 in rescueEmptyTurn (F8-Text)"
    section_exactly "$vm" 'private static func isCreateFailure(' 'private func streamTurn(' \
        '\.emptyResponse' 1 "R7d davon 1 in isCreateFailure (F10-Bestand)"
    section_exactly "$vm" 'private func handle(' 'private func rollbackUserEntry(' \
        '\.emptyResponse' 0 "R7e keine in handle"

    # R8 (Erratum §4.4): ein Setter-Aufruf, keine direkte Zuweisung, nur im
    # Misserfolgszweig.
    section_exactly "$vm" \
        'private func rescueEmptyTurn() async -> Bool' 'private func prepareSession' \
        '^[[:space:]]+offerHistoryReload\(\)$' 1 "R8a Rettung ruft den Setter genau 1x"
    section_exactly "$vm" \
        'private func rescueEmptyTurn() async -> Bool' 'private func prepareSession' \
        'offersHistoryReload = true' 0 "R8b keine direkte Zuweisung in der Rettung"
    section_order "$vm" \
        'private func rescueEmptyTurn() async -> Bool' 'private func prepareSession' \
        'return true' 'offerHistoryReload()' \
        "R8c Aufruf nur nach dem Erfolgs-Return"

    # R9 (Erratum §4.4): genau eine Zuweisung im Setter.
    # Nachtrag Runde 2 (MARAAA-188): statt zwei eigenstaendigen Aufrufen sind es
    # drei. Der dritte steht im Abbruch-Pfad `abandonDeadStreamIfNeeded` (E1):
    # nach einem abgerissenen Turn muss „Verlauf neu laden“ sichtbar bleiben.
    # `reloadHistory()` bietet den Weg zusaetzlich inline nach einem erneuten
    # Fehlschlag an (E6, R9f). Die Zusage („jeder Aufruf ist ein benannter
    # Weg“) bleibt und wird unten einzeln gehalten: R9d = O3-Zweig,
    # R9e = Rettung, R9f = reloadHistory.
    exactly "$vm" 'offersHistoryReload = true' 1 "R9a genau 1 Zuweisung"
    section_exactly "$vm" 'private func offerHistoryReload()' 'func reloadHistory()' \
        'offersHistoryReload = true' 1 "R9b die Zuweisung steht im Setter"
    exactly "$vm" '^[[:space:]]+offerHistoryReload\(\)$' 3 "R9c genau 3 eigenstaendige Aufrufe"
    section_exactly "$vm" 'private func handle(' 'private func rollbackUserEntry(' \
        '^[[:space:]]+offerHistoryReload\(\)$' 1 "R9d einer ist der O3-Zweig"
    section_exactly "$vm" \
        'private func rescueEmptyTurn() async -> Bool' 'private func prepareSession' \
        '^[[:space:]]+offerHistoryReload\(\)$' 1 "R9e einer ist die Rettung"
    # E6 (Rev 9, MARAAA-188): der vierte Aufruf steht inline in
    # `reloadHistory()` — er hält den Wiederholweg nach einem erneuten
    # Fehlschlag offen (scheitert das Nachladen, bleibt `historyLoaded` false).
    section_has "$vm" \
        'func reloadHistory()' 'func loadSessions()' \
        'if !historyLoaded, currentSession != nil \{ offerHistoryReload\(\) \}' \
        "R9f reloadHistory bietet den Weg nach erneutem Fehlschlag an"

    # R10: kein Rollback des optimistischen Eintrags.
    section_exactly "$vm" \
        'private func rescueEmptyTurn() async -> Bool' 'private func prepareSession' \
        'rollbackUserEntry' 0 "R10 Rettung rollt den User-Eintrag nicht zurueck"

    # R11: Rollback-Aufrufe unveraendert (1 Deklaration + 3 Aufrufe).
    exactly "$vm" 'rollbackUserEntry\(text:' 4 "R11 rollbackUserEntry(text: genau 4x"

    # R12: O3-Timeout unveraendert und im handle-Zweig.
    section_exactly "$vm" 'private func handle(' 'private func rollbackUserEntry(' \
        'Seit \\\(Int\(configuration\.streamIdleTimeout\)\) s keine Antwort' 1 \
        "R12 O3-Meldung genau 1x in handle"

    # R13: F12 vor F8 im Provider.
    section_order "$prov" 'func consumeEventStream' 'func emit(' \
        'finishReason == "error"' 'guard sawContent' \
        "R13 F12-Zweig steht vor der Leer-Pruefung"

    # R14: Rettung vor handle im catch von run.
    section_order "$vm" 'private func run(text: String, generation: Int) async' 'private func rescueEmptyTurn' \
        'rescueEmptyTurn()' 'handle(error, text: text)' \
        "R14 rescueEmptyTurn() steht vor handle(error, text: text)"

    # R15: kein neuer Knopf; der eine Knopf steht in der noticeBar.
    exactly "$view" 'Button\("Verlauf neu laden"\)' 1 \
        "R15a Button \"Verlauf neu laden\" genau 1x"
    section_exactly "$view" 'private func noticeBar(' 'private var transcript' \
        'Button\("Verlauf neu laden"\)' 1 \
        "R15b der Knopf steht in noticeBar"

    # R16: Merge-Ergebnis traegt die Zahl der neuen Agent-Eintraege.
    need "$vm" 'merged\(agentEntries' "R16a MergeOutcome.merged(agentEntries:)"
    section_has "$vm" \
        'private func rescueEmptyTurn() async -> Bool' 'private func prepareSession' \
        'agentEntries > 0' "R16b Erfolg haengt an agentEntries > 0"

    # R17: genau eine Meldung im Rettungsrumpf, und zwar der F8-Text.
    section_exactly "$vm" \
        'private func rescueEmptyTurn() async -> Bool' 'private func prepareSession' \
        'notice =' 1 "R17a genau 1 notice im Rettungsrumpf"
    section_has "$vm" \
        'private func rescueEmptyTurn() async -> Bool' 'private func prepareSession' \
        'notice = displayText\(for: ChatStreamError\.emptyResponse\)' \
        "R17b die Meldung ist der F8-Text"

    # R18 (Nachtrag zu §7.4 M11): B2 verlangt, dass NUR der leere Strom die
    # Rettung ausloest. R7 zaehlt die `.emptyResponse`-Vorkommen und R12 den
    # O3-Text; keine der beiden Zeilen sieht den Rumpf von `isEmptyStream` an.
    # Ohne diese Zeile bliebe M11 (Timeout als leerer Strom) unbemerkt —
    # genau das Risiko R1 aus §8. Geprueft wird der Rumpf (nicht der Abschnitt),
    # weil die Abschnittsgrenze `private func isTimeout(` selbst das Wort
    # `isTimeout` traegt.
    block_lacks "$vm" 'private func isEmptyStream(' \
        'isTimeout|\.timeout|timedOut|URLError' \
        "R18 isEmptyStream erkennt keinen Timeout als leeren Strom (M11)"

    # R19 (R-CH5, Minor aus G-CH8): der Abbruch waehrend des Rettungs-`GET`
    # darf den F8-Text nicht ueberschreiben. Der Rettungsrumpf traegt deshalb
    # genau zwei `Task.isCancelled`-Pruefungen (Eintritt + Recheck), der
    # Recheck steht nach `await merge(` und der F8-Zweig dahinter.
    section_exactly "$vm" \
        'private func rescueEmptyTurn() async -> Bool' 'private func prepareSession' \
        'Task\.isCancelled' 2 "R19a genau 2 Task.isCancelled im Rettungsrumpf"
    section_order "$vm" \
        'private func rescueEmptyTurn() async -> Bool' 'private func prepareSession' \
        'await merge(' 'guard !Task.isCancelled' \
        "R19b Recheck steht nach await merge("
    section_order "$vm" \
        'private func rescueEmptyTurn() async -> Bool' 'private func prepareSession' \
        'guard !Task.isCancelled' \
        'notice = displayText(for: ChatStreamError.emptyResponse)' \
        "R19c F8-Zweig liegt hinter dem Recheck"

    # R20 (R-CH5, N1/N2): beide Turn-Felder fallen im `defer` von `run`
    # zurueck — nicht irgendwo im Rumpf, sondern im defer-Block selbst.
    section_block_has "$vm" \
        'private func run(text: String, generation: Int) async' 'private func rescueEmptyTurn' \
        'defer {' '^[[:space:]]+streamRequested = false$' \
        "R20a defer setzt streamRequested zurueck"
    section_block_has "$vm" \
        'private func run(text: String, generation: Int) async' 'private func rescueEmptyTurn' \
        'defer {' '^[[:space:]]+mergeFallbackDuration = nil$' \
        "R20b defer setzt mergeFallbackDuration zurueck"
}

# ---------------------------------------------------------------------------
# R2 — Generierungsdauer (§7.3.2, D7/D9 in der Ersatzfassung des Erratums)
# ---------------------------------------------------------------------------
duration_section() {
    echo "--- R2 Generierungsdauer (Rev 8 §7.3.2, Erratum §4.3) ---"

    # D1: das Feld am Eintrag.
    section_exactly "$vm" 'struct Entry: Identifiable, Equatable {' \
        '@Published private(set) var sessions' \
        'var generationDuration: TimeInterval\?' 1 \
        "D1 generationDuration genau 1x in struct Entry"

    # D2/D3: reine Berechnung aus der ganzen Seite, sortiert nach id.
    exactly "$vm" \
        'static func generationDurations\(in messages: \[ChatMessage\]\) -> \[Int: TimeInterval\]' 1 \
        "D2 generationDurations genau 1 Deklaration"
    section_order "$vm" \
        'static func generationDurations(in messages: [ChatMessage]) -> [Int: TimeInterval]' \
        'func durationText(for entry:' \
        '.sorted' 'timestamp' "D3 sortiert vor der Zeitstempel-Auswertung"
    section_has "$vm" \
        'static func generationDurations(in messages: [ChatMessage]) -> [Int: TimeInterval]' \
        'func durationText(for entry:' \
        'timestamp' "D3b generationDurations liest timestamp"

    # D4/D5/D6: Anzeige und reiner Formatierer.
    exactly "$vm" 'func durationText\(for entry: Entry\) -> String\?' 1 \
        "D4 durationText(for:) genau 1 Deklaration"
    section_exactly "$vm" 'static func durationText(seconds:' 'private func handle(' \
        'floor\(' 1 "D5a floor( genau 1x im Formatierer"
    section_lacks "$vm" 'static func durationText(seconds:' 'private func handle(' \
        'rounded\(' "D5b kein rounded( im Formatierer"
    section_has "$vm" 'static func durationText(seconds:' 'private func handle(' \
        'if total < 60' "D6a Minuten-Grenze 60"
    section_has "$vm" 'static func durationText(seconds:' 'private func handle(' \
        'total / 60' "D6b Minuten-Quotient"
    section_has "$vm" 'static func durationText(seconds:' 'private func handle(' \
        'total % 60' "D6c Minuten-Rest"
    section_has "$vm" 'static func durationText(seconds:' 'private func handle(' \
        '3_600' "D6d Stundengrenze 3600"
    section_lacks "$vm" 'static func durationText(seconds:' 'private func handle(' \
        'Locale|DateFormatter' "D6e keine Locale-/Formatter-Abhaengigkeit"

    # D7 (Erratum §4.4): Index-Rueckgabe, Dauer setzt merge.
    exactly "$vm" 'private func applyMergedAssistant\(_ message: ChatMessage\) -> Int\?' 1 \
        "D7a Deklaration ohne duration:"
    section_exactly "$vm" 'private func merge(' 'private func applyMergedUser' \
        'if let index = applyMergedAssistant\(message\)' 1 \
        "D7b merge bindet den Index"
    section_exactly "$vm" 'private func merge(' 'private func applyMergedUser' \
        'entries\[index\]\.generationDuration = durations\[message\.id\] \?\? fallbackDuration' 1 \
        "D7c merge setzt Rang 1 / Rang 2"
    exactly "$vm" 'applyMergedAssistant\(message, duration:' 0 \
        "D7d kein duration:-Aufruf"

    # D8: map setzt die Dauer, aber keinen Fallback.
    section_at_least "$vm" 'static func map(messages:' 'private static func reasoning(' \
        'generationDuration:' 1 "D8a map setzt generationDuration"
    section_lacks "$vm" 'static func map(messages:' 'private static func reasoning(' \
        'fallbackDuration' "D8b map erfindet keinen Fallback"

    # D9 (Erratum §4.4): Signatur ohne Parameter, Fallback aus dem Turn-Feld.
    exactly "$vm" 'private func merge\(sessionID: String\) async -> MergeOutcome' 1 \
        "D9a Signatur ohne Parameter"
    section_exactly "$vm" 'private func merge(' 'private func applyMergedUser' \
        'let fallbackDuration = mergeFallbackDuration' 1 "D9b Fallback aus dem Turn-Feld"
    exactly "$vm" 'merge\(sessionID:' 3 "D9c 1 Deklaration + 2 Aufrufer"
    exactly "$vm" 'merge\(sessionID: [^)]*fallbackDuration' 0 \
        "D9d kein fallbackDuration:-Parameter"

    # D10: Rang 1 aus der ganzen Seite, nicht aus `fresh`.
    exactly "$vm" 'generationDurations\(in: page\.messages\)' 1 \
        "D10 generationDurations(in: page.messages) genau 1x"

    # D11/D12: lokale Messung, genau eine Uhr-Lesestelle.
    exactly "$vm" 'private func measuredTurnDuration\(\)' 1 \
        "D11a measuredTurnDuration deklariert"
    exactly "$vm" '= measuredTurnDuration\(\)' 2 "D11b genau 2 Aufrufe"
    exactly "$vm" 'Date\(\)\.timeIntervalSince\(' 1 \
        "D12 Date().timeIntervalSince( genau 1x in der Datei"

    # D13/D14: die zwei Stellschrauben in der Konfiguration.
    exactly "$cfg" 'minVisibleGenerationDuration' 1 \
        "D13a minVisibleGenerationDuration genau 1x in der Konfiguration"
    exactly "$cfg" 'var minVisibleGenerationDuration: TimeInterval = 1' 1 \
        "D13b Wert 1"
    exactly "$cfg" 'maxVisibleGenerationDuration' 1 \
        "D14a maxVisibleGenerationDuration genau 1x in der Konfiguration"
    exactly "$cfg" 'var maxVisibleGenerationDuration: TimeInterval = 86_400' 1 \
        "D14b Wert 86_400"

    # D15/D18: die View liest den fertigen Text, formatiert nicht.
    exactly "$view" 'viewModel\.durationText\(for: entry\)' 1 \
        "D15a viewModel.durationText(for: entry) genau 1x"
    section_order "$view" 'private func row(for entry:' 'private func approvalCard(for entry:' \
        'MessageBubbleView(role: .agent' 'durationText(for: entry)' \
        "D15b Dauerzeile steht nach der Antwort-Bubble"
    section_has "$view" 'private func row(for entry:' 'private func approvalCard(for entry:' \
        'accessibilityLabel\(Text\(duration\)\)' \
        "D18 die Dauerzeile traegt accessibilityLabel(Text(duration))"
    section_lacks "$view" 'private func row(for entry:' 'private func approvalCard(for entry:' \
        'accessibilityLabel\(Text\(".*duration' \
        "D18b kein zusaetzliches Literal an der Dauerzeile"

    # D16: keine Formatierung, keine Schwelle, keine Einheit in der View.
    exactly "$view" 'String\(format:' 0 "D16a kein String(format: in ChatView"
    exactly "$view" '" s"' 0 "D16b keine Einheit \" s\" in ChatView"
    exactly "$view" '" min ' 0 "D16c keine Einheit \" min \" in ChatView"
    exactly "$view" '3_600' 0 "D16d kein 3_600 in ChatView"
    exactly "$view" '86_400' 0 "D16e kein 86_400 in ChatView"
    exactly "$view" 'floor\(' 0 "D16f kein floor( in ChatView"
    exactly "$view" 'minVisible' 0 "D16g keine Schwelle in ChatView"

    # D17: die Dauerzeile ist keine zweite Statuszeile.
    section_lacks "$view" 'private var statusText: String' 'private var phaseBar' \
        'durationText' "D17a kein durationText in statusText"
    section_lacks "$view" 'private var phaseBar' 'private func noticeBar(' \
        'durationText' "D17b kein durationText in phaseBar"
    section_lacks "$view" 'private func noticeBar(' 'private var transcript' \
        'durationText' "D17c kein durationText in noticeBar"

    # D19/D20: lokale Messung am Live-Eintrag, vor dem Merge.
    exactly "$vm" 'private func attachLiveDuration\(' 1 \
        "D19a attachLiveDuration deklariert"
    section_exactly "$vm" \
        'private func streamTurn(' 'private func adoptSessionID(' \
        'attachLiveDuration\(measured\)' 1 "D19b genau 1 Aufruf in streamTurn"
    section_order "$vm" \
        'private func streamTurn(' 'private func adoptSessionID(' \
        'attachLiveDuration' 'merge(sessionID:' \
        "D19c attachLiveDuration steht vor merge(sessionID:"
    block_has "$vm" 'private func attachLiveDuration(' 'turnEntryIDs' \
        "D20a nur Eintraege dieses Turns"
    block_has "$vm" 'private func attachLiveDuration(' '\.agent' \
        "D20b nur Agent-Eintraege"
    block_has "$vm" 'private func attachLiveDuration(' 'text\.isEmpty' \
        "D20c nur Eintraege mit Text"
    block_has "$vm" 'private func attachLiveDuration(' 'generationDuration == nil' \
        "D20d nur ohne vorhandenen Wert"

    # D21: keine Dauer an Werkzeugkarten, Denken-Klappe oder Freigabe.
    section_order "$view" 'private func row(for entry:' 'private func approvalCard(for entry:' \
        'durationText(for: entry)' 'if let engine = entry.engine' \
        "D21a Dauerzeile steht im Textblock vor der Engine-Zeile"
    section_lacks "$view" 'private func approvalCard(for entry:' 'private var emptyState' \
        'durationText' "D21b keine Dauer in der Freigabekarte"
}

# ---------------------------------------------------------------------------
# Grenzen, Unveraendertheit (§7.3.3, X1–X8)
# ---------------------------------------------------------------------------
global_section() {
    echo "--- Grenzen und Unveraendertheit (Rev 8 §7.3.3) ---"

    local base_commit="3c80baa"
    # X1/X2 sagen etwas ueber den CH4-Commit, nicht ueber den jeweils letzten
    # Commit: der Anker ist fest, damit ein Folgecommit auf `main` die Zeilen
    # nicht umdreht (MARAAA-186).
    local ch4_commit="ac109f0"
    local ch4_range="${base_commit}..${ch4_commit}"
    local ch4_anchor=0
    local head_commit
    head_commit="$(git rev-parse --short=7 HEAD 2>/dev/null || true)"

    if ! git rev-parse --verify -q "${base_commit}^{commit}" >/dev/null 2>&1; then
        bad "X-Git Basisstand $base_commit nicht auffindbar — X1/X2/X5–X8 nicht pruefbar"
        return
    fi
    if git rev-parse --verify -q "${ch4_commit}^{commit}" >/dev/null 2>&1; then
        ch4_anchor=1
    else
        bad "X-Git CH4-Anker $ch4_commit nicht auffindbar — X1/X2 nicht pruefbar"
    fi
    git show "${base_commit}:${vm}" >"$tmp_base"
    git show "${base_commit}:${view}" >"$tmp_base_view"

    if [[ "$ch4_anchor" -eq 1 ]]; then
        # X1: der CH4-Commit aendert keine Testdatei.
        if [[ -z "$(git diff --stat "$ch4_range" -- Tests 2>/dev/null || true)" ]]; then
            pass "X1 CH4-Commit aendert Tests/** nicht"
        else
            bad "X1 CH4-Commit aendert Tests/**: $(git diff --stat "$ch4_range" -- Tests | tr '\n' ' ')"
        fi

        # X2: genau die drei Dateien aus §2.3.
        local changed expected
        changed="$(git diff --name-only "$ch4_range" 2>/dev/null | sort || true)"
        expected="$(printf '%s\n' \
            'Planer/Features/Chat/ChatConfiguration.swift' \
            'Planer/Features/Chat/ChatView.swift' \
            'Planer/Features/Chat/ChatViewModel.swift' | sort)"
        if [[ "$changed" == "$expected" ]]; then
            pass "X2 geaendert sind genau die drei Dateien aus §2.3"
        else
            bad "X2 geaenderte Dateien weichen ab: $(echo "$changed" | tr '\n' ' ')"
        fi
    fi

    # X3: das ViewModel bleibt HTTP-frei.
    exactly "$vm" 'URLSession|NetworkClient|httpMethod' 0 \
        "X3 ChatViewModel ohne URLSession/NetworkClient/httpMethod"

    # X4: das F8-Literal steht genau einmal im Baum, im Provider.
    local hits total
    hits="$(grep -rInF 'Der Server hat keine Antwort geliefert.' Planer/ --include='*.swift' 2>/dev/null || true)"
    total="$(grep -c . <<<"$hits" 2>/dev/null || true)"
    total="${total:-0}"
    if [[ "$total" -eq 1 ]] && grep -qF "$prov:" <<<"$hits"; then
        pass "X4 F8-Literal genau 1x im Baum, in $prov"
    else
        bad "X4 F8-Literal: Treffer $total, erwartet 1 in $prov  [$(head -1 <<<"$hits")]"
    fi

    # X5: Provider, SSE und DTOs im CH4-Commit unveraendert.
    # HISTORISCH (V6, nur fuer den CH4-Commit ac109f0): die Aussage „Rev 8 hat
    # diese drei Dateien nicht angefasst“ gilt fuer den CH4-Commit, nicht fuer
    # jeden spaeteren Commit auf main (MARAAA-186). Rev 9 (MARAAA-188) aendert
    # Provider und SSE bewusst (ein zu grosses SSE-Ereignis wird verworfen
    # statt zum Turn-Fehler); ein Vergleich gegen HEAD wuerde die alte Zusage
    # mit der neuen Arbeit umdrehen, statt sie zu pruefen.
    # Diese Zeile ist daher **keine lebende Grenze** fuer HEAD; die lebende
    # Grenze der DTOs ist X5b. Sie bleibt als datierter Nachweis des damaligen
    # Stands stehen.
    # Nachtrag Runde 2 (Befund 5): der Anker wird **vor** dem Vergleich
    # validiert. Fehlt er, ist X5 rot — ein `git diff` mit unaufloesbarem
    # Bereich liefert leer und waere sonst vakuum-gruen.
    if [[ "$ch4_anchor" -eq 0 ]]; then
        bad "X5a (historisch) CH4-Anker $ch4_commit nicht auffindbar — Unveraendertheit nicht pruefbar"
    elif [[ -z "$(git diff --stat "$ch4_range" -- "$prov" "$sse" "$dtos" 2>/dev/null || true)" ]]; then
        pass "X5a (historisch, CH4-Bereich) ChatStreamProvider/ChatSSE/ChatDTOs unveraendert"
    else
        bad "X5a (historisch) unerlaubte Aenderung an Provider/SSE/DTOs: $(git diff --name-only "$ch4_range" -- "$prov" "$sse" "$dtos" | tr '\n' ' ')"
    fi

    # X5b (Runde 2): die DTO-Vertraege zusaetzlich gegen HEAD. Der feste
    # CH4-Bereich allein sagt nichts ueber die Arbeit **nach** CH4; der
    # Wire-Vertrag (`ChatDTOs`) darf auch dort nicht wandern.
    if [[ -z "$(git diff --stat "${base_commit}..HEAD" -- "$dtos" 2>/dev/null || true)" ]]; then
        pass "X5b ChatDTOs unveraendert gegen HEAD"
    else
        bad "X5b ChatDTOs gegen HEAD geaendert: $(git diff --name-only "${base_commit}..HEAD" -- "$dtos" | tr '\n' ' ')"
    fi

    # X6: Design-Tokens unveraendert.
    if [[ -z "$(git diff --stat "${base_commit}..HEAD" -- 'Config/DesignTokens.json' 'Planer/DesignSystem/DesignTokens.swift' 2>/dev/null || true)" ]]; then
        pass "X6 DesignTokens.json und DesignTokens.swift unveraendert"
    else
        bad "X6 Design-Tokens geaendert"
    fi

    # X7: die drei Bestandsfunktionen behalten ihren Rumpf.
    local fn
    for fn in 'func cancel()' 'func openSession(' 'func loadOlderMessages()'; do
        if diff -q \
            <(brace_block "$tmp_base" "$fn") \
            <(brace_block "$vm" "$fn") >/dev/null 2>&1; then
            pass "X7 Rumpf unveraendert: $fn"
        else
            bad "X7 Rumpf geaendert: $fn"
        fi
    done

    # X7b (Runde 2, MARAAA-188/E6): `reloadHistory()` ist die eine bewusst
    # geaenderte Bestandsfunktion — bei erneutem Fehlschlag setzt sie wieder
    # `offersHistoryReload`. Geprueft wird dieselbe Zusage wie in X7 („kein
    # versehentlicher Umbau“) in der Form, die die Aenderung zulaesst: keine
    # Zeile des Bestandsrumpfs entfernt oder geaendert, und genau **eine**
    # neue Codezeile, die das Angebot setzt (Kommentarzeilen zaehlen nicht).
    local rh_removed rh_added rh_added_count
    rh_removed="$(diff \
        <(brace_block "$tmp_base" 'func reloadHistory()') \
        <(brace_block "$vm" 'func reloadHistory()') | grep -c '^<' || true)"
    rh_added="$(diff \
        <(brace_block "$tmp_base" 'func reloadHistory()') \
        <(brace_block "$vm" 'func reloadHistory()') \
        | grep '^>' | sed 's/^> //' | grep -vE '^[[:space:]]*(//.*)?$' || true)"
    rh_added_count="$(grep -c . <<<"$rh_added" || true)"
    if [[ "${rh_removed:-0}" -eq 0 && "${rh_added_count:-0}" -eq 1 ]] \
        && grep -qF 'offerHistoryReload()' <<<"$rh_added"; then
        pass "X7b reloadHistory(): Bestandsrumpf unangetastet, nur das E6-Angebot ergaenzt"
    else
        bad "X7b reloadHistory() weicht ab: entfernt=${rh_removed:-?}, neue Codezeilen=${rh_added_count:-?}, erwartet 0/1  [$(head -3 <<<"$rh_added")]"
    fi

    # X8: keine neuen Bedienelemente/Zustaende/Timer in der View.
    local sym a b
    for sym in 'Button' '@State' 'TimelineView'; do
        a="$(count_matches "$tmp_base_view" "$sym")"
        b="$(count_matches "$view" "$sym")"
        if [[ "$a" -eq "$b" ]]; then
            pass "X8 $sym unveraendert ($b)"
        else
            bad "X8 $sym geaendert: $a -> $b"
        fi
    done
    section_has "$view" 'private func approvalCard(for entry:' 'private var emptyState' \
        'TimelineView' "X8b TimelineView steht nur in approvalCard"

    echo "HEAD: ${head_commit}"
}

# ---------------------------------------------------------------------------

[[ "$mode" == "rescue" || "$mode" == "all" ]] && rescue_section
[[ "$mode" == "duration" || "$mode" == "all" ]] && duration_section
[[ "$mode" == "all" ]] && global_section

if [[ "$fail" -ne 0 ]]; then
    echo "Ergebnis: FEHLGESCHLAGEN (chat-rev8)"
    exit 1
fi
echo "Ergebnis: OK (chat-rev8)"
exit 0
