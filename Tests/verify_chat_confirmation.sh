#!/usr/bin/env bash
#
# Statischer Regressionstest für MARAAA-89 (Review N1/N5) und MARAAA-96
# (Review N1b/N5):
#   (a) Header-Injektion existiert genau einmal — in NetworkClient.swift.
#   (b) Modell-angeforderte tools/call laufen nicht ohne Nutzerfreigabe.
#   (c) Abnahme MARAAA-96: null Header-Duplikate im Chat, 5/5 MCP-Begriffe,
#       benannter Bestätigungspfad, Ausführung nur hinter der Freigabe.
#
# Warum statisch: Auf diesem Prüfstand gibt es keine Swift-Toolchain; die
# übrigen WP-Abnahmen laufen ebenfalls über grep-/Schema-Prüfungen.
#
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$root"

fail=0

pass() { echo "ok:   $1"; }
fail_check() { echo "FAIL: $1"; fail=1; }

require() {
    local description="$1"
    local pattern="$2"
    local file="$3"
    if grep -qE "$pattern" "$file"; then
        pass "$description"
    else
        fail_check "$description ($file)"
    fi
}

forbid() {
    local description="$1"
    local pattern="$2"
    local file="$3"
    if grep -qE "$pattern" "$file"; then
        fail_check "$description ($file)"
    else
        pass "$description"
    fi
}

network="Planer/Networking/NetworkClient.swift"
chat_dir="Planer/Features/Chat"
mcp="Planer/Features/Chat/MCPClient.swift"
stream="Planer/Features/Chat/ChatStreamProvider.swift"
model="Planer/Features/Chat/ChatViewModel.swift"
view="Planer/Features/Chat/ChatView.swift"
policy="Planer/Features/Chat/ToolCallPolicy.swift"
confirmation="Planer/Features/Chat/ToolCallConfirmation.swift"

# --- (a) Header-Injektion genau einmal -------------------------------------

# Die drei sicherheitsrelevanten Header dürfen nur in NetworkClient.swift
# gesetzt werden. Gezählt werden Zuweisungen (setValue), nicht Doc-Kommentare.
setvalue_count="$(grep -rhE 'setValue\(.*(CF-Access-Client-Id|CF-Access-Client-Secret|Authorization)' Planer --include='*.swift' | wc -l | tr -d ' ')"
if [[ "$setvalue_count" -eq 3 ]]; then
    pass "genau drei Auth-Header-Zuweisungen app-weit"
else
    fail_check "genau drei Auth-Header-Zuweisungen app-weit (gefunden: $setvalue_count)"
fi

forbid "Chat-Client setzt keine Auth-Header" 'setValue\(.*(CF-Access|Authorization)' "$mcp"
forbid "Chat-Strom setzt keine Auth-Header" 'setValue\(.*(CF-Access|Authorization)' "$stream"
forbid "die alte Chat-lokale Injektion ist entfernt" 'HermesAuthorization' "$mcp"

require "NetworkClient bietet einen Streaming-Send" \
    'func stream\(_ request: APIRequest' "$network"
require "Streaming-Send nutzt URLSession.bytes(for:)" \
    'session\.bytes\(for:' "$network"
require "Streaming-Send nutzt denselben Request-Aufbau" \
    'makeURLRequest\(request, configuration: configuration\)' "$network"
require "Header-Injektion bleibt genau eine Methode" \
    'private func injectHeaders' "$network"
require "MCP-Client nutzt den Streaming-Send" \
    'networkClient\.stream\(apiRequest, for: service\)' "$mcp"
require "Chat-Strom nutzt den Streaming-Send" \
    'networkClient\.stream\(request, for: \.hermes\)' "$stream"

# --- (b) Schreibpfad nur mit Freigabe --------------------------------------

require "Freigaberegel existiert" 'enum ToolCallPolicy' "$policy"
require "Default deny: nur readOnlyHint == true läuft ohne Freigabe" \
    'tool\.annotations\?\.readOnlyHint != true' "$policy"
forbid "keine Freigabe per Werkzeugnamen-Raterei" \
    'contains\("(create|update|delete|add)' "$policy"

require "Bestätigungsmodell existiert" 'struct ToolCallConfirmation' "$confirmation"
require "Bestätigung hält den wartenden Aufruf" 'let pendingToolCall: ToolCallRequest' "$confirmation"
require "ChatViewModel hält den wartenden Aufruf als pendingToolCall" \
    'var pendingToolCall: ToolCallConfirmation\?' "$model"
require "ChatViewModel baut die Bestätigung aus der Freigaberegel" \
    'requiresConfirmation: ToolCallPolicy\.requiresConfirmation\(for: tool\(named: request\.name\)\)' "$model"
require "ChatViewModel fragt vor dem Aufruf nach Freigabe" \
    'if confirmation\.requiresConfirmation' "$model"
require "ChatViewModel wartet auf die Entscheidung" \
    'let approved = await waitForDecision\(on: confirmation\)' "$model"
require "Ablehnung wird an das Modell gemeldet" \
    'recordDecline\(request, badgeID: badgeID\)' "$model"
require "Chip 'Ausführen' löst die Freigabe aus" \
    'func approveToolCall' "$model"
require "Chip 'Ablehnen' löst die Ablehnung aus" \
    'func declineToolCall' "$model"
require "Abbruch löst offene Chips auf" \
    'resolvePendingConfirmations\(approved: false' "$model"

# Die Ausführung muss im Quelltext NACH der Freigabeprüfung stehen: sonst
# könnte ein Aufruf ohne Entscheidung laufen.
gate_line="$(grep -n 'ToolCallPolicy\.requiresConfirmation' "$model" | head -1 | cut -d: -f1)"
execute_line="$(grep -n 'await execute(request, badgeID: badgeID)' "$model" | head -1 | cut -d: -f1)"
if [[ -n "$gate_line" && -n "$execute_line" && "$gate_line" -lt "$execute_line" ]]; then
    pass "Freigabeprüfung steht vor der Ausführung"
else
    fail_check "Freigabeprüfung steht vor der Ausführung (gate=$gate_line, execute=$execute_line)"
fi

require "ChatView rendert die Action-Chips" \
    'ToolConfirmationChips\(' "$view"
require "Chips erscheinen nur bei wartendem Aufruf" \
    'if entry\.awaitsConfirmation' "$view"

# --- (c) Abnahme MARAAA-96 ---------------------------------------------------
# Vier binäre Kriterien, hier als Prüfung — damit sie reproduzierbar sind und
# nicht bei der nächsten Änderung still brechen.

# K1: keine zweite Header-Injektion im Chat-Feature.
header_hits="$(grep -rn 'CF-Access-Client-Id' "$chat_dir" 2>/dev/null | wc -l | tr -d ' ' || true)"
if [[ "$header_hits" -eq 0 ]]; then
    pass "K1: keine CF-Access-Header im Chat-Feature"
else
    fail_check "K1: keine CF-Access-Header im Chat-Feature (gefunden: $header_hits)"
fi

# K2: die fünf MCP-Begriffe aus spec-ios §1/I3 — keine Regression.
for term in 'Mcp-Session-Id' 'initialize' 'tools/call' 'tools/list' 'text/event-stream'; do
    count="$(grep -rIo "$term" "$chat_dir" 2>/dev/null | wc -l | tr -d ' ' || true)"
    if [[ "$count" -ge 1 ]]; then
        pass "K2: MCP-Begriff vorhanden — $term ($count)"
    else
        fail_check "K2: MCP-Begriff fehlt — $term"
    fi
done

# K3: expliziter Bestätigungspfad, unter genau diesem Namen.
path_hits="$(grep -rIlE 'pendingToolCall|ToolCallConfirmation|confirmToolCall' "$chat_dir" 2>/dev/null | wc -l | tr -d ' ' || true)"
if [[ "$path_hits" -ge 1 ]]; then
    pass "K3: expliziter Bestätigungspfad benannt ($path_hits Datei(en))"
else
    fail_check "K3: expliziter Bestätigungspfad benannt"
fi

# K4: Doc-Kommentar an der Ausführungsstelle + Aufruf nur hinter der Freigabe.
require "K4: Doc-Kommentar nennt die Grenze an der Ausführungsstelle" \
    'Schreibende Werkzeuge erreichen diese Stelle nie ohne Freigabe' "$model"

execute_calls="$(grep -cE 'await execute\(request, badgeID: badgeID\)' "$model" | tr -d ' ' || true)"
if [[ "$execute_calls" -eq 1 ]]; then
    pass "K4: genau eine Ausführungsstelle im ChatViewModel"
else
    fail_check "K4: genau eine Ausführungsstelle im ChatViewModel (gefunden: $execute_calls)"
fi

# Die Freigabesperre muss zwischen dem Warten und der Ausführung liegen, und
# die Ablehnung muss die Ausführung überspringen — nicht nur protokollieren.
gate_line="$(grep -n 'if confirmation\.requiresConfirmation' "$model" | head -1 | cut -d: -f1)"
wait_line="$(grep -n 'let approved = await waitForDecision' "$model" | head -1 | cut -d: -f1)"
decline_line="$(grep -n 'guard approved else' "$model" | head -1 | cut -d: -f1)"
execute_line="$(grep -n 'await execute(request, badgeID: badgeID)' "$model" | head -1 | cut -d: -f1)"
if [[ -n "$gate_line" && -n "$wait_line" && -n "$decline_line" && -n "$execute_line" ]] \
    && [[ "$gate_line" -lt "$wait_line" && "$wait_line" -lt "$decline_line" && "$decline_line" -lt "$execute_line" ]]; then
    pass "K4: Freigabe → Warten → Ablehnung → Ausführung stehen in dieser Reihenfolge"
else
    fail_check "K4: Reihenfolge Freigabe/Warten/Ablehnung/Ausführung (gate=$gate_line, wait=$wait_line, decline=$decline_line, execute=$execute_line)"
fi

# K4-Gegenprobe: ohne `continue` im Ablehnungszweig würde die Ausführung trotz
# Ablehnung erreicht. Geprüft wird der Block hinter `guard approved else`, nicht
# nur die Meldung.
if grep -A6 'guard approved else' "$model" | grep -q 'continue'; then
    pass "K4: Ablehnung überspringt die Ausführung (continue im else-Zweig)"
else
    fail_check "K4: Ablehnung überspringt die Ausführung (continue im else-Zweig)"
fi

# Genau ein Aufrufer von `callTool` — sonst gäbe es einen zweiten, ungeprüften
# Schreibpfad am ChatViewModel vorbei.
call_sites="$(grep -rn 'mcpClient\.callTool' "$chat_dir" 2>/dev/null | wc -l | tr -d ' ' || true)"
if [[ "$call_sites" -eq 1 ]]; then
    pass "K4: genau ein tools/call-Aufrufer im Chat-Feature"
else
    fail_check "K4: genau ein tools/call-Aufrufer im Chat-Feature (gefunden: $call_sites)"
fi

# --- Schreibfall-Gegenprobe -------------------------------------------------
# Ein schreibendes Werkzeug ohne Annotation darf nicht als "nur lesend"
# durchgehen: die Regel darf nicht auf `== false` prüfen (das würde `nil`
# durchlassen) und nicht auf einen Namen filtern.
if grep -qE 'readOnlyHint == false' "$policy"; then
    fail_check "fehlende Annotation gilt als bestätigungspflichtig (readOnlyHint == false wäre falsch)"
else
    pass "fehlende Annotation gilt als bestätigungspflichtig"
fi

if [[ "$fail" -ne 0 ]]; then
    echo "Ergebnis: FEHLGESCHLAGEN"
    exit 1
fi

echo "Ergebnis: OK"
