#!/usr/bin/env bash
#
# Statische Abnahme der Rev-9-Leistungen des Chat-Tabs (MARAAA-188):
#
#   S1–S17  Ein SSE-Ereignis über dem Größenlimit bricht den Turn nicht ab;
#           das Limit ist genau ein benannter Wert (Auftrag A3/A4). S16/S17
#           sichern den `id:`-Vertrag: ein leerer Wert setzt die letzte ID
#           zurück (Nachtrag Runde 2, Befund 7).
#   N1–N10  Der Hintergrund-Hinweis ist ein Hinweis, kein Fehler — die
#           Unterscheidung ist expliziter Zustand, kein Textvergleich (A5).
#
# Mutationsprobe (Nachtrag Runde 2): Jede hier neue Prüfung ist gegen den
# Ist-Stand `main` rot belegt — dort fehlen `maxStreamEventCharacters` und der
# Decoder-Verwurf (S1–S17), und `noticeIsInformational` existiert nicht (N1–N10).
# Beleg: `git worktree add /tmp/probe main`, dieses Skript dorthin kopieren,
# `bash Tests/verify_chat_rev9.sh all` → Exit 1 mit den S-/N-Zeilen als FAIL.
# Der Lauf steht im Bericht zu MARAAA-188 (Runde 2) und in der Commit-Nachricht.
#
# Rein statisch: grep/awk/Dateiprüfungen, keine Swift-Toolchain, kein Netz,
# kein Aufruf anderer Tests.
#
#   bash Tests/verify_chat_rev9.sh [sse|notice|all]      # Default: all
#
# Exit 0 = alle Prüfungen des gewählten Abschnitts grün
# Exit 1 = mindestens eine rot
# Exit 2 = falscher Aufruf
# Letzte Zeile bei Erfolg: Ergebnis: OK (chat-rev9)
# Letzte Zeile bei Fehler: Ergebnis: FEHLGESCHLAGEN (chat-rev9)
#
set -euo pipefail

case "${1:-all}" in
    sse|notice|all) mode="${1:-all}" ;;
    *)
        echo "Aufruf: bash Tests/verify_chat_rev9.sh [sse|notice|all]" >&2
        exit 2
        ;;
esac
if [[ $# -gt 1 ]]; then
    echo "Aufruf: bash Tests/verify_chat_rev9.sh [sse|notice|all]" >&2
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

fail=0

pass() { echo "ok:   $1"; }
bad()  { echo "FAIL: $1"; fail=1; }

need() { if grep -qE "$2" "$1"; then pass "$3"; else bad "$3  [$1 ~ /$2/]"; fi; }
need_fixed() { if grep -qF "$2" "$1"; then pass "$3"; else bad "$3  [$1 = $2]"; fi; }
ban() { if grep -qE "$2" "$1"; then bad "$3  [$1 ~ /$2/]"; else pass "$3"; fi; }

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

# Abschnitt einer Datei: von der Zeile, die $2 enthält, bis zur ersten Zeile,
# die $3 enthält (beide Grenzen eingeschlossen). Grenzen sind **wörtlich** und
# werden mit index() verglichen — ein Regex würde bei jedem `\(` in awk
# warnen und die Grenze unschärfer machen.
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

# Reihenfolge zweier wörtlicher Marken **innerhalb** eines Abschnitts: grün
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

# Rumpf ab der Zeile mit $2 bis zur schließenden Klammer derselben
# Verschachtelungstiefe (`{`/`}` je Zeile gezählt).
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

# ---------------------------------------------------------------------------
# (a) SSE-Größenlimit — A3/A4
# ---------------------------------------------------------------------------
sse_section() {
    echo "--- (a) SSE: ein zu großes Ereignis wird verworfen, nicht zum Fehler"

    # A4: genau EIN benannter Wert. Der Zähler läuft über den ganzen Baum:
    # eine zweite Magic Number in Decoder oder Provider wäre rot.
    need_fixed "$cfg" 'var maxStreamEventCharacters = 262_144' \
        "S1  das Limit ist ein benannter Konfigurationswert"
    local hits
    hits="$(grep -rInF '262_144' Planer/ --include='*.swift' 2>/dev/null || true)"
    if [[ "$(grep -c . <<<"$hits" || true)" -eq 1 ]] && grep -qF "$cfg:" <<<"$hits"; then
        pass "S2  262_144 steht genau einmal im Baum, in $cfg"
    else
        bad "S2  262_144: $(grep -c . <<<"$hits" || true) Treffer, erwartet 1 in $cfg  [$(head -1 <<<"$hits")]"
    fi
    need_fixed "$sse" 'init(maxCharacters: Int = HermesChatConfiguration().maxStreamEventCharacters)' \
        "S3  der Decoder liest den benannten Wert als Default"
    need_fixed "$prov" 'ServerSentEventDecoder(maxCharacters: configuration.maxStreamEventCharacters)' \
        "S4  der Provider übergibt den konfigurierten Wert"
    ban "$sse" 'Größenlimit' \
        "S5  der alte Fehlertext ist aus dem Decoder verschwunden"

    # A3: das Ereignis wird verworfen; der Decoder wirft dafür nicht mehr.
    block_lacks "$sse" 'mutating func consume(line: String)' 'throw ' \
        "S6  consume wirft bei zu großem Ereignis nicht mehr"
    block_has "$sse" 'mutating func consume(line: String)' 'discardsCurrentEvent = true' \
        "S7  das zu große Ereignis wird als „verwerfen“ markiert"
    block_has "$sse" 'mutating func consume(line: String)' \
        'dataLines\.removeAll\(keepingCapacity: false\)' \
        "S8  der Puffer wird beim Verwerfen freigegeben (bounded)"
    block_has "$sse" 'mutating func consume(line: String)' \
        'guard !discardsCurrentEvent else \{ return nil \}' \
        "S9  nach dem Überschreiten wird keine weitere data-Zeile gepuffert"
    section_order "$sse" 'mutating func consume' 'case "event"' \
        'guard !discardsCurrentEvent' 'ServerSentEvent\(' \
        "S10 das verworfene Ereignis wird nie gebaut (kein halbes Ergebnis)"
    need_fixed "$sse" 'self.maxCharacters = max(1_024, maxCharacters)' \
        "S11 die Untergrenze des Limits bleibt erhalten"

    # Der Strom läuft weiter: `nil` heißt „nächstes Ereignis“, nicht „Ende“.
    need_fixed "$prov" 'guard let event = decoder.consume(line: line) else { continue }' \
        "S12 der Provider setzt nach einem verworfenen Ereignis fort"
    ban "$prov" 'try decoder\.consume' \
        "S13 der Provider behandelt consume nicht mehr als Wurfstelle"

    # A3, zweite Hälfte: kommt gar kein Inhalt an, bleibt es der Leer-Fehler.
    need "$prov" 'guard sawContent else \{' \
        "S14 die Leer-Prüfung bleibt bestehen"
    need_fixed "$prov" 'throw ChatStreamError.emptyResponse' \
        "S15 ohne Inhalt bleibt es bei emptyResponse (kein stiller Erfolg)"

    # E6b (Nachtrag Runde 2): `id:` mit leerem Wert ist eine Zuweisung, kein
    # „nichts“ — der SSE-Vertrag setzt die zuletzt gesehene ID dann auf "".
    # Der Abschnitt ist die `id`-Verzweigung bis zum `default:` desselben
    # `switch`; ein Riegel gegen den leeren Wert wäre dort sichtbar.
    section_has "$sse" 'case "id":' 'default:' 'lastIdentifier = value' \
        "S16 ein id-Feld übernimmt seinen Wert auch leer (SSE-Vertrag)"
    section_lacks "$sse" 'case "id":' 'default:' 'isEmpty|!value|guard' \
        "S17 kein Riegel gegen den leeren id-Wert (SSE-Vertrag)"
}

# ---------------------------------------------------------------------------
# (b) Hinweis statt Fehler — A5
# ---------------------------------------------------------------------------
notice_section() {
    echo "--- (b) Hinweis: eigener Zustand statt Textvergleich"

    need_fixed "$vm" 'static let backgroundResumeNotice = "Der Chat war im Hintergrund. Der Verlauf wurde vom Server neu geladen."' \
        "N1  der Hinweis bleibt wörtlich (A5)"
    need_fixed "$vm" '@Published private(set) var noticeIsInformational = false' \
        "N2  die Darstellung ist ein eigener, beobachtbarer Zustand"
    block_has "$vm" 'var notice: String?' 'noticeIsInformational = false' \
        "N3  jede neue Meldung fällt auf die Fehler-Optik zurück"
    section_has "$vm" 'func reconcileAfterBackground' 'private func beginBackgroundTaskIfNeeded' \
        'noticeIsInformational = true' \
        "N4  nur der Hintergrund-Hinweis setzt die Info-Optik"
    exactly "$vm" 'noticeIsInformational = true' 1 \
        "N5  genau eine Stelle setzt die Info-Optik"
    need_fixed "$view" 'viewModel.noticeIsInformational ? "info.circle" : "exclamationmark.triangle.fill"' \
        "N6  der Hinweis bekommt info.circle, der Fehler das Dreieck"
    need_fixed "$view" 'viewModel.noticeIsInformational ? DesignTokens.Palette.secondaryLabel : DesignTokens.Palette.danger' \
        "N7  der Hinweis nimmt die Label-Farbe, der Fehler danger"
    ban "$vm" 'notice == Self\.backgroundResumeNotice|notice == ChatViewModel\.backgroundResumeNotice' \
        "N8  die Unterscheidung ist kein Vergleich auf den Meldungstext"
    ban "$view" 'backgroundResumeNotice' \
        "N9  die View kennt den Wortlaut des Hinweises nicht"
    need_fixed "$view" '"exclamationmark.triangle.fill"' \
        "N10 echte Fehler behalten die Warn-Optik"
}

[[ "$mode" == "sse" || "$mode" == "all" ]] && sse_section
[[ "$mode" == "notice" || "$mode" == "all" ]] && notice_section

if [[ "$fail" -ne 0 ]]; then
    echo "Ergebnis: FEHLGESCHLAGEN (chat-rev9)"
    exit 1
fi
echo "Ergebnis: OK (chat-rev9)"
exit 0
