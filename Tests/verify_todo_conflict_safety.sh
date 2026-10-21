#!/usr/bin/env bash
#
# Statischer Regressionstest für MARAAA-136 (D): Konfliktpfad der To-Dos
# absichern und die Tastatur beim Scrollen ausblenden.
#
# Warum statisch: Auf diesem Prüfstand gibt es keine Swift-Toolchain; die
# übrigen Abnahmen laufen ebenfalls über grep-/Fixture-Prüfungen. Der Test
# fixiert die Abnahme aus dem Auftrag:
#   1. `serverTask(id:)` unterscheidet „gefunden", „sicher nicht vorhanden"
#      (alle Status-Partitionen vollständig gelesen) und „unbekannt" (Limit
#      erreicht). Nur „sicher nicht vorhanden" darf lokal löschen.
#   2. `TodosViewModel` ruft `discardLocalChanges` nur auf ausdrückliche
#      Nutzerwahl auf, nicht in einem Fehler-catch.
#   3. `TodosView` und `TodoEditorSheet` dismissen die Tastatur beim Scrollen;
#      `onSubmit`/`submitLabel` bleiben unverändert.
#
#   bash Tests/verify_todo_conflict_safety.sh
#
# Exit-Status: 0 = alle Invarianten grün, 1 = mindestens eine rot.
#
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$root"

todos="Planer/Features/Todos"
repo="$todos/TodoRepository.swift"
model="$todos/TodosViewModel.swift"
view="$todos/TodosView.swift"
editor="$todos/TodoEditorSheet.swift"

fail=0

pass() { echo "ok:   $1"; }
bad()  { echo "FAIL: $1"; fail=1; }

require() {
    local description="$1" pattern="$2" file="$3"
    if grep -qE "$pattern" "$file"; then
        pass "$description"
    else
        bad "$description ($file ~ /$pattern/)"
    fi
}

forbid() {
    local description="$1" pattern="$2" file="$3"
    if grep -qE "$pattern" "$file"; then
        bad "$description ($file ~ /$pattern/)"
    else
        pass "$description"
    fi
}

require_body() {
    local description="$1" pattern="$2" body="$3"
    if grep -qE "$pattern" <<<"$body"; then
        pass "$description"
    else
        bad "$description"
    fi
}

forbid_body() {
    local description="$1" pattern="$2" body="$3"
    if grep -qE "$pattern" <<<"$body"; then
        bad "$description"
    else
        pass "$description"
    fi
}

count() { { grep -cE "$1" <<<"$2" || true; } | tr -d ' '; }

# Schneidet den Rumpf einer Funktion heraus: von der Signatur bis zur ersten
# Zeile, die nur aus vier Leerzeichen und einer schließenden Klammer besteht.
body_of() {
    local file="$1" signature="$2"
    sed -n "/$signature/,/^    }\$/p" "$file"
}

# Schneidet einen `case`-Zweig eines Switch heraus (Label bis zum nächsten
# `case` bzw. bis zur schließenden Klammer des Switch).
case_branch() {
    local file="$1" label="$2"
    awk -v label="$label" '
        $0 ~ "^[[:space:]]*case " label ":" { in_block = 1; next }
        in_block && $0 ~ "^[[:space:]]*case " { exit }
        in_block && $0 ~ "^[[:space:]]*\\}[[:space:]]*$" { exit }
        in_block { print }
    ' "$file"
}

# ---------------------------------------------------------------------------
echo "--- 1. serverTask(id:) unterscheidet drei Ausgänge"

require "ServerTaskLookup ist deklariert" \
    'enum ServerTaskLookup' "$repo"
require "Ausgang gefunden" \
    'case found\(TodoDTO\)' "$repo"
require "Ausgang sicher nicht vorhanden" \
    'case absent' "$repo"
require "Ausgang unbekannt" \
    'case unknown' "$repo"
require "serverTask liefert den dreiwertigen Ausgang" \
    'func serverTask\(id: String\) async throws -> ServerTaskLookup' "$repo"
forbid "serverTask liefert kein optionales TodoDTO mehr" \
    'func serverTask\(id: String\) async throws -> TodoDTO\?' "$repo"

lookup_body="$(body_of "$repo" 'func serverTask(id: String) async throws -> ServerTaskLookup {')"
require_body "serverTask liest beide Status-Partitionen" \
    'TodoStatus\.open\.rawValue, TodoStatus\.done\.rawValue' "$lookup_body"
require_body "serverTask liest mit dem Server-Maximum" \
    'requestTasks\(status: status, limit: TodoAPI\.maximumLimit\)' "$lookup_body"
require_body "serverTask erkennt eine gekappte Partition am Limit" \
    'if page\.count >= TodoAPI\.maximumLimit' "$lookup_body"
require_body "serverTask merkt sich die Unvollständigkeit" \
    'isComplete = false' "$lookup_body"
require_body "serverTask meldet den belegten Treffer" \
    'return \.found\(match\)' "$lookup_body"
require_body "serverTask meldet absent nur bei vollständiger Lektüre" \
    'return isComplete \? \.absent : \.unknown' "$lookup_body"
forbid_body "der Einzelabruf räumt den Cache nicht auf" \
    'prune: \.(all|status)' "$lookup_body"

# ---------------------------------------------------------------------------
echo "--- 2. Nur „sicher nicht vorhanden“ löscht lokal"

discard_body="$(body_of "$repo" 'func discardLocalChanges(id: String) async throws {')"
require_body "gefunden übernimmt den Serverstand" \
    'case \.found\(let server\)' "$discard_body"
require_body "gefunden schreibt den Serverstand in den Cache" \
    'Self\.apply\(server, to: item\)' "$discard_body"
require_body "sicher nicht vorhanden entfernt lokal" \
    'case \.absent:' "$discard_body"
require_body "unbekannt wird als eigener Zweig behandelt" \
    'case \.unknown:' "$discard_body"
require_body "unbekannt wirft einen Konflikt statt zu löschen" \
    'throw APIError\.conflict' "$discard_body"

remove_count="$(count 'try removeLocal\(id: id\)' "$discard_body")"
if [[ "$remove_count" -eq 1 ]]; then
    pass "discardLocalChanges entfernt genau einmal lokal"
else
    bad "discardLocalChanges entfernt genau einmal lokal ($remove_count)"
fi

if awk '
    /case \.absent:/          { absent = NR }
    /try removeLocal\(id: id\)/ { remove = NR }
    /case \.unknown:/         { unknown = NR }
    /throw APIError\.conflict/ { conflict = NR }
    END { exit (absent && remove && unknown && conflict \
                && absent < remove && remove < unknown && unknown < conflict ? 0 : 1) }
' <<<"$discard_body"; then
    pass "removeLocal steht ausschließlich im absent-Zweig"
else
    bad "removeLocal steht ausschließlich im absent-Zweig"
fi

absent_branch="$(case_branch "$repo" '.absent')"
unknown_branch="$(case_branch "$repo" '.unknown')"
require_body "absent entfernt den Eintrag" \
    'try removeLocal\(id: id\)' "$absent_branch"
forbid_body "unbekannt entfernt den Eintrag nicht" \
    'removeLocal|context\.delete' "$unknown_branch"
require_body "unbekannt lässt den Eintrag ausdrücklich stehen" \
    'Der lokale Eintrag bleibt erhalten' "$unknown_branch"

forbid "forceLocal rät keine Server-Version mehr" \
    'server\?\.version' "$repo"
force_body="$(body_of "$repo" 'func forceLocal(id: String) async throws -> TodoDTO {')"
require_body "forceLocal behandelt gefunden" \
    'case \.found\(let server\)' "$force_body"
require_body "forceLocal behandelt unbekannt" \
    'case \.unknown:' "$force_body"
require_body "forceLocal behandelt sicher nicht vorhanden" \
    'case \.absent:' "$force_body"

# ---------------------------------------------------------------------------
echo "--- 3. Verwerfen nur auf Nutzerwahl, nicht im Fehler-catch"

model_discard="$( { grep -cE 'discardLocalChanges' "$model" || true; } | tr -d ' ')"
if [[ "$model_discard" -eq 1 ]]; then
    pass "TodosViewModel nennt discardLocalChanges genau einmal"
else
    bad "TodosViewModel nennt discardLocalChanges genau einmal ($model_discard)"
fi

resolve_body="$(body_of "$model" 'func resolveConflictKeepingServer(')"
require_body "die Nutzerwahl ruft discardLocalChanges" \
    'try await repository\.discardLocalChanges\(id: conflict\.id\)' "$resolve_body"
require "„Server behalten“ ist an resolveConflictKeepingServer gebunden" \
    'await viewModel\.resolveConflictKeepingServer\(conflict\)' "$view"
require "die View bietet den Knopf „Server behalten“" \
    'Button\("Server behalten"\)' "$view"

handle_body="$(body_of "$model" 'private func handle(_ error: APIError, for task: TodoDTO) async {')"
forbid_body "der Fehlerpfad verwirft nichts" \
    'discardLocalChanges' "$handle_body"

validation_branch="$(case_branch "$model" '.validation')"
forbid_body "der Validierungsfehler verwirft nichts" \
    'discardLocalChanges' "$validation_branch"
require_body "der Validierungsfehler nennt nur den Grund" \
    'banner = message\(for: error\)' "$validation_branch"

conflict_body="$(body_of "$model" 'private func presentConflict(id: String) async {')"
require_body "presentConflict wertet den belegten Treffer aus" \
    'case \.found\(let server\)' "$conflict_body"
require_body "presentConflict behandelt sicher nicht vorhanden" \
    'case \.absent:' "$conflict_body"
require_body "presentConflict behandelt unbekannt" \
    'case \.unknown:' "$conflict_body"
unknown_model_branch="$(case_branch "$model" '.unknown')"
forbid_body "unbekannt entfernt den Eintrag aus der Liste nicht" \
    'tasks\.removeAll' "$unknown_model_branch"
require_body "unbekannt behält den Eintrag ausdrücklich" \
    'Der Eintrag bleibt erhalten' "$unknown_model_branch"

# ---------------------------------------------------------------------------
echo "--- 4. Tastatur beim Scrollen ausblenden"

require "TodosView dismissiert die Tastatur beim Scrollen" \
    '\.scrollDismissesKeyboard\(\.interactively\)' "$view"
require "TodoEditorSheet dismissiert die Tastatur beim Scrollen" \
    '\.scrollDismissesKeyboard\(\.interactively\)' "$editor"

view_list_body="$(body_of "$view" 'private var list: some View {')"
require_body "TodosView hängt das Dismiss an die Liste" \
    '\.scrollDismissesKeyboard\(\.interactively\)' "$view_list_body"
if awk '
    /\.listStyle\(\.plain\)/                    { style = NR }
    /\.scrollDismissesKeyboard\(\.interactively\)/ { dismiss = NR }
    END { exit (style && dismiss && style < dismiss ? 0 : 1) }
' <<<"$view_list_body"; then
    pass "das Dismiss steht am Listen-Container"
else
    bad "das Dismiss steht am Listen-Container"
fi

form_line="$(grep -nE '^\s*Form \{' "$editor" | head -1 | cut -d: -f1 || true)"
dismiss_line="$(grep -nE '\.scrollDismissesKeyboard\(\.interactively\)' "$editor" | head -1 | cut -d: -f1 || true)"
if [[ -n "$form_line" && -n "$dismiss_line" && "$dismiss_line" -gt "$form_line" ]]; then
    pass "das Dismiss steht am Formular"
else
    bad "das Dismiss steht am Formular (Form: ${form_line:-?}, Dismiss: ${dismiss_line:-?})"
fi

forbid "TodosView führt kein onSubmit ein" 'onSubmit' "$view"
forbid "TodosView führt kein submitLabel ein" 'submitLabel' "$view"
forbid "TodoEditorSheet führt kein onSubmit ein" 'onSubmit' "$editor"
forbid "TodoEditorSheet führt kein submitLabel ein" 'submitLabel' "$editor"

# ---------------------------------------------------------------------------
if [[ "$fail" -ne 0 ]]; then
    echo "Ergebnis: FEHLGESCHLAGEN"
    exit 1
fi

echo "Ergebnis: OK"
