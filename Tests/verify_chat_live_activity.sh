#!/usr/bin/env bash
#
# Statische Abnahme der Live-Aktivitaet im Chat (MARAAA-204, W1-W4).
#
# Grundlage: `docs/spec-chat-live-activity.md` (MARAAA-203), §5.1 (Bausteine),
# §5.2 (Defaults) und §6.1 (Pruefungen L1-L17). Die Pruefungen sind woertlich
# aus §6.1 uebernommen.
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
section_has "$vm" 'private func streamTurn(' 'F15: Der Server' \
    'liveActivityTask\?\.cancel\(\)' 'L10a Abgleich endet mit dem Turn'
section_has "$vm" 'private func streamTurn(' 'F15: Der Server' \
    'case \.toolProgress' 'L10b Werkzeug-Frame ist die Startbedingung'
section_has "$vm" 'private func streamTurn(' 'F15: Der Server' \
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

# L16: die Karte behaelt ihre Form — sieben Parameter, keine neue Signatur.
card_params="$(section "$card" 'struct ToolCallCard: View {' 'var body:' \
    | count_matches '/dev/stdin' '^    let [A-Za-z]+: ')"
if [[ "$card_params" -eq 7 ]]; then
    pass "L16 ToolCallCard-Signatur unveraendert (7 Parameter)"
else
    bad "L16 ToolCallCard-Signatur geaendert ($card_params Parameter, erwartet: 7)"
fi

# ---------------------------------------------------------------------------

echo "HEAD: $(git rev-parse --short HEAD 2>/dev/null || echo unbekannt)"

if [[ "$fail" -ne 0 ]]; then
    echo "Ergebnis: FEHLGESCHLAGEN (chat-live-activity)"
    exit 1
fi
echo "Ergebnis: OK (chat-live-activity)"
exit 0
