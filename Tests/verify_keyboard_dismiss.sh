#!/usr/bin/env bash
#
# Statische Regression für MARAAA-137: Tastatur schließt beim Scrollen.
#
# Geprüft werden die drei Flächen aus dem Auftrag — ChatView, SessionListView
# und SettingsView. Für jede Datei wird der scrollbare Container gesucht
# (`ScrollView`, `List`, `Form`) und in dessen Modifikator-Kette
# `.scrollDismissesKeyboard(.interactively)` verlangt. Die Prüfung hängt am
# Container, nicht an der Datei: ein Modifikator an einer beliebigen anderen
# View zählt nicht. Auskommentierte Zeilen zählen nicht.
#
# `.immediately` ist hier für keine der drei Dateien zulässig — alle drei
# Flächen sind `ScrollView`, `List` oder `Form` und damit echte Scroll-Flächen.
#
#   bash Tests/verify_keyboard_dismiss.sh
#
# Exit-Status: 0 = alle Invarianten grün, 1 = mindestens eine rot.
#
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$root"

chat="Planer/Features/Chat/ChatView.swift"
sessions="Planer/Features/Chat/SessionListView.swift"
settings="Planer/Settings/SettingsView.swift"

fail=0

pass() { echo "ok:   $1"; }
bad()  { echo "FAIL: $1"; fail=1; }

# Zählt die Klammer-Bilanz einer Zeile: öffnende minus schließende `{`.
brace_delta() {
    local line="$1"
    local open close
    open="$(printf '%s' "$line" | tr -cd '{' | wc -c | tr -d ' ')"
    close="$(printf '%s' "$line" | tr -cd '}' | wc -c | tr -d ' ')"
    echo $(( open - close ))
}

# Prüft, ob `pattern` in der Modifikator-Kette des ersten Containers steht,
# der auf `container` passt. Die Kette beginnt mit der schließenden Klammer
# des Containers und endet bei der ersten Zeile, die kein `.modifier` mehr ist.
chain_has() {
    local file="$1" container="$2" pattern="$3"
    awk -v container="$container" -v pattern="$pattern" '
        function delta(s,   o, c) {
            o = gsub(/\{/, "{", s)
            c = gsub(/\}/, "}", s)
            return o - c
        }
        {
            line = $0
            is_comment = (line ~ /^[[:space:]]*\/\//)

            if (!started) {
                if (!is_comment && line ~ container) {
                    started = 1
                    depth = delta(line)
                }
                next
            }

            if (depth > 0) {
                depth += delta(line)
                if (depth < 0) depth = 0
                next
            }

            if (is_comment || line ~ /^[[:space:]]*$/) next

            if (line ~ /^[[:space:]]*\./) {
                if (index(line, pattern) > 0) found = 1
                depth = delta(line)
                if (depth < 0) depth = 0
                next
            }

            exit
        }
        END { exit(found ? 0 : 1) }
    ' "$file"
}

# Prüft eine Datei gegen ihren erwarteten Container.
check_view() {
    local file="$1" container="$2" display="$3" label="$4"

    if [[ ! -f "$file" ]]; then
        bad "$label: Datei fehlt ($file)"
        return
    fi

    if ! grep -qE "$container" "$file"; then
        bad "$label: kein scrollbarer Container ($display) gefunden"
        return
    fi

    if chain_has "$file" "$container" '.scrollDismissesKeyboard(.interactively)'; then
        pass "$label: $display trägt .scrollDismissesKeyboard(.interactively)"
    else
        bad "$label: $display trägt .scrollDismissesKeyboard(.interactively)"
    fi

    if grep -qE '\.scrollDismissesKeyboard\(\.immediately\)' "$file"; then
        bad "$label: .immediately ist für eine echte Scroll-Fläche nicht zulässig"
    else
        pass "$label: kein .immediately"
    fi

    if grep -qE '\.scrollDismissesKeyboard\(\.never\)' "$file"; then
        bad "$label: .never würde das Schließen beim Scrollen abschalten"
    else
        pass "$label: kein .never"
    fi
}

echo "--- ChatView: Verlauf"
check_view "$chat" '^[[:space:]]*ScrollView[[:space:]]*[{]' 'ScrollView' "ChatView"

echo "--- SessionListView: Verlaufs-Sheet"
check_view "$sessions" '^[[:space:]]*List[[:space:]]*[{]' 'List' "SessionListView"

echo "--- SettingsView: Einstellungs-Form"
check_view "$settings" '^[[:space:]]*Form[[:space:]]*[{]' 'Form' "SettingsView"

# ---------------------------------------------------------------------------
if [[ "$fail" -ne 0 ]]; then
    echo "Ergebnis: FEHLGESCHLAGEN"
    exit 1
fi
echo "Ergebnis: OK"
