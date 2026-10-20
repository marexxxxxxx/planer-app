#!/usr/bin/env bash
#
# Statischer Regressionstest für MARAAA-89 (Review N1/N5):
#   (a) Header-Injektion existiert genau einmal — in NetworkClient.swift.
#   (b) Modell-angeforderte tools/call laufen nicht ohne Nutzerfreigabe.
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
mcp="Planer/Features/Chat/MCPClient.swift"
stream="Planer/Features/Chat/ChatStreamProvider.swift"
model="Planer/Features/Chat/ChatViewModel.swift"
view="Planer/Features/Chat/ChatView.swift"
policy="Planer/Features/Chat/ToolCallPolicy.swift"

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

require "ChatViewModel fragt vor dem Aufruf nach Freigabe" \
    'ToolCallPolicy\.requiresConfirmation\(for: tool\(named: request\.name\)\)' "$model"
require "ChatViewModel wartet auf die Entscheidung" \
    'let approved = await waitForDecision\(on: badgeID\)' "$model"
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
