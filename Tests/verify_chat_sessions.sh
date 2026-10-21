#!/usr/bin/env bash
#
# Statische Abnahme für spec-chat Rev 4 (CH1 = Daten, CH2 = UI; N1–N6 eingearbeitet).
# Keine Swift-Toolchain nötig — geprüft werden Dateien und Symbole.
#
#   bash Tests/verify_chat_sessions.sh data   # CH1
#   bash Tests/verify_chat_sessions.sh ui     # CH2
#   bash Tests/verify_chat_sessions.sh all    # beide (Default)
#
# Exit-Status: 0 = alle Prüfungen der Schicht grün, 1 = mindestens eine rot,
# 2 = falscher Aufruf. Der Status stammt aus `fail`, nie aus einem `echo`.
#
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$root"

layer="${1:-all}"
chat="Planer/Features/Chat"
fail=0

pass() { echo "ok:   $1"; }
bad()  { echo "FAIL: $1"; fail=1; }

file_required()  { [[ -f "$1" ]] && pass "Datei: $1" || bad "Datei fehlt: $1"; }
file_forbidden() { [[ ! -e "$1" ]] && pass "entfernt: $1" || bad "muss entfernt sein: $1"; }
need()  { if grep -qE "$2" "$1"; then pass "$3"; else bad "$3  [$1 ~ /$2/]"; fi; }
ban()   { if grep -qE "$2" "$1"; then bad "$3  [$1]"; else pass "$3"; fi; }
# Suchraum ist standardmäßig der Chat-Ordner: NetworkClient.swift:294 ist die
# benannte Ausnahme außerhalb (Befund 1, §3.3), nicht Teil der Abnahme.
ban_tree() {
    local pattern="$1" label="$2" dir="${3:-$chat}" hits
    hits="$(grep -rInE "$pattern" "$dir" --include='*.swift' 2>/dev/null | wc -l | tr -d ' ' || true)"
    [[ "$hits" -eq 0 ]] && pass "$label" || bad "$label (Treffer: $hits)"
}

# N1: Der Freigabe-Typ hat genau zwei Fälle, beide mit explizitem Wire-Wert.
# Rot bei `case session`, `case always`, impliziten Raw-Values oder einem dritten Fall.
# Der Rumpf wird aus der Deklaration geschnitten, damit ein `case session` in einem
# fremden CodingKeys-Enum nicht fälschlich als Freigabe-Fall zählt.
approval_choice_is_exact() {
    local file="$chat/ChatDTOs.swift" body count
    body="$(awk '/^enum ChatApprovalChoice[ :{]/{f=1} f{print} f&&/^}/{exit}' "$file")"
    count="$(printf '%s
' "$body" | grep -cE '^[[:space:]]*case ' || true)"
    if [[ "$count" -eq 2 ]] \
       && printf '%s
' "$body" | grep -qE '^[[:space:]]*case once = "once"' \
       && printf '%s
' "$body" | grep -qE '^[[:space:]]*case deny = "deny"' \
       && ! printf '%s
' "$body" | grep -qE '^[[:space:]]*case (session|always)\b'; then
        pass "ChatApprovalChoice: genau once/deny mit expliziten Wire-Werten"
    else
        bad "ChatApprovalChoice: genau once/deny mit expliziten Wire-Werten"
    fi
}

data_layer() {
    echo "--- CH1: Protokoll und Daten"
    file_required "$chat/ChatDTOs.swift"
    file_required "$chat/ChatConfiguration.swift"
    file_required "$chat/ChatSSE.swift"
    file_required "$chat/HermesChatAPI.swift"
    file_required "$chat/ChatStreamProvider.swift"
    file_required "$chat/ChatViewModel.swift"

    file_forbidden "$chat/MCPClient.swift"
    file_forbidden "$chat/MCPSession.swift"
    file_forbidden "$chat/ToolCallPolicy.swift"
    file_forbidden "$chat/ToolCallConfirmation.swift"
    file_forbidden "Tests/verify_chat_confirmation.sh"

    # Befund 1: Suchraum Features/Chat. Befund 11: JSONValue. Befund 12: MCPProtocol.
    ban_tree 'MCPClient|MCPTool|MCPSession|MCPProtocol|ToolCallPolicy|ToolCallConfirmation|callTool|listTools|JSONValue' \
        "keine clientseitige MCP-Spur mehr"

    # Genau eine Stelle setzt den Fortsetzungs-Header.
    local header_hits
    header_hits="$(grep -rIo 'X-Hermes-Session-Id' Planer --include='*.swift' | wc -l | tr -d ' ' || true)"
    [[ "$header_hits" -eq 1 ]] && pass "genau eine Session-Header-Konstante" \
        || bad "genau eine Session-Header-Konstante (gefunden: $header_hits)"
    need "$chat/ChatConfiguration.swift" 'sessionHeader = "X-Hermes-Session-Id"' \
        "Header steht in der Konfiguration"

    # Provider: Signatur, Ereignisfälle, Dispatch nach event-Namen, kein tools-Array.
    need "$chat/ChatStreamProvider.swift" \
        'func stream\(sessionID: String, userText: String\)' "Provider-Signatur"
    need "$chat/ChatStreamProvider.swift" 'case reasoningDelta\(' "Ereignis reasoningDelta"
    need "$chat/ChatStreamProvider.swift" 'case toolProgress\(' "Ereignis toolProgress"
    need "$chat/ChatStreamProvider.swift" 'case status\(' "Ereignis status"
    need "$chat/ChatStreamProvider.swift" 'case approval\(' "Ereignis approval"
    need "$chat/ChatStreamProvider.swift" 'case finished\(' "Ereignis finished"
    need "$chat/ChatStreamProvider.swift" 'hermes\.tool\.progress' "Event-Name tool.progress"
    need "$chat/ChatStreamProvider.swift" 'hermes\.status' "Event-Name status"
    need "$chat/ChatStreamProvider.swift" 'approval\.request' "Event-Name approval"
    ban  "$chat/ChatStreamProvider.swift" '"tools"' "kein tools-Array im Request"
    ban  "$chat/ChatStreamProvider.swift" 'maxHistoryTurns' "keine Client-Historie im Request"
    need "$chat/ChatStreamProvider.swift" 'makeChatRequestBody\(userText:' "Body-Bauer für einen User-Turn"

    # Befund 9: F8 hängt am Inhalt, nicht an irgendeinem empfangenen Frame.
    need "$chat/ChatStreamProvider.swift" 'sawContent' "Inhalts-Flag für F8"
    need "$chat/ChatStreamProvider.swift" 'case emptyResponse' "Fehlerfall leerer Strom"
    ban  "$chat/ChatStreamProvider.swift" 'receivedEvent' "kein receivedEvent als Inhaltsbeweis"

    # Befund 4: der Strom-Client trägt streamIdleTimeout, nie den 10-s-Default.
    need "$chat/ChatStreamProvider.swift" \
        'NetworkClient\(timeout: configuration\.streamIdleTimeout\)' "Strom-Client mit streamIdleTimeout"
    ban  "$chat/ChatStreamProvider.swift" 'NetworkClient\(\)' "kein Default-Client (10 s) im Provider"

    # API-Flächen.
    need "$chat/HermesChatAPI.swift" 'func listSessions\(' "API listSessions"
    need "$chat/HermesChatAPI.swift" 'func createSession\(' "API createSession"
    need "$chat/HermesChatAPI.swift" 'func messages\(sessionID:' "API messages"
    need "$chat/HermesChatAPI.swift" 'func respondToApproval\(runID:' "API respondToApproval"
    need "$chat/ChatConfiguration.swift" 'approvalPath' "Freigabe-Pfad konfiguriert"
    need "$chat/ChatConfiguration.swift" 'sessionSource = "desktop"' "Source desktop"

    # Befund 4/5: Zeit- und Retry-Klassen an der Konstruktion, ein Client je Klasse.
    need "$chat/HermesChatAPI.swift" \
        'NetworkClient\(timeout: configuration\.restTimeout' "REST-Clients mit restTimeout"
    need "$chat/HermesChatAPI.swift" 'RetryPolicy\(maxAttempts: 1\)' "Schreib-Client ohne Retry"
    ban  "$chat/HermesChatAPI.swift" 'NetworkClient\(\)' "kein Default-Client (10 s) in der API"

    # O1: eine Basis-URL mit Pfad wird abgelehnt, nicht stillschweigend benutzt.
    need "$chat/ChatConfiguration.swift" 'case baseURLHasPath\(' "Fehlerfall Basis-URL mit Pfad"
    need "$chat/ChatConfiguration.swift" 'func validateBaseURL\(path:' "Guard für die Basis-URL"
    need "$chat/HermesChatAPI.swift" 'validateBaseURL\(path:' "Guard wird vor dem Request benutzt"
    # N2: genau ein Ort. Die API ruft den Guard auf, sie definiert ihn nicht.
    ban  "$chat/HermesChatAPI.swift" 'func validateBaseURL\(path:' "Guard nicht doppelt in der API"

    need "$chat/ChatDTOs.swift" 'struct SessionSummary' "SessionSummary"
    need "$chat/ChatDTOs.swift" 'struct ChatMessage' "ChatMessage"
    need "$chat/ChatDTOs.swift" 'struct ChatToolProgress' "ChatToolProgress"
    need "$chat/ChatDTOs.swift" 'struct ChatApproval' "ChatApproval"
    need "$chat/ChatDTOs.swift" 'struct ChatFinish' "ChatFinish"
    need "$chat/ChatDTOs.swift" 'struct SessionPage' "SessionPage"
    need "$chat/ChatDTOs.swift" 'struct MessagePage' "MessagePage"
    need "$chat/ChatDTOs.swift" 'enum ToolCallStatus' "ToolCallStatus"

    # N3: alle Wire-Typen sind Decodable — inklusive der drei realen Hüllen aus P3/P4.
    need "$chat/ChatDTOs.swift" 'struct SessionSummary: Identifiable, Decodable' "SessionSummary ist Decodable"
    need "$chat/ChatDTOs.swift" 'struct SessionEnvelope: Decodable' "SessionEnvelope {object, session}"
    need "$chat/ChatDTOs.swift" 'struct SessionPage: Decodable' "SessionPage ist Decodable"
    need "$chat/ChatDTOs.swift" 'struct MessagePage: Decodable' "MessagePage ist Decodable"
    need "$chat/ChatDTOs.swift" 'struct ChatMessage: Decodable' "ChatMessage ist Decodable"
    need "$chat/ChatDTOs.swift" 'struct StoredToolCall: Decodable' "StoredToolCall ist Decodable"
    need "$chat/ChatDTOs.swift" 'struct ChatToolProgress: Decodable' "ChatToolProgress ist Decodable"
    need "$chat/ChatDTOs.swift" 'struct ChatStatusNote: Decodable' "ChatStatusNote ist Decodable"
    need "$chat/ChatDTOs.swift" 'struct ChatApproval: Decodable' "ChatApproval ist Decodable"
    # N3: pagination.returned liegt verschachtelt; CodingKeys allein erreicht es nicht.
    need "$chat/ChatDTOs.swift" 'nestedContainer\(keyedBy: PaginationKeys\.self, forKey: \.pagination\)' \
        "pagination.returned über nestedContainer"
    need "$chat/ChatDTOs.swift" 'forKey: \.returned' "PaginationKeys.returned"
    need "$chat/HermesChatAPI.swift" 'SessionEnvelope' "API dekodiert die Session-Hülle"
    # Kein direkter Decode der Hülle als SessionSummary.
    ban  "$chat/HermesChatAPI.swift" 'as: SessionSummary\.self' "kein Decode der Hülle als SessionSummary"

    # N5: „Mehr laden“/„Ältere laden“ müssen sich auch nach einer leeren Seite aktualisieren.
    need "$chat/ChatViewModel.swift" '@Published private\(set\) var loadedAllSessions' "loadedAllSessions ist @Published"
    need "$chat/ChatViewModel.swift" '@Published private\(set\) var hasMoreOlder' "hasMoreOlder ist @Published"

    # Befund 3: last_active ist eine Zahl, kein Date.
    need "$chat/ChatDTOs.swift" 'var lastActive: Double\?' "SessionSummary.lastActive ist Double"
    need "$chat/ChatDTOs.swift" 'var lastActiveDate: Date\?' "Abbildung auf Date an einer Stelle"
    ban  "$chat/ChatDTOs.swift" 'var lastActive: Date\?' "kein Date-Feld auf last_active"

    # Befund 2: Thinking-/Detail-Default steht an der Deklaration, nicht am Aufrufer.
    need "$chat/ChatViewModel.swift" 'var reasoningDisclosure: Disclosure = \.collapsed' \
        "Thinking-Default an der Deklaration"
    need "$chat/ChatViewModel.swift" 'var toolDetailDisclosure: Disclosure = \.collapsed' \
        "Tool-Detail-Default an der Deklaration"
    need "$chat/ChatViewModel.swift" 'enum Disclosure' "Disclosure-Typ"
    need "$chat/ChatViewModel.swift" 'var reasoning: String\?' "Entry.reasoning"
    need "$chat/ChatViewModel.swift" 'var toolCallID: String\?' "Entry.toolCallID"
    need "$chat/ChatViewModel.swift" 'var toolArgs: String\?' "Entry.toolArgs"
    need "$chat/ChatViewModel.swift" 'var toolResult: String\?' "Entry.toolResult"
    need "$chat/ChatViewModel.swift" 'reasoningDisclosure: Disclosure' "Entry.reasoningDisclosure"
    need "$chat/ChatViewModel.swift" 'toolDetailDisclosure: Disclosure' "Entry.toolDetailDisclosure"

    # H8-Ersatz (N1): Der Sicherheitspfad wird dort geprüft, wo der Wire-Wert entsteht.
    # ChatApprovalChoice liegt in ChatDTOs.swift (§5.1); ChatViewModel reicht nur den Enum durch.
    # Die früheren `need ChatViewModel '"once"'/'"deny"'` sind gestrichen — sie verlangten
    # ein Literal in einer Datei, die per Spezifikation nur den Enum kennt.
    need "$chat/ChatDTOs.swift" 'enum ChatApprovalChoice: String' "Freigabe-Choice-Typ in ChatDTOs"
    need "$chat/ChatDTOs.swift" 'case once = "once"' "Wire-Wert once am Entstehungsort"
    need "$chat/ChatDTOs.swift" 'case deny = "deny"' "Wire-Wert deny am Entstehungsort"
    need "$chat/HermesChatAPI.swift" 'choice\.rawValue' "Wire-Wert wird aus dem Enum gebaut"
    need "$chat/ChatDTOs.swift" 'canApproveOnce' "fail closed: once nur wenn angeboten"
    need "$chat/ChatDTOs.swift" 'canDeny' "fail closed: deny nur wenn angeboten"
    ban  "$chat/ChatDTOs.swift" 'case session\b' "keine Dauerfreigabe session in v1"
    ban  "$chat/ChatDTOs.swift" 'case always\b' "keine Dauerfreigabe always in v1"
    ban  "$chat/ChatDTOs.swift" '"(session|always)"' "keine Dauerfreigabe-Wire-Werte"
    # Der Enum darf nicht ins ViewModel wandern (sonst greift der Bann oben nicht mehr).
    ban  "$chat/ChatViewModel.swift" 'enum ChatApprovalChoice' "Choice-Typ nicht im ViewModel definiert"
    # Kein Roh-Literal im ViewModel: es reicht den Enum durch (kein toter String).
    ban  "$chat/ChatViewModel.swift" '"once"' "kein Roh-Literal once im ViewModel"
    ban  "$chat/ChatViewModel.swift" '"deny"' "kein Roh-Literal deny im ViewModel"
    approval_choice_is_exact

    # Befund 13: die eingefrorene Sprach-Nahtstelle (§9.6) wird nicht still verloren.
    need "$chat/ChatViewModel.swift" 'var voice: \(any VoiceAssistant\)\?' "Voice-Feld"
    need "$chat/ChatViewModel.swift" 'voice\?\.ingestAssistantDelta\(' "N2: Text an die Sprachschicht"
    need "$chat/ChatViewModel.swift" 'voice\?\.finishAssistantStream\(' "N3: Turn-Ende an die Sprachschicht"
    need "$chat/ChatViewModel.swift" 'voice\?\.stopSpeaking\(' "N4: Abbruch stoppt das Vorlesen"

    # Öffentliche ViewModel-API (§9.3).
    for sig in 'func loadSessions\(\) async' 'func loadMoreSessions\(\) async' \
               'func openSession\(' 'func newChat\(\)' \
               'func send\(\)' 'func cancel\(\)' 'func loadOlderMessages\(\) async' \
               'func toggleReasoning\(_ entryID: UUID\)' 'func toggleToolDetail\(_ entryID: UUID\)' \
               'func decideApproval\(_ entryID: UUID, choice:' 'func detach\(\)' \
               'func appendDictation\(_ text: String\)'; do
        need "$chat/ChatViewModel.swift" "$sig" "ViewModel: $sig"
    done
}

ui_layer() {
    echo "--- CH2: Oberfläche"
    file_required "$chat/ChatView.swift"
    file_required "$chat/SessionListView.swift"
    file_required "$chat/ThinkingDisclosureView.swift"
    file_required "$chat/ToolCallCard.swift"
    file_required "$chat/ToolConfirmationChips.swift"
    file_forbidden "$chat/ToolCallBadge.swift"

    for sym in 'SessionListView(' 'ThinkingDisclosureView(' 'ToolCallCard(' \
               'ToolConfirmationChips(' 'toggleReasoning(' 'toggleToolDetail(' \
               'decideApproval(' 'detach()'; do
        need "$chat/ChatView.swift" "$(printf '%s' "$sym" | sed 's/(/\\(/g; s/)/\\)/g')" "ChatView nutzt $sym"
    done

    # Befund 10: der MCP-Lebenszyklus ist entfallen; die View darf ihn nicht aufrufen.
    ban "$chat/ChatView.swift" 'viewModel\.(connect|disconnect)\(' "kein connect()/disconnect() mehr"
    # Befund 13: Voice wird in der View verdrahtet (N1).
    need "$chat/ChatView.swift" 'viewModel\.voice = voice' "Voice-Verdrahtung in der View"
    # N4: auch der Eingabepfad (Diktat) muss verdrahtet bleiben.
    need "$chat/ChatView.swift" 'voice\.onTranscript =' "Voice-Diktat verdrahtet (onTranscript)"

    ban "$chat/ToolConfirmationChips.swift" 'ToolCallPolicy' "Chips ohne ToolCallPolicy"
    ban_tree 'import (Alamofire|SkeletonUI|MarkdownUI|RichTextKit|Lottie)' \
        "keine Fremd-UI-Bibliothek"
    # H8-Ersatz: die Chips fragen die fail-closed-Prädikate, statt Choices zu raten.
    need "$chat/ToolConfirmationChips.swift" 'canApproveOnce' "Chips: once nur wenn angeboten"
    need "$chat/ToolConfirmationChips.swift" 'canDeny' "Chips: deny nur wenn angeboten"

    # Befund 2: hier steht bewusst KEINE Prüfung von ChatViewModel.swift —
    # die Datei gehört CH1, und der Default wird an der Deklaration geprüft.
}

case "$layer" in
    data) data_layer ;;
    ui)   ui_layer ;;
    all)  data_layer; ui_layer ;;
    *)    echo "Aufruf: $0 [data|ui|all]"; exit 2 ;;
esac

if [[ "$fail" -ne 0 ]]; then
    echo "Ergebnis: FEHLGESCHLAGEN ($layer)"
    exit 1
fi
echo "Ergebnis: OK ($layer)"
