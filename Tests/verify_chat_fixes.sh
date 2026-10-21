#!/usr/bin/env bash
#
# Statische Regression für CH3 (Nachbesserung G-CH1, spec-chat Rev 5).
#
# Geprüft werden die 15 Befunde aus MARAAA-125: B1, H1/H2, M1–M5 und die
# sieben Niedrig-Befunde. Keine Swift-Toolchain nötig — geprüft werden
# Dateien, Symbole und die Reihenfolge kritischer Zeilen.
#
#   bash Tests/verify_chat_fixes.sh
#
# Exit-Status: 0 = alle Invarianten grün, 1 = mindestens eine rot.
#
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$root"

chat="Planer/Features/Chat"
api="$chat/HermesChatAPI.swift"
provider="$chat/ChatStreamProvider.swift"
model="$chat/ChatViewModel.swift"
view="$chat/ChatView.swift"
card="$chat/ToolCallCard.swift"
sessions="$chat/SessionListView.swift"

fail=0

pass() { echo "ok:   $1"; }
bad()  { echo "FAIL: $1"; fail=1; }

need() {
    local file="$1" pattern="$2" label="$3"
    if grep -qE "$pattern" "$file"; then
        pass "$label"
    else
        bad "$label  [$file ~ /$pattern/]"
    fi
}

ban() {
    local file="$1" pattern="$2" label="$3"
    if grep -qE "$pattern" "$file"; then
        bad "$label  [$file]"
    else
        pass "$label"
    fi
}

ban_tree() {
    local pattern="$1" label="$2" hits
    hits="$(grep -rInE "$pattern" "$chat" --include='*.swift' 2>/dev/null | wc -l | tr -d ' ' || true)"
    if [[ "$hits" -eq 0 ]]; then
        pass "$label"
    else
        bad "$label (Treffer: $hits)"
    fi
}

first_line() {
    local file="$1" pattern="$2"
    grep -nE "$pattern" "$file" 2>/dev/null | head -1 | cut -d: -f1 || true
}

# ---------------------------------------------------------------------------
echo "--- B1: NetworkClient-Argumentreihenfolge"

need "$api" 'retryPolicy: RetryPolicy\(maxAttempts: 1\),' \
    "B1: Schreib-Client übergibt retryPolicy"
need "$api" 'timeout: configuration\.restTimeout' \
    "B1: Schreib-Client übergibt timeout"
ban_tree 'timeout:.*retryPolicy:' \
    "B1: nirgends timeout vor retryPolicy"

writer_block="$(awk '
    /self\.writer = NetworkClient\(/ { in_block = 1 }
    in_block { print }
    in_block && /^        \)/ { exit }
' "$api")"
writer_retry="$(printf '%s\n' "$writer_block" | grep -nE 'retryPolicy: RetryPolicy\(maxAttempts: 1\),' | head -1 | cut -d: -f1 || true)"
writer_timeout="$(printf '%s\n' "$writer_block" | grep -nE 'timeout: configuration\.restTimeout' | head -1 | cut -d: -f1 || true)"
if [[ -n "$writer_retry" && -n "$writer_timeout" && "$writer_retry" -lt "$writer_timeout" ]]; then
    pass "B1: retryPolicy steht im Schreib-Client vor timeout"
else
    bad "B1: retryPolicy steht im Schreib-Client vor timeout"
fi

# ---------------------------------------------------------------------------
echo "--- H1: Antwort-Session-ID und F15"

need "$provider" 'case sessionID\(String\)' "H1: Ereignis sessionID"
need "$provider" 'value\(forHTTPHeaderField: configuration\.sessionHeader\)' \
    "H1: Provider liest den Antwort-Header"
need "$provider" 'continuation\.yield\(\.sessionID\(responseSessionID\)\)' \
    "H1: Provider reicht die Antwort-ID als Ereignis"
need "$model" 'case \.sessionID\(let responseID\)' \
    "H1: ViewModel empfängt die Antwort-ID"
need "$model" 'adoptSessionID\(responseID\)' \
    "H1: ViewModel übernimmt die abweichende ID"
need "$model" 'private func adoptSessionID' "H1: Übernahme ist eine eigene Naht"
need "$model" 'currentSession = SessionSummary\(' \
    "H1: currentSession erhält die neue ID"
need "$model" 'Der Verlauf wird nicht fortgesetzt \(Sitzungs-Header fehlt\)\.' \
    "H1/F15: Warnung bei fehlendem Header wörtlich"

# ---------------------------------------------------------------------------
echo "--- H2: streamStarted erst nach dem ersten Ereignis"

loop_line="$(first_line "$model" 'for try await event in provider\.stream')"
started_line="$(first_line "$model" 'streamStarted = true')"
started_count="$( { grep -cE 'streamStarted = true' "$model" || true; } | tr -d ' ')"
if [[ -n "$loop_line" && -n "$started_line" \
      && "$started_count" -eq 1 && "$started_line" -gt "$loop_line" ]]; then
    pass "H2: streamStarted wird im Ereignis-Loop gesetzt"
else
    bad "H2: streamStarted wird im Ereignis-Loop gesetzt (Loop: ${loop_line:-?}, Flag: ${started_line:-?}, Anzahl: ${started_count:-0})"
fi
need "$model" 'if !streamStarted \{' "H2: Rollback unterscheidet vor/nach dem Start"
need "$model" 'rollbackUserEntry\(text: text\)' "H2: optimistischer Eintrag wird zurückgerollt"

# ---------------------------------------------------------------------------
echo "--- M1: Fehler-Vorrang beim Anlegen (F10 nur Transport/Timeout/5xx)"

need "$model" 'private static func isCreateFailure' "M1: eigene Klassifikation"
need "$model" 'case \.timeout, \.offline:' "M1: Transport/Timeout → F10"
need "$model" 'return status >= 500' "M1: nur 5xx → F10"
need "$model" 'if Self\.isCreateFailure\(error\)' "M1: Klassifikation wird benutzt"
need "$model" 'throw error' "M1: spezifische Fehler werden weitergeworfen"
need "$model" 'case \.unauthorized, \.forbidden, \.notFound, \.conflict,' \
    "M1: 401/403/404/409 bleiben spezifisch"
need "$model" 'if error is HermesChatConfigurationError \{ return false \}' \
    "M1: F22 bleibt spezifisch"
need "$model" 'if error is CancellationError \{ return false \}' \
    "M1: Abbruch bleibt F7"

# ---------------------------------------------------------------------------
echo "--- M2: URLError aus dem laufenden Strom"

need "$provider" 'catch let error as URLError' "M2: Provider fängt URLError"
need "$provider" 'case \.timedOut:' "M2: Timeout wird abgebildet"
need "$provider" 'case \.cancelled:' "M2: Abbruch wird abgebildet"
need "$provider" 'return \.http\(\.offline\)' "M2: Offline wird abgebildet"
need "$model" 'else if let urlError = error as\? URLError' \
    "M2: ViewModel kennt URLError"
need "$model" 'Self\.describe\(urlError\)' "M2: URLError erhält einen Text"

# ---------------------------------------------------------------------------
echo "--- M3: Scrollanker für „Ältere laden“"

need "$model" 'entries\.insert\(contentsOf: older, at: 0\)' \
    "M3: ältere Einträge werden vorangestellt"
need "$view" 'viewModel\.entries\.first\?\.id' \
    "M3: Anker ist die Entry.id des ersten sichtbaren Eintrags"
need "$view" 'proxy\.scrollTo\(anchorID, anchor: \.top\)' \
    "M3: View scrollt auf den Anker"
need "$view" 'await Task\.yield\(\)' "M3: Scrollen erst nach dem Insert"

# ---------------------------------------------------------------------------
echo "--- M4: kein Senden/Merge ohne geladenen Verlauf"

need "$model" 'private var historyLoaded = false' "M4: historyLoaded-Zustand"
need "$model" '\(currentSession == nil \|\| historyLoaded\)' \
    "M4: canSend verlangt geladenen Verlauf"
need "$model" 'watermark = page\.messages\.map\(\\\.id\)\.max\(\) \?\? 0' \
    "M4: Baseline-Wasserzeichen für leere Sessions"
need "$model" 'guard watermark != nil \|\| createdSessionThisTurn' \
    "M4: Merge-Vorbedingung"
need "$model" 'historyLoaded = true' "M4: erfolgreiches Laden gibt frei"

# ---------------------------------------------------------------------------
echo "--- M5: Voice-Regressionstest grün und weiterhin scharf"

if bash "$root/Tests/verify_voice.sh" >/dev/null 2>&1; then
    pass "M5: Tests/verify_voice.sh endet mit Exit 0"
else
    bad "M5: Tests/verify_voice.sh endet mit Exit 0"
fi
need "Tests/verify_voice.sh" 'var engine: ChatEngine' \
    "M5: Voice-Test prüft die Engine-Markierung am Modell"
need "Tests/verify_voice.sh" 'entry.engine' \
    "M5: Voice-Test prüft die Engine-Anzeige in der View"

# ---------------------------------------------------------------------------
echo "--- Niedrig-Befunde"

need "$model" 'var toolEmoji: String\?' "N: Entry.toolEmoji"
need "$model" 'toolEmoji: progress\.status == \.running \? progress\.emoji : nil' \
    "N: Emoji wird aus hermes.tool.progress gesetzt"
need "$card" 'let emoji: String\?' "N: ToolCallCard nimmt das Emoji"
need "$view" 'emoji: entry\.toolEmoji' "N: ChatView reicht das Emoji durch"

need "$sessions" 'HermesChatConfiguration\(\)\.maxPreviewCharacters' \
    "N: Vorschau nutzt maxPreviewCharacters"
ban "$sessions" 'previewLimit = 80' "N: kein zweites 80er-Literal"

need "$view" 'let notice = viewModel\.notice' \
    "N: Fehlerzustand bei leerem Verlauf"
need "$view" 'Button\("Erneut laden"\)' "N: Fehlerzustand bietet Erneut laden"

truncated_resets="$(grep -cE 'didWarnReasoningTruncated = false' "$model" | tr -d ' ' || true)"
if [[ "$truncated_resets" -ge 2 ]]; then
    pass "N: didWarnReasoningTruncated wird je Turn zurückgesetzt"
else
    bad "N: didWarnReasoningTruncated wird je Turn zurückgesetzt ($truncated_resets)"
fi

need "$model" 'if notice == nil \{' "N: Merge-Hinweis überschreibt keine Fehlermeldung"
need "$model" 'Antwort nicht im Verlauf gespeichert\.' "N: Merge-Hinweis existiert"
if awk '/if notice == nil \{/ { getline; if ($0 ~ /Antwort nicht im Verlauf gespeichert/) found = 1 } END { exit(found ? 0 : 1) }' "$model"; then
    pass "N: F12-Meldung hat Vorrang vor dem Merge-Hinweis"
else
    bad "N: F12-Meldung hat Vorrang vor dem Merge-Hinweis"
fi

need "$provider" 'HermesChatConfiguration\.validateBaseURL\(path: service\.baseURL\.path\)' \
    "N: Strom-Provider ruft den bestehenden Guard"
ban "$provider" 'func validateBaseURL\(path:' \
    "N: kein zweiter Guard-Ort im Provider"

need "$model" '@Published private\(set\) var decidingApprovalEntryID: UUID\?' \
    "N: decidingApprovalEntryID ist öffentliche API"
need "$model" 'var canSend: Bool' "N: canSend ist öffentliche API"

# ---------------------------------------------------------------------------
if [[ "$fail" -ne 0 ]]; then
    echo "Ergebnis: FEHLGESCHLAGEN"
    exit 1
fi
echo "Ergebnis: OK"
