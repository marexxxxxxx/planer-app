#!/usr/bin/env bash
#
# Statischer Regressionstest der Sprachschicht (spec-voice Rev 2, §13).
#
# Geprüft wird:
#   - V4: beide Info.plist-Keys in Debug **und** Release, wortwörtliche Texte
#         (§5), die Freigabe-Helfer (§11) und die Abwesenheit der in iOS 17
#         abgekündigten Mikrofon-API.
#   - die Datenschutz-Invarianten der Sprachschicht: kein Netz, keine Secrets,
#         keine Platzhalter (§13).
#   - V2/V3/V5, sobald die jeweiligen Dateien vorhanden sind. Damit ist der
#         Test ab V4 lauffähig und wird mit den späteren WPs vollständig
#         (§13, §14). Fehlende spätere WPs werden als `skip` gemeldet, nicht
#         als bestanden.
#
# Warum statisch: Auf diesem Prüfstand gibt es keine Swift-Toolchain; die
# übrigen WP-Abnahmen laufen ebenfalls über grep-/Dateiprüfungen.
#
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$root"

fail=0

pass() { echo "ok:   $1"; }
fail_check() { echo "FAIL: $1"; fail=1; }
skip() { echo "skip: $1"; }

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

# Zählt Treffer rekursiv; 0 ist ein gültiges Ergebnis, kein Fehler.
count_matches() {
    local pattern="$1"
    local path="$2"
    grep -rInE "$pattern" "$path" 2>/dev/null | wc -l | tr -d ' ' || true
}

# Prüft, ob ein Build-Setting in genau einer der beiden App-Konfigurationen
# steht. XCBuildConfiguration-Blöcke enden mit ihrer `name = ...;`-Zeile.
setting_in_configuration() {
    local key="$1"
    local configuration="$2"
    awk -v key="$key" -v configuration="$configuration" '
        /isa = XCBuildConfiguration;/ { block = "" }
        { block = block $0 "\n" }
        /name = (Debug|Release);/ {
            if (index(block, key) > 0 && index(block, "name = " configuration ";") > 0) {
                found = 1
            }
            block = ""
        }
        END { exit(found ? 0 : 1) }
    ' "$pbx"
}

pbx="Planer.xcodeproj/project.pbxproj"
permissions="Planer/Voice/VoicePermissions.swift"
texts="Planer/Voice/VoicePrivacyTexts.swift"
voice="Planer/Voice"

# --- V4: die fünf binären Kriterien aus §2 --------------------------------

mic_key="INFOPLIST_KEY_NSMicrophoneUsageDescription"
speech_key="INFOPLIST_KEY_NSSpeechRecognitionUsageDescription"

mic_count="$(grep -cE "$mic_key" "$pbx" || true)"
if [[ "$mic_count" -ge 2 ]]; then
    pass "K1: $mic_key kommt ≥ 2-mal vor ($mic_count)"
else
    fail_check "K1: $mic_key kommt ≥ 2-mal vor (gefunden: $mic_count)"
fi

speech_count="$(grep -cE "$speech_key" "$pbx" || true)"
if [[ "$speech_count" -ge 2 ]]; then
    pass "K2: $speech_key kommt ≥ 2-mal vor ($speech_count)"
else
    fail_check "K2: $speech_key kommt ≥ 2-mal vor (gefunden: $speech_count)"
fi

for configuration in Debug Release; do
    if setting_in_configuration "$mic_key" "$configuration"; then
        pass "K1: $mic_key steht in $configuration"
    else
        fail_check "K1: $mic_key fehlt in $configuration"
    fi
    if setting_in_configuration "$speech_key" "$configuration"; then
        pass "K2: $speech_key steht in $configuration"
    else
        fail_check "K2: $speech_key fehlt in $configuration"
    fi
done

mic_api_hits="$(count_matches 'AVAudioApplication\.(requestRecordPermission|shared\.recordPermission)' "$voice")"
if [[ "$mic_api_hits" -ge 1 ]]; then
    pass "K3: Mikrofon-Freigabe nutzt AVAudioApplication ($mic_api_hits Treffer)"
else
    fail_check "K3: Mikrofon-Freigabe nutzt AVAudioApplication (gefunden: $mic_api_hits)"
fi

speech_api_hits="$(count_matches 'SFSpeechRecognizer\.requestAuthorization' "$voice")"
if [[ "$speech_api_hits" -ge 1 ]]; then
    pass "K4: Erkennungs-Freigabe nutzt SFSpeechRecognizer.requestAuthorization ($speech_api_hits Treffer)"
else
    fail_check "K4: Erkennungs-Freigabe nutzt SFSpeechRecognizer.requestAuthorization (gefunden: $speech_api_hits)"
fi

deprecated_hits="$(count_matches 'AVAudioSession\.requestRecordPermission' Planer)"
if [[ "$deprecated_hits" -eq 0 ]]; then
    pass "K5: die abgekündigte Mikrofon-API kommt app-weit nicht vor"
else
    fail_check "K5: die abgekündigte Mikrofon-API kommt app-weit nicht vor (gefunden: $deprecated_hits)"
fi

# --- V4: wortwörtliche Texte (§5) -----------------------------------------

mic_text='Planer benötigt das Mikrofon, um Ihre Diktate aufzunehmen. Die Aufnahme wird auf diesem Gerät ausgewertet und nicht an einen Server übertragen.'
speech_text='Planer wandelt Ihre gesprochenen Sätze auf diesem Gerät in Text um. Die Erkennung läuft ohne Netz auf dem Gerät; ohne deutsche On-Device-Erkennung bietet die App kein Diktat an.'

mic_text_count="$(grep -cF "$mic_key = \"$mic_text\";" "$pbx" || true)"
if [[ "$mic_text_count" -eq 2 ]]; then
    pass "§5: Mikrofon-Freigabetext steht wortgleich in Debug und Release"
else
    fail_check "§5: Mikrofon-Freigabetext steht wortgleich in Debug und Release (gefunden: $mic_text_count)"
fi

speech_text_count="$(grep -cF "$speech_key = \"$speech_text\";" "$pbx" || true)"
if [[ "$speech_text_count" -eq 2 ]]; then
    pass "§5: Erkennungs-Freigabetext steht wortgleich in Debug und Release"
else
    fail_check "§5: Erkennungs-Freigabetext steht wortgleich in Debug und Release (gefunden: $speech_text_count)"
fi

if grep -qF "$mic_text" "$texts"; then
    pass "§5: VoicePrivacyTexts wiederholt den Mikrofon-Text wortgleich"
else
    fail_check "§5: VoicePrivacyTexts wiederholt den Mikrofon-Text wortgleich ($texts)"
fi

if grep -qF "$speech_text" "$texts"; then
    pass "§5: VoicePrivacyTexts wiederholt den Erkennungs-Text wortgleich"
else
    fail_check "§5: VoicePrivacyTexts wiederholt den Erkennungs-Text wortgleich ($texts)"
fi

require "VoicePrivacyTexts nennt die Mikrofon-Konstante" \
    'static let mikrofonFreigabe' "$texts"
require "VoicePrivacyTexts nennt die Erkennungs-Konstante" \
    'static let spracherkennungFreigabe' "$texts"
require "VoicePrivacyTexts enthält den Hinweis ohne On-Device-Diktat" \
    'static let diktatNichtMoeglich' "$texts"

# --- V4: Freigabe-Helfer (§11) --------------------------------------------

require "VoicePermissionStatus existiert" \
    'enum VoicePermissionStatus: Equatable' "$permissions"
require "Status kennt nichtGefragt" 'case nichtGefragt' "$permissions"
require "Status kennt erlaubt" 'case erlaubt' "$permissions"
require "Status kennt verweigert" 'case verweigert' "$permissions"
require "VoicePermissions.requestSpeechRecognition existiert" \
    'static func requestSpeechRecognition\(\) async -> VoicePermissionStatus' "$permissions"
require "VoicePermissions.requestMicrophone existiert" \
    'static func requestMicrophone\(\) async -> VoicePermissionStatus' "$permissions"
require "VoicePermissions.microphoneStatus existiert" \
    'static var microphoneStatus: VoicePermissionStatus' "$permissions"
require "requestMicrophone nutzt AVAudioApplication.requestRecordPermission" \
    'AVAudioApplication\.requestRecordPermission' "$permissions"
require "microphoneStatus liest AVAudioApplication.shared.recordPermission" \
    'AVAudioApplication\.shared\.recordPermission' "$permissions"
require "requestSpeechRecognition nutzt SFSpeechRecognizer.requestAuthorization" \
    'SFSpeechRecognizer\.requestAuthorization' "$permissions"

# --- §13: Datenschutz-Invarianten der Sprachschicht -----------------------

network_hits="$(count_matches 'URLSession|NetworkClient|MCPClient' "$voice")"
if [[ "$network_hits" -eq 0 ]]; then
    pass "§13: kein Netzwerkcode in Planer/Voice"
else
    fail_check "§13: kein Netzwerkcode in Planer/Voice (gefunden: $network_hits)"
fi

secret_hits="$(count_matches 'Keychain|token|secret' "$voice")"
if [[ "$secret_hits" -eq 0 ]]; then
    pass "§13: kein Secret/Keychain in Planer/Voice"
else
    fail_check "§13: kein Secret/Keychain in Planer/Voice (gefunden: $secret_hits)"
fi

placeholder_hits="$(count_matches 'TBD|TODO|FIXME' "$voice")"
if [[ "$placeholder_hits" -eq 0 ]]; then
    pass "§13: keine Platzhalter in Planer/Voice"
else
    fail_check "§13: keine Platzhalter in Planer/Voice (gefunden: $placeholder_hits)"
fi

# --- V2: On-Device-Erkennung erzwungen (§4) -------------------------------

recognizer="Planer/Voice/SpeechRecognizerService.swift"
if [[ -f "$recognizer" ]]; then
    require "V2: requiresOnDeviceRecognition wird immer gesetzt" \
        'requiresOnDeviceRecognition = true' "$recognizer"
    require "V2: supportsOnDeviceRecognition wird geprüft" \
        'supportsOnDeviceRecognition' "$recognizer"
else
    skip "V2: SpeechRecognizerService.swift noch nicht vorhanden"
fi

# --- V3: Zustandsautomat, Nahtstellen, freihändig (§8, §13) ---------------

state="Planer/Voice/VoiceState.swift"
coordinator="Planer/Voice/VoiceCoordinator.swift"

if [[ -f "$state" && -f "$coordinator" ]]; then
    for voice_state in stumm hoerend sprechend fehler; do
        require "V3: VoiceState kennt .$voice_state" \
            "case $voice_state" "$state"
    done
    require "V3: jeder Übergang läuft über transition(to:)" \
        'func transition\(to:' "$coordinator"
    require "V3: Nahtstelle ingestAssistantDelta existiert" \
        'func ingestAssistantDelta' "$coordinator"
    require "V3: Nahtstelle finishAssistantStream existiert" \
        'func finishAssistantStream' "$coordinator"
    require "V3: Nahtstelle stopSpeaking existiert" \
        'func stopSpeaking' "$coordinator"
    require "V3: freihändig ist in der Sprachschicht benannt" \
        'handsFree' "$coordinator"
    require "V3: PlanerApp gibt scenePhase an den Koordinator" \
        'handleScenePhase' Planer/App/PlanerApp.swift
    require "V3: ChatView bindet die Sprachleiste ein" \
        'VoiceControlBar\(' Planer/Features/Chat/ChatView.swift
    require "V3: TodosView bietet Vorlesen an" \
        'ReadAloudButton\(' Planer/Features/Todos/TodosView.swift
    require "V3: SettingsView bindet die Sprach-Sektion ein" \
        'VoiceSettingsSection\(' Planer/Settings/SettingsView.swift
else
    skip "V3: VoiceState.swift/VoiceCoordinator.swift noch nicht vorhanden"
fi

# --- V5: Router und Messprotokoll (§7, §13) -------------------------------

router="Planer/Voice/ModelRouter.swift"
if [[ -f "$router" ]]; then
    require "V5: Router kennt hermesWithLocalFallback" \
        'hermesWithLocalFallback' "$router"
    require "V5: Router kennt connectTimeout" \
        'connectTimeout' "$router"
    if [[ -f "Tests/voice-model-benchmark.md" ]]; then
        pass "V5: Messprotokoll Tests/voice-model-benchmark.md liegt vor"
    else
        fail_check "V5: Messprotokoll Tests/voice-model-benchmark.md fehlt"
    fi
else
    skip "V5: ModelRouter.swift noch nicht vorhanden"
fi

# --- V3/V5: Herkunft der Antwort ist markiert (§7) ------------------------

if grep -qE 'case engine' Planer/Features/Chat/ChatStreamProvider.swift 2>/dev/null; then
    engine_hits="$(count_matches 'Entry\.engine' Planer/Features/Chat)"
    if [[ "$engine_hits" -ge 1 ]]; then
        pass "§13: die Herkunft der Antwort ist am Chat-Eintrag markiert"
    else
        fail_check "§13: die Herkunft der Antwort ist am Chat-Eintrag markiert"
    fi
else
    skip "V3/V5: ChatStreamProvider kennt noch keinen engine-Fall"
fi

if [[ "$fail" -ne 0 ]]; then
    echo "Ergebnis: FEHLGESCHLAGEN"
    exit 1
fi

echo "Ergebnis: OK"
