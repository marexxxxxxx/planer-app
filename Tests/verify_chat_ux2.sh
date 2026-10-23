#!/usr/bin/env bash
#
# Statische Abnahme der vier Leistungen aus CH3 (MARAAA-171)
# (spec-chat Rev 7 Delta §7.2/§7.3, Entscheidungen A1-A7).
#
# Geprüft werden Dateien, Symbole, Zeilenreihenfolgen, Aufrufe und Zählungen —
# keine Swift-Toolchain, keine Kompilierung, kein Netz, kein Aufruf anderer
# Tests.
#
#   bash Tests/verify_chat_ux2.sh [copy|approval|phase|status|background|handover|all]
#
# `status` ist der im Auftrag (MARAAA-173) genannte Name des Abschnitts `phase`;
# beide Wörter wählen dieselbe Prüfung. `phase` ist der Name aus §7.2.
#
# Exit-Status: 0 = alle Prüfungen des Abschnitts grün, 1 = mindestens eine rot,
# 2 = falscher Aufruf. Der Status stammt aus `fail`, nie aus einem `echo`.
#
# Die Prüfnummern (K/F/P/B/X) sind die der Testmatrix §7.3. Die dort genannte
# Probe M1–M20 aus §7.4 macht den zugehörigen Abschnitt rot; die
# Mutationsmatrix steht im Bericht zu MARAAA-173.
#
# Nachtrag R-CH4 (MARAAA-176): K22a/K22b/K23a–c, F55–F59, P25/P26 und B28–B30 sind
# die Regressionen zu den Befunden F1–F4 aus G-CH3. Sie prüfen den **Rumpf**
# (Handler, Karte, Verzweigung), nicht die Datei — die Mutationsmatrix dazu
# steht im Bericht zu MARAAA-176.
#
# Nachtrag Rev 9 (MARAAA-188): B31–B42 prüfen den Wiederanlauf nach der
# Rückkehr aus dem Hintergrund (Schonfrist, abgebrochener toter Strom,
# sichtbarer Wiederholweg über `offersHistoryReload`). Sie ändern keine der
# Prüfungen B1–B30.
#
# Nachtrag Runde 2 (MARAAA-188, Review-Befunde 1–4 + 7):
# B31/B34/B35/B42 sind auf **dieselbe Zusage** umformuliert, weil die
# Umsetzung sich geändert hat — nicht abgeschwächt:
#   B31  vorher „5 s“ (eine Zahl), in Runde 2 ein Bereich 10–15 s; seit
#        Runde 3 wieder exakt: der beschlossene Wert 12 s ist gepinnt (V3f).
#   B34  vorher „abgebrochen und abgewartet“ via `await runningTask.value`,
#        jetzt „abgebrochen und **begrenzt** abgewartet“ (E3) plus das Verbot
#        des unbegrenzten Wartens — dieselbe Zusage, härter geprüft. Runde 3
#        pinnt zusätzlich `runningTask?.cancel()` (V3d).
#   B35  vorher `streamEventCount == seenEvents`, jetzt das Lebenszeichen aus
#        **beiden** Zählern (`resumeLiveness`), verglichen in der Schleife.
#   B42  vorher „die Frist wird neu gestellt“ (Aufruf von
#        `scheduleResumeWatchdog`), jetzt „die Runde läuft weiter“ (`continue`)
#        — die Schleife hat keinen zweiten Task mehr, den man neu stellen
#        könnte; die Zusage („eine wartende Freigabe bricht nicht ab“) bleibt.
#   B12  vorher die Signatur `func reconcileAfterBackground() async`, jetzt der
#        benannte Pfad **mit** Parameter und `async` — E1 braucht den Schalter
#        `announcesResume`; die Zusage („es gibt **einen** benannten Pfad“)
#        bleibt. Runde 3 pinnt die vollständige Signatur (V3e).
#   B15  vorher `if notice == nil`, jetzt `if announcesResume, notice == nil` —
#        dieselbe Zusage („der Hinweis überschreibt keine Fehlermeldung“).
# Neu sind B43a–B47 (ehrlicher Ausgang, begrenztes Warten und hartes Schließen,
# kontinuierlicher Watchdog mit Zeilenzähler, Info-Optik in `emptyState` und
# `SessionListView`, `reloadHistory`-Wiederangebot). Die frühere Angabe
# „B43–B52“ in diesem Kopf und in der Commit-Nachricht von 7e24979 war falsch:
# B48–B52 existierten in Runde 2 nicht (keine Nummer ohne Prüfung, V4).
#
# Nachtrag R-CH10 (MARAAA-192, Review-Befunde 1–3 aus G-CH11): B48a–B48j
# binden den Turn-Riegel an eine Generation (`turnGeneration`,
# `abandonedGeneration`), prüfen den Reset in `send()` und die Verwendung von
# `configuration.backgroundResumeGracePeriod` im Watchdog. Damit sind die
# beiden Testlücken aus MARAAA-189 (Mutationen M11/M12) geschlossen und der
# verspätete `run` aus Befund 1 ist statisch abgedeckt; Rot-Belege im Bericht
# zu MARAAA-192.
#
# Nachtrag Runde 3 (MARAAA-188, Review-Befunde A1/V1–V6): Die Prüfungen B12,
# B31, B34a, B42, B43g und B45d prüfen jetzt die **Zusage im Rumpf** statt nur
# ein Wort in der Nachbarschaft. Jede ist durch die im Bericht genannte
# Mutation rot belegt. B42 gilt nur noch für eine **entscheidbare** Freigabe
# (`.open`/`acceptsDecision`); `.expired` endet im Abbruch-Pfad mit eigenem
# Wortlaut (`backgroundApprovalExpiredNotice`). B31 pinnt den beschlossenen
# Wert exakt statt eines Bereichs (Runde 3: 12 s).
#
# Nachtrag Runde 4 (MARAAA-188, Review-Befunde W1–W4): B49a–B49e schließen die
# letzten unbewachten Stellen der A1-Verdrahtung. Geprüft wird der **Aufruf**
# von `abandonDeadStreamIfNeeded` im Rumpf von `scheduleResumeWatchdog` (W1),
# das Argument `approvalExpired: self.hasExpiredApproval` und die Textauswahl
# im Abbruch-Pfad (W2), die Reihenfolge `cancel()` **vor** `await
# waitForTurnStop()` (W3) und der erneute Generationsriegel nach dem
# Nachladen, bevor Text und Wiederholweg geschrieben werden (W4). Die
# Mutationsmatrix steht im Bericht zu MARAAA-188 Runde 4.
#
# Nachtrag R-CH11 (MARAAA-196, Entscheidung MARAAA-193): B31 pinnt jetzt den
# exakten Wert 25 s (10-s-Keepalive × 2 + Reserve) statt 12 s; B48i/B48j
# binden weiterhin die Verwendungsstelle. Rot-Beleg: `= 12` in
# `ChatConfiguration.swift` ⇒ B31 rot.
#
# Nachtrag R-CH12 (MARAAA-198, minor-Befund 1 aus G-CH12/MARAAA-194): B50a–B50e
# binden die beiden Ausstiegspfade von `merge`, die nicht über den
# Post-`await`-Guard liefen (`await loadSessions()`, `catch` → `.failed`), und
# den `notice`-Schreibpfad des Aufrufers nach dem Merge. Geprüft wird die
# Reihenfolge im Rumpf, nicht ein Vorkommen in der Datei. Rot-Belege im Bericht
# zu MARAAA-198: Guard nach `loadSessions()` entfernt ⇒ B50a, Guard im `catch`
# entfernt ⇒ B50b/B50c, Guard in `streamTurn` entfernt ⇒ B50e.
#
# Abweichung von §7.3, begründet: X1 verlangt „`300` genau 1 Treffer in $cfg“.
# Am Ist-Code steht `300` zweimal in `ChatConfiguration.swift` — Zeile 59
# (`approvalTimeout`) und Zeile 68 (`maxNoticeCharacters`, unverändert aus
# Rev 5). Ein Zähler auf die nackte Zahl wäre gegen den korrekten Baum rot.
# Geprüft wird deshalb die **Definition** der beiden neuen Zahlen: je genau
# eine Deklarationszeile (X1a/X1b). Die Nullaussage „keine Magic Number in
# der Oberfläche“ bleibt unverändert (X2).
#
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$root"

chat="Planer/Features/Chat"
vm="$chat/ChatViewModel.swift"
view="$chat/ChatView.swift"
cfg="$chat/ChatConfiguration.swift"
slv="$chat/SessionListView.swift"
prov="$chat/ChatStreamProvider.swift"
chips="$chat/ToolConfirmationChips.swift"
card="$chat/ToolCallCard.swift"
phase="$chat/ApprovalPhase.swift"
phaseView="$chat/ChatPhaseStatusView.swift"
api="$chat/HermesChatAPI.swift"
clip="Planer/DesignSystem/Components/TextClipboard.swift"
bubble="Planer/DesignSystem/Components/MessageBubbleView.swift"
planerapp="Planer/App/PlanerApp.swift"
net="Planer/Networking/NetworkClient.swift"

fail=0

pass() { echo "ok:   $1"; }
bad()  { echo "FAIL: $1"; fail=1; }

need() { if grep -qE "$2" "$1"; then pass "$3"; else bad "$3  [$1 ~ /$2/]"; fi; }
need_fixed() { if grep -qF "$2" "$1"; then pass "$3"; else bad "$3  [$1 = $2]"; fi; }
ban() { if grep -qE "$2" "$1"; then bad "$3  [$1 ~ /$2/]"; else pass "$3"; fi; }
ban_fixed() { if grep -qF "$2" "$1"; then bad "$3  [$1 = $2]"; else pass "$3"; fi; }
file_required() { if [[ -f "$1" ]]; then pass "Datei: $1"; else bad "Datei fehlt: $1"; fi; }

# `grep -c` endet bei 0 Treffern mit Status 1; unter `pipefail` darf das den
# Zähler nicht verfälschen. Deshalb erst den Status schlucken, dann zählen.
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

# Abschnitt einer Datei: von der Zeile, die $2 enthält, bis zur ersten Zeile,
# die $3 enthält (beide Grenzen eingeschlossen). Grenzen sind **wörtlich** und
# werden mit index() verglichen — ein Regex würde bei jedem `\(` in awk
# warnen und die Grenze unschärfer machen.
section() {
    awk -v s="$2" -v e="$3" '!f && index($0, s) > 0 { f=1 } f { print; if (index($0, e) > 0) exit }' "$1"
}

# Abschnitt erst in eine Variable, dann prüfen. `section ... | grep -q` ist
# unter `pipefail` nicht deterministisch: beendet `grep -q` nach dem ersten
# Treffer, bekommt `awk` beim nächsten Schreibblock SIGPIPE (Status 141) und
# die Pipeline gilt als rot, obwohl der Treffer da war. Die Zwischenvariable
# nimmt den SIGPIPE aus dem Spiel.
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

# Reihenfolge zweier wörtlicher Marken **innerhalb** eines Abschnitts: grün
# nur, wenn beide vorkommen und $5 nach $4 steht. Genau das unterscheidet
# „Zustand vor dem Aufruf gesetzt“ von „irgendwo im Rumpf erwähnt“.
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
# Verschachtelungstiefe. Gezählt werden `{` und `}` je Zeile. Damit prüft eine
# Aussage „im Rumpf von X“ und nicht „irgendwo in der Datei“ — bei F1 ist genau
# das der Unterschied zwischen „synchron im Handler“ und „im Hop daneben“.
# Voraussetzung: die geprüften Rümpfe führen keine Klammern in Zeichenketten
# (Kommentare dürfen das Wort `Task` enthalten, aber kein `{` danach).
# Reihenfolge **mehrerer** wörtlicher Marken innerhalb eines Abschnitts: grün
# nur, wenn sie in genau dieser Reihenfolge vorkommen. Anders als
# `section_order` wird die nächste Marke erst **nach** der vorigen gesucht —
# eine frühere Fundstelle (etwa ein Guard am Funktions-Eintritt) kann die
# Prüfung damit nicht ausgleichen. Marken werden mit `::` getrennt.
section_sequence() {
    local file="$1" start="$2" end="$3" label="$4" marks="$5" body
    body="$(section "$file" "$start" "$end")"
    if awk -v marks="$marks" '
        BEGIN { n = split(marks, m, "::"); want = 1 }
        want <= n && index($0, m[want]) > 0 { want++ }
        END { exit !(want > n) }' <<<"$body"; then
        pass "$label"
    else
        bad "$label  [$file, Abschnitt /$start/../$end/: Reihenfolge »$marks« nicht gefunden]"
    fi
}

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

# Muster kommt unter `Planer/` vor, aber in keiner der genannten Dateien.
# Die ausgeschlossenen Pfade werden **wörtlich** samt `:` gefiltert, damit
# kein Regex-Zeichen im Pfad (Punkt, Klammer) die Grenze verschiebt.
ban_outside() {
    local pattern="$1" label="$2"
    shift 2
    local hits ex
    hits="$(grep -rInE "$pattern" Planer/ --include='*.swift' 2>/dev/null || true)"
    for ex in "$@"; do
        hits="$(grep -vF "$ex:" <<<"$hits" || true)"
    done
    if [[ -z "${hits//[[:space:]]/}" ]]; then
        pass "$label"
    else
        bad "$label  [Treffer außerhalb: $(head -1 <<<"$hits")]"
    fi
}

# Muster steht **in** $1 und nirgends sonst unter `Planer/` — die schärfere
# Form von „genau eine Stelle“: Vorhandensein und Ausschließlichkeit in einem.
need_outside() {
    local file="$1" pattern="$2" label="$3"
    need "$file" "$pattern" "$label (vorhanden)"
    ban_outside "$pattern" "$label (nur hier)" "$file"
}

ban_tree() {
    local pattern="$1" label="$2" dir="${3:-$chat}" hits
    hits="$(grep -rInE "$pattern" "$dir" --include='*.swift' 2>/dev/null | wc -l | tr -d ' ' || true)"
    if [[ "${hits:-0}" -eq 0 ]]; then
        pass "$label"
    else
        bad "$label (Treffer: $hits)"
    fi
}

# ---------------------------------------------------------------------------
# (a) Kopieren — §7.3.1, K1–K21
# ---------------------------------------------------------------------------
copy_section() {
    echo "--- (a) Kopieren: eine Stelle, kein Netz, leerer Text ohne Aktion"

    file_required "$clip"
    need "$clip" 'enum TextClipboard' \
        "K2  TextClipboard ist der benannte Ort der Zwischenablage"
    need "$clip" 'static func copy\(_ text: String\?\) -> Bool' \
        "K3  copy nimmt optionalen Text und meldet Erfolg"
    need_fixed "$clip" 'UIPasteboard.general.string = trimmed' \
        "K4  geschrieben wird der getrimmte Text"
    exactly "$clip" 'UIPasteboard' 1 \
        "K5  genau ein Zugriff auf die Zwischenablage in der Datei"
    need_fixed "$clip" 'guard isCopyable(text), let text else { return false }' \
        "K6  der Riegel steht vor dem Schreiben"
    need "$clip" 'return !text\.trimmingCharacters\(in: \.whitespacesAndNewlines\)\.isEmpty' \
        "K6b isCopyable misst den getrimmten Text, nicht den rohen"
    at_least "$clip" 'trimmingCharacters\(in: \.whitespacesAndNewlines\)' 2 \
        "K7  getrimmt wird an beiden Stellen (Riegel und Schreiben)"
    need_fixed "$clip" 'static let announcement = "Kopiert"' \
        "K8  die Ansage steht wörtlich"
    need "$clip" 'AccessibilityNotification\.Announcement\(TextClipboard\.announcement\)\.post\(\)' \
        "K9  die Ansage wird nach dem Schreiben gepostet"
    need "$clip" 'func copyableText\(_ text: String\?\) -> some View' \
        "K10 copyableText ist ein View-Modifier"
    need "$clip" 'func copyableAction\(_ text: String\?\) -> some View' \
        "K11 copyableAction ist ein View-Modifier (ohne Kontextmenü)"
    need_fixed "$clip" 'Button("Kopieren")' \
        "K12 der Kontextmenü-Eintrag heißt „Kopieren“"
    at_least "$clip" '\.accessibilityAction\(named: Text\("Kopieren"\)\)' 2 \
        "K13 beide Modifier tragen die benannte VoiceOver-Aktion"
    ban "$clip" 'URLSession|NetworkClient|HermesChatAPI' \
        "K14 Kopieren ist lokal — kein Netzwerkpfad in der Datei"
    need_fixed "$bubble" '.copyableText(text)' \
        "K15 die Blase hängt die Kopier-Affordanz an ihren Text"
    section_order "$bubble" 'var body' '#Preview' '.accessibilityLabel' '.copyableText(text)' \
        "K16 das Label steht vor der Kopier-Affordanz (VoiceOver liest den Text)"
    need_fixed "$view" '.copyableAction(entry.approval?.command)' \
        "K17 der Befehl der Freigabe ist kopierbar"
    need_fixed "$view" 'Button("Befehl kopieren")' \
        "K18 der Befehl hat einen eigenen Kopier-Knopf"
    need_fixed "$card" '.copyableAction(value)' \
        "K19 Werkzeug-Argumente und -Ergebnis sind kopierbar"
    ban_outside 'UIPasteboard' \
        "K20 UIPasteboard kommt nur in TextClipboard vor" "$clip"
    ban "$bubble" 'textSelection' \
        "K21 die Blase behält das Kontextmenü statt des Systemmenüs"

    # --- F3 (R-CH4): die Prüfung ist privat, die Modifier liegen im enum ----
    # `private` an einem Typ-Member ist nur innerhalb der Deklaration sichtbar.
    # Die beiden Modifier müssen deshalb Geschwister von `isCopyable` sein —
    # stünden sie auf Dateiebene, wäre die Prüfung entweder unerreichbar oder
    # wieder `fileprivate`.
    # `grep -F 'private static func …'` waere hier falsch: die Zeichenfolge
    # steckt auch in `fileprivate static func …`. Beide Muster sind deshalb auf
    # den Zeilenanfang bzw. eine Nicht-Buchstaben-Grenze verankert; die Probe
    # »private -> fileprivate« belegt, dass sie den Unterschied sehen.
    need "$clip" '^[[:space:]]*private[[:space:]]+static[[:space:]]+func[[:space:]]+isCopyable' \
        "K22a isCopyable ist private, nicht fileprivate (F3)"
    ban "$clip" '^[[:space:]]*fileprivate[[:space:]]+static[[:space:]]+func[[:space:]]+isCopyable' \
        "K22b es gibt keine fileprivate Deklaration von isCopyable mehr (F3)"
    block_has "$clip" 'enum TextClipboard' 'struct CopyableTextModifier: ViewModifier' \
        "K23a der Kontextmenü-Modifier liegt im enum — sonst ist private unerreichbar (F3)"
    block_has "$clip" 'enum TextClipboard' 'struct CopyableActionModifier: ViewModifier' \
        "K23b der Aktions-Modifier liegt im enum — sonst ist private unerreichbar (F3)"
    # Kontrolle gegen ein ins Leere greifendes Rumpf-Muster: derselbe Schnitt
    # muss die private Prüfung wirklich enthalten. Die Grenze `[^A-Za-z]` hält
    # `fileprivate` draußen.
    block_has "$clip" 'enum TextClipboard' '[^A-Za-z]private[[:space:]]+static[[:space:]]+func[[:space:]]+isCopyable' \
        "K23c (Kontrolle: der enum-Rumpf enthält die private Prüfung)"
}

# ---------------------------------------------------------------------------
# (b) Befehls-Freigabe — §7.3.2, F1–F54
# ---------------------------------------------------------------------------
approval_section() {
    echo "--- (b) Befehls-Freigabe: sechs Zustände, zwei Choices, ein POST"

    file_required "$phase"
    need_fixed "$phase" 'enum ApprovalPhase: Equatable, Sendable' \
        "F2  ApprovalPhase ist der benannte Zustand"
    exactly "$phase" '^ *case (open|sending|executed|denied|expired|conflict)$' 6 \
        "F3  genau sechs Zustände, keine mehr"
    need_fixed "$phase" 'case .open: return "Offen"' \
        "F4  Text „Offen“ wörtlich"
    need_fixed "$phase" 'case .sending: return "Wird gesendet …"' \
        "F5  Text „Wird gesendet …“ wörtlich"
    need_fixed "$phase" 'case .executed: return "Ausgeführt"' \
        "F6  Text „Ausgeführt“ wörtlich"
    need_fixed "$phase" 'case .denied: return "Abgelehnt"' \
        "F7  Text „Abgelehnt“ wörtlich"
    need_fixed "$phase" 'case .expired: return "Abgelaufen"' \
        "F8  Text „Abgelaufen“ wörtlich"
    need_fixed "$phase" 'case .conflict: return "Nicht mehr aktiv"' \
        "F9  Text „Nicht mehr aktiv“ wörtlich"
    need_fixed "$phase" 'var acceptsDecision: Bool { self == .open }' \
        "F10 nur aus .open darf entschieden werden"
    need "$phase" 'var waitsForUser: Bool' \
        "F11 waitsForUser ist ein eigener Begriff"
    need_fixed "$phase" 'static func derive(stored: ApprovalPhase, receivedAt: Date?, timeout: TimeInterval, now: Date) -> ApprovalPhase' \
        "F12 die Frist wird abgeleitet, nicht gespeichert"
    need "$phase" 'return \.expired' \
        "F13 die Ableitung kennt den Ablauf"
    need_fixed "$cfg" 'var approvalTimeout: TimeInterval = 300' \
        "F14 die Frist ist konfiguriert (300 s)"
    need_fixed "$cfg" 'var maxCommandCharacters = 12_000' \
        "F15 die Befehls-Obergrenze ist konfiguriert (12 000)"
    ban "$view" 'lineLimit\(3\)' \
        "F16 der Befehl wird vollständig gerendert (A1)"
    need "$view" 'confirmationDialog\(' \
        "F17 die Bestätigung ist ein Dialog"
    need_fixed "$view" 'Button("Ausführen", role: .destructive)' \
        "F18 der Ausführen-Knopf ist als destruktiv markiert"
    need_fixed "$view" 'Button("Abbrechen", role: .cancel)' \
        "F19 der Abbrechen-Knopf ist der Cancel-Knopf"
    need "$view" 'titleVisibility: \.visible' \
        "F20 der Dialogtitel ist sichtbar"
    need "$view" 'approvalCommand\(for:' \
        "F21 der Dialog zeigt den vollständigen Befehl als message"
    need "$view" 'Text\(approval\.runID\)' \
        "F22 die Run-ID steht als Text auf der Karte"
    need "$view" 'truncationMode\(\.middle\)' \
        "F23 die Run-ID wird mittig gekürzt"
    need_fixed "$view" 'vom Server nicht benannt' \
        "F24 fehlender Werkzeugname hat einen Text"
    need_fixed "$view" 'Keine Beschreibung vom Server.' \
        "F25 fehlende Beschreibung hat einen Text"
    need "$view" 'approvalTimeoutSeconds' \
        "F26 die Frist steht als Hinweis in der Oberfläche"
    need "$view" 'TimelineView\(\.periodic\(from:' \
        "F27 die Karte rechnet den Ablauf ohne Nutzeraktion nach"
    ban "$view" 'approveSession|"session"' \
        "F28 „session“ wird nie als Choice angeboten"
    need_fixed "$chips" 'let phase: ApprovalPhase' \
        "F29 die Chips lesen den benannten Zustand"
    need_fixed "$chips" 'let allowsExecute: Bool' \
        "F30 die Chips kennen die Ausführbarkeit"
    need_fixed "$chips" 'let onRequestExecute: () -> Void' \
        "F31 die Chips fragen die Ausführung an, statt sie zu tun"
    need "$chips" 'canApproveOnce' \
        "F32a der Server-Riegel canApproveOnce ist beachtet"
    need "$chips" 'canDeny' \
        "F32b der Server-Riegel canDeny ist beachtet"
    need_fixed "$chips" 'Keine ausführbare Auswahl.' \
        "F33 ohne Choice steht ein Text statt eines leeren Bereichs"
    need_fixed "$vm" 'var approvalPhase: ApprovalPhase = .open' \
        "F34 der gespeicherte Startzustand ist .open"
    need_fixed "$vm" 'var approvalReceivedAt: Date?' \
        "F35 die Empfangszeit ist optional gespeichert"
    need_fixed "$vm" 'var approvalToolName: String?' \
        "F36 der Werkzeugname ist optional gespeichert"
    need_fixed "$vm" 'var approvalCommandTooLong: Bool = false' \
        "F37 die Obergrenze ist als Merker gespeichert"
    need_fixed "$vm" 'var approvalResolved: Bool { !approvalPhase.waitsForUser }' \
        "F38 „erledigt“ ist berechnet, nicht gesetzt"
    ban "$vm" 'approvalResolved: Bool = false' \
        "F39 es gibt keinen gespeicherten Erledigt-Zustand mehr"
    need_fixed "$vm" 'entries[current].approvalPhase = .conflict' \
        "F40 der Server-Konflikt hat einen eigenen Zustand"
    section_lacks "$vm" '        catch {' '// MARK: Ablauf' '\.denied' \
        "F41 der Fehlerzweig behauptet nie „abgelehnt“"
    section_has "$vm" '        catch {' '// MARK: Ablauf' '\.conflict' \
        "F42 der Fehlerzweig setzt den Konflikt"
    need_fixed "$vm" '"Freigabe nicht mehr aktiv."' \
        "F43 die Konfliktmeldung ist wörtlich (Rev 5 F14)"
    need_fixed "$vm" 'decidingApprovalEntryID == nil' \
        "F44 der Doppel-Tipp-Riegel steht im Riegel"
    section_order "$vm" 'func decideApproval(' 'try await api.respondToApproval' \
        '.sending' 'try await api.respondToApproval' \
        "F45 .sending steht vor dem await (sichtbarer Zwischenzustand)"
    exactly "$api" 'func respondToApproval' 1 \
        "F46 genau eine API-Methode für die Antwort"
    ban_outside 'respondToApproval' \
        "F47 respondToApproval wird nur von API und ViewModel genannt" "$api" "$vm"
    exactly "$view" 'decideApproval\(' 2 \
        "F48 genau zwei Aufrufstellen (einmal pro Choice)"
    exactly "$view" 'choice: \.once' 1 \
        "F49 genau ein once-Aufruf"
    exactly "$view" 'choice: \.deny' 1 \
        "F50 genau ein deny-Aufruf"
    need_fixed "$vm" 'func approvalCommand(for entryID: UUID) -> String?' \
        "F51 der Dialogtext kommt unverkürzt aus dem Modell"
    need_fixed "$vm" 'var approvalTimeoutSeconds: Int' \
        "F52 die Frist gelangt als Int in die View"
    need "$view" 'approvalPhase\.label' \
        "F53 die Kopfzeile zeigt den Zustandstext"
    ban "$view" '\.onAppear' \
        "F54 beim Erscheinen wird nichts still ausgeführt"

    # --- F3/F4 (R-CH4): eine Quelle für die Folge, deny endet auch die Karte -
    # Die Folge ist der beim Empfang gespeicherte `Entry.text` (§3.3.2, C5).
    # Ein zweiter Zugriff auf `approval.description` in der Karte wäre eine
    # zweite Quelle für denselben Satz.
    block_has "$view" 'private func approvalCard(for entry' 'Text\(entry\.text\)' \
        "F55 die Klartext-Folge liest den gespeicherten entry.text (F3)"
    block_lacks "$view" 'private func approvalCard(for entry' 'approval\?\.description' \
        "F56 die Karte greift nicht ein zweites Mal auf approval.description (F3)"
    block_has "$view" 'private func approvalCard(for entry' 'copyableText\(entry\.text\)' \
        "F57 die Kopier-Affordanz hängt am selben Text wie die Anzeige (F3)"
    # F4: `deny` beendet die Freigabe — auf der Karte wie auf den Chips.
    block_has "$vm" 'if choice == .once' 'toolStatus = \.denied' \
        "F58 deny setzt die Werkzeugkarte auf .denied (F4)"
    exactly "$vm" 'toolStatus = \.denied' 1 \
        "F59 genau eine Stelle setzt .denied — der catch-Zweig nicht (F4)"
}

# ---------------------------------------------------------------------------
# (c) Live-Status — §7.3.3, P1–P24
# ---------------------------------------------------------------------------
phase_section() {
    echo "--- (c) Live-Status: fünf Phasen, abgeleitet, ohne Animation"

    file_required "$phaseView"
    need_fixed "$phaseView" 'enum ChatTurnPhase: Equatable, Sendable' \
        "P2  ChatTurnPhase ist der benannte Phasenzustand"
    need_fixed "$phaseView" 'case connecting' "P3a Phase „verbindet“"
    need_fixed "$phaseView" 'case thinking' "P3b Phase „denkt nach“"
    need_fixed "$phaseView" 'case awaitingApproval' "P3c Phase „wartet auf Freigabe“"
    need_fixed "$phaseView" 'case writing' "P3d Phase „schreibt“"
    need_fixed "$phaseView" 'case tool(name: String)' \
        "P4  die Werkzeugphase trägt den Werkzeugnamen"
    need_fixed "$phaseView" 'case .connecting: return "Verbindet …"' \
        "P5  Text „Verbindet …“ wörtlich"
    need_fixed "$phaseView" 'case .thinking: return "Denkt nach …"' \
        "P6  Text „Denkt nach …“ wörtlich"
    need "$phaseView" 'case \.tool\(let name\): return "Werkzeug \\\(name\)"' \
        "P7  Text „Werkzeug <Name>“ wörtlich"
    need_fixed "$phaseView" 'case .awaitingApproval: return "Wartet auf Freigabe …"' \
        "P8  Text „Wartet auf Freigabe …“ wörtlich"
    need_fixed "$phaseView" 'case .writing: return "Schreibt …"' \
        "P9  Text „Schreibt …“ wörtlich"
    need_fixed "$phaseView" 'struct ChatPhaseStatusView: View' \
        "P10 die Zeile ist eine eigene View"
    need_fixed "$phaseView" 'init(phase: ChatTurnPhase)' \
        "P11 die View nimmt genau die Phase"
    need "$phaseView" '\.accessibilityElement\(children: \.ignore\)' \
        "P12 die Zeile ist ein Element, kein Textstückwerk"
    need "$phaseView" '\.accessibilityLabel\(Text\("Status: \\\(phase\.title\)"\)\)' \
        "P13 die Zeile hat ein eigenes Label"
    ban "$phaseView" 'withAnimation|\.transition\(|\.id\(' \
        "P14 kein animierter Wechsel, kein Flackern"
    need "$vm" 'var turnPhase: ChatTurnPhase\?' \
        "P15 die Phase ist ein optionaler, berechneter Wert"
    section_order "$vm" 'var turnPhase' 'var showsWorkingIndicator' \
        'return .awaitingApproval' 'return .tool(name:' \
        "P16a Freigabe hat Vorrang vor dem Werkzeug"
    section_order "$vm" 'var turnPhase' 'var showsWorkingIndicator' \
        'return .tool(name:' 'return .writing' \
        "P16b Werkzeug hat Vorrang vor dem Schreiben"
    section_order "$vm" 'var turnPhase' 'var showsWorkingIndicator' \
        'return .writing' 'return .connecting' \
        "P16c Schreiben hat Vorrang vor dem Verbinden"
    section_order "$vm" 'var turnPhase' 'var showsWorkingIndicator' \
        'return .awaitingApproval' 'return .writing' \
        "P16d Freigabe hat auch Vorrang vor dem Schreiben"
    section_has "$vm" 'var turnPhase' 'var showsWorkingIndicator' \
        'guard isStreaming else \{ return nil \}' \
        "P17 außerhalb eines Turns gibt es keine Phase"
    section_has "$vm" 'var turnPhase' 'var showsWorkingIndicator' 'streamStarted' \
        "P18 „verbindet“ hängt am ersten Ereignis, nicht an der Uhr"
    need "$vm" 'var showsWorkingIndicator: Bool' \
        "P19 die Arbeits-Animation bleibt unverändert vorhanden (O5)"
    need_fixed "$view" 'ChatPhaseStatusView(phase: phase)' \
        "P20 die Zeile wird mit der Phase gerendert"
    need "$view" 'if let phase = viewModel\.turnPhase' \
        "P21 gerendert wird nur eine vorhandene Phase"
    need_fixed "$view" 'private var phaseBar: some View' \
        "P21b die Zeile hat einen eigenen Platz im Baum"
    section_order "$view" 'var body: some View' 'private var statusBar' 'statusBar' 'phaseBar' \
        "P22 die Phasen-Zeile steht im Statusbereich"
    section_lacks "$view" 'private var transcript' '// MARK: Eingabe' 'ChatPhaseStatusView' \
        "P23 die Zeile liegt außerhalb des Scrollinhalts"
    ban "$phaseView" 'accessibilityReduceMotion' \
        "P24 es gibt keine Animation, die abzuschalten wäre (dokumentierte Nullaussage)"

    # --- F2 (R-CH4): der Phasenwechsel ist beobachtbar ----------------------
    # `turnPhase` leitet „verbindet“ aus `streamStarted` ab. Ohne Teilnahme an
    # `objectWillChange` bleibt die Zeile beim ersten Ereignis stehen, bis ein
    # anderer Wert das Objekt meldet — genau der unsichtbare Wechsel aus G-CH3.
    need_fixed "$vm" '@Published private(set) var streamStarted = false' \
        "P25 streamStarted ist @Published und von außen nur lesbar (F2)"
    ban "$vm" '^[[:space:]]*private var streamStarted([[:space:]]*=|:)' \
        "P26 es gibt keine unbeobachtbare Deklaration von streamStarted mehr (F2)"
}

# ---------------------------------------------------------------------------
# (d) Hintergrund — §7.3.4, B1–B27
# ---------------------------------------------------------------------------
background_section() {
    echo "--- (d) Hintergrund: ein Modell, ein Task, eine Reconciliation"

    need_fixed "$vm" 'static let shared = ChatViewModel()' \
        "B1  es gibt genau eine Instanz je Prozess"
    need_fixed "$view" '@ObservedObject private var viewModel = ChatViewModel.shared' \
        "B2  die View beobachtet das geteilte Modell"
    ban "$view" '@StateObject private var viewModel' \
        "B3  die View erzeugt das Modell nicht mehr (A6)"
    need "$vm" 'UIApplication\.didEnterBackgroundNotification' \
        "B4  der Hintergrund-Wechsel wird beobachtet"
    need "$vm" 'UIApplication\.willEnterForegroundNotification' \
        "B5  die Rückkehr wird beobachtet"
    at_least "$vm" 'Task \{ @MainActor in' 2 \
        "B6  je Beobachter ein Hop auf den Main-Actor"
    need_outside "$vm" 'UIApplication\.shared\.beginBackgroundTask\(withName: "chat-turn"\)' \
        "B7  genau eine Stelle bittet iOS um Zeit"
    need_fixed "$vm" 'UIApplication.shared.endBackgroundTask(backgroundTask)' \
        "B8  die Aufgabe wird wieder freigegeben"
    need_fixed "$vm" 'guard backgroundTask == .invalid else { return }' \
        "B9  der Start ist genau-einmal (Riegel)"
    need_fixed "$vm" 'guard backgroundTask != .invalid else { return }' \
        "B10 das Ende ist idempotent (Riegel)"
    need_fixed "$vm" 'static let backgroundResumeNotice = "Der Chat war im Hintergrund. Der Verlauf wurde vom Server neu geladen."' \
        "B11 der Hinweis ist wörtlich (A7)"
    need_fixed "$vm" 'func reconcileAfterBackground(announcesResume: Bool = true) async' \
        "B12 die Rückkehr hat genau einen benannten Pfad — vollständige Signatur inkl. async (V3e)"
    section_has "$vm" 'func reconcileAfterBackground' 'private func beginBackgroundTaskIfNeeded' \
        'await openSession\(session\)' \
        "B13 nachgeladen wird über den vorhandenen Verlaufspfad"
    section_has "$vm" 'func reconcileAfterBackground' 'private func beginBackgroundTaskIfNeeded' \
        'guard !isStreaming else \{ return \}' \
        "B14 ein lebender Strom gewinnt gegen die Reconciliation (E15)"
    section_has "$vm" 'func reconcileAfterBackground' 'private func beginBackgroundTaskIfNeeded' \
        'if announcesResume, notice == nil' \
        "B15 der Hintergrund-Hinweis überschreibt keine Fehlermeldung"
    section_has "$vm" 'func handleDidEnterBackground' 'func handleWillEnterForeground' \
        'beginBackgroundTaskIfNeeded\(\)' \
        "B16 der Hintergrund-Wechsel startet die Aufgabe"
    section_order "$vm" 'func handleWillEnterForeground' 'func reconcileAfterBackground' \
        'endBackgroundTaskIfNeeded()' 'reconcileAfterBackground()' \
        "B17 die Aufgabe wird beendet, bevor nachgeladen wird"
    need "$vm" 'private func registerLifecycleObservers\(\)' \
        "B18a die Beobachter werden registriert"
    section_has "$vm" 'self.provider = providerFactory' 'deinit' 'registerLifecycleObservers\(\)' \
        "B18b die Registrierung passiert im init"
    need_fixed "$vm" 'import UIKit' \
        "B19 das Modell darf UIKit kennen"
    need_fixed "$vm" 'private var backgroundTask: UIBackgroundTaskIdentifier = .invalid' \
        "B20 die Aufgabe startet als ungültig (kein Task)"
    need_fixed "$vm" 'private var resumeAfterBackground = false' \
        "B21 der Merker startet aus"
    ban_outside 'URLSessionConfiguration\.background' \
        "B22 keine Background-URLSession (kein unbegrenztes Streaming)"
    ban_outside 'BGTaskScheduler|beginBackgroundTask' \
        "B23 genau eine Stelle kennt die Hintergrund-Aufgabe" "$vm"
    need_fixed "$planerapp" 'isUnlocked = false' \
        "B24a die App-Sperre bleibt wirksam (Zuweisung vorhanden)"
    # B24b prüft die **Stelle**: die Sperre wird im Hintergrund-Zweig gesetzt,
    # nicht irgendwo in der Datei. Die Deklaration `@State … = false` in B24a
    # allein wäre grün, auch wenn der Hintergrund-Zweig nichts mehr täte.
    section_has "$planerapp" 'case .background:' 'case .active:' 'isUnlocked = false' \
        "B24b gesperrt wird beim Wechsel in den Hintergrund"
    need_fixed "$planerapp" 'Planer ist gesperrt' \
        "B25 der Sperrtext ist unverändert"
    ban "$planerapp" 'ChatViewModel|MessageBubbleView|ChatView' \
        "B26 die Sperre kennt den Chat nicht"
    section_lacks "$planerapp" 'private var lockScreen' 'private func unlockIfNeeded' 'Chat' \
        "B27 hinter der Sperre steht kein Chat-Inhalt"

    # --- F1 (R-CH4): der Expiration-Handler schließt synchron ab ------------
    # Geprüft wird der **Rumpf der Closure**, nicht die Datei: `endBackgroundTask`
    # steht auch in `endBackgroundTaskIfNeeded`, `Task { @MainActor in` auch in
    # den beiden Beobachtern. Nur der Schnitt über die Klammertiefe trennt
    # „synchron im Handler“ von „im Hop daneben“.
    local handler='beginBackgroundTask(withName: "chat-turn")'
    block_has "$vm" "$handler" 'endBackgroundTaskIfNeeded\(\)' \
        "B28 die Freigabe steht im Rumpf des Expiration-Handlers (F1)"
    block_has "$vm" "$handler" 'MainActor\.assumeIsolated' \
        "B29 der Handler betritt den Main-Actor synchron, ohne Hop (F1)"
    block_lacks "$vm" "$handler" 'Task(\.[A-Za-z]+)?[[:space:]]*\{' \
        "B30 kein Task-Hop im Handler — UIKit verlangt die Freigabe vor der Rückkehr (F1)"

    # --- A1/A2 (Rev 9, MARAAA-188): die Rückkehr endet nicht im toten Strom --
    # Ein Strom, den die Suspension getötet hat, liefert nie einen Fehler: sein
    # `URLSession`-Request lebt bis `streamIdleTimeout` (Default 900 s) weiter.
    # Ohne Schonfrist bliebe `isStreaming` true und der Composer gesperrt —
    # genau der Nutzerbericht „ich muss die App neu starten“.
    # B31: der beschlossene Wert ist 25 s — exakt gepinnt, nicht als Bereich
    # (MARAAA-193: 10-s-Keepalive × 2 + Reserve, Folgeauftrag MARAAA-196).
    # Eine Änderung auf 12 s (oder jeden anderen Wert) ist rot (V3f).
    need_fixed "$cfg" 'var backgroundResumeGracePeriod: TimeInterval = 25' \
        "B31 die Schonfrist ist exakt 25 s"
    need_fixed "$vm" 'private var resumeWatchdogTask: Task<Void, Never>?' \
        "B32 der Watchdog ist gespeichert (kein freier Task)"
    section_has "$vm" 'func handleWillEnterForeground' 'func reconcileAfterBackground' \
        'scheduleResumeWatchdog\(\)' \
        "B33 die Rückkehr stellt bei laufendem Strom den Watchdog"
    # B34: der tote Strom wird **abgebrochen** (`cancel()`, V3d) und
    # **begrenzt** abgewartet (E3). Vorher stand hier `await runningTask.value`
    # — das hinge an genau dem Task, der hängt; die Zusage „abwarten, dann
    # aufräumen“ bleibt.
    block_has "$vm" 'private func abandonDeadStreamIfNeeded(' 'runningTask\?\.cancel\(\)' \
        "B34a der tote Strom wird abgebrochen (E3, V3d)"
    block_has "$vm" 'private func abandonDeadStreamIfNeeded(' 'await waitForTurnStop\(\)' \
        "B34a2 nach dem Abbruch wird begrenzt abgewartet (E3)"
    ban "$vm" 'await runningTask\.value' \
        "B34b kein unbegrenztes Warten auf den Task (E3)"
    block_has "$vm" 'private func waitForTurnStop()' 'streamStopWaitLimit' \
        "B34c die Wartezeit ist ein benannter Wert (E3)"
    # B35: Lebenszeichen = ausgelieferte **und** gelesene Zeilen. Vorher zählte
    # nur `streamEventCount`; die Zusage („Verkehr hält den Strom am Leben“)
    # bleibt, der Begriff ist jetzt vollständig.
    block_has "$vm" 'private var resumeLiveness: ResumeLiveness' 'streamEventCount' \
        "B35a das Lebenszeichen liest die Ereignisse"
    block_has "$vm" 'private var resumeLiveness: ResumeLiveness' 'lineCount' \
        "B35b das Lebenszeichen liest die gelesenen Zeilen (Keepalive/verworfen)"
    section_has "$vm" 'private func scheduleResumeWatchdog' 'private func cancelResumeWatchdog' \
        'resumeLiveness != marker' \
        "B35c ein Strom mit neuem Lebenszeichen gewinnt gegen die Frist (E15/B14)"
    section_order "$vm" 'private func run(text: String, generation: Int) async' 'private func rescueEmptyTurn' \
        'defer {' 'cancelResumeWatchdog\(\)' \
        "B36 das Turn-Ende bricht den Watchdog ab"
    block_has "$vm" 'deinit {' 'resumeWatchdogTask\?\.cancel\(\)' \
        "B37 der Deinit bricht den Watchdog ab"
    section_has "$vm" 'func handleDidEnterBackground' 'func handleWillEnterForeground' \
        'cancelResumeWatchdog\(\)' \
        "B38 der Wechsel in den Hintergrund bricht den Watchdog ab"
    section_has "$vm" 'func reconcileAfterBackground' 'private func beginBackgroundTaskIfNeeded' \
        'if !historyLoaded \{ offerHistoryReload\(\) \}' \
        "B39 gescheitertes Nachladen bietet den Wiederholweg (A2)"
    section_lacks "$vm" 'func reconcileAfterBackground' 'private func beginBackgroundTaskIfNeeded' \
        'offersHistoryReload = false' \
        "B40 die Rückkehr nimmt den Wiederholweg nicht wieder zurück (A2)"
    # B41 hält die Semantik aus B14 fest: der Watchdog greift nur, wenn seit der
    # Rückkehr kein einziges Lebenszeichen ankam — ein lebender Strom wird nicht
    # abgebrochen, nur weil die Frist abläuft.
    block_has "$vm" 'private func abandonDeadStreamIfNeeded(' \
        'guard isStreaming else \{ return \}' \
        "B41 ohne laufenden Turn tut der Watchdog nichts"
    # B42 (V1): die Freigabe-Ausnahme gilt nur für eine **entscheidbare**
    # Freigabe (`.open`/`acceptsDecision`). `.expired` wartet zwar
    # serverseitig weiter (`waitsForUser`), hat aber keine Chips mehr; der
    # Watchdog darf ihn nicht bis `streamIdleTimeout` sperren. Geprüft wird der
    # `continue`-Zweig im Rumpf — die Mutation „continue entfernen“ ist rot
    # (V3c). B42b belegt, dass die Ausnahme nicht mehr an `waitsForUser` hängt;
    # B42c, dass der Ablauf im Abbruch-Pfad einen eigenen Wortlaut hat.
    block_has "$vm" 'private func scheduleResumeWatchdog()' \
        'if self\.hasDecidableApproval \{ continue \}' \
        "B42a nur eine entscheidbare Freigabe lässt die Frist weiterlaufen (V1/V3c)"
    block_has "$vm" 'private var hasDecidableApproval' 'acceptsDecision' \
        "B42b die Ausnahme prüft acceptsDecision, nicht waitsForUser (V1)"
    block_has "$vm" 'private func abandonDeadStreamIfNeeded(' \
        'backgroundApprovalExpiredNotice' \
        "B42c der Ablauf endet mit eigenem, ehrlichem Wortlaut (V1)"

    # --- E1 (Befund 1): ehrlicher Ausgang statt Erfolgs-Hinweis --------------
    # Ein stiller und ein toter Strom sind nicht unterscheidbar. Die Frist darf
    # deshalb beenden — aber sie darf keinen Erfolg behaupten.
    need_fixed "$vm" 'static let backgroundStreamLostNotice = ' \
        "B43a es gibt einen eigenen Wortlaut für den abgerissenen Turn (E1)"
    local lost_len
    lost_len="$(sed -n 's/^[[:space:]]*static let backgroundStreamLostNotice = "\(.*\)"$/\1/p' "$vm" | wc -m | tr -d ' ')"
    if [[ -n "$lost_len" && "$lost_len" -ge 20 && "$lost_len" -le 301 ]]; then
        pass "B43b der Verlust-Text bleibt im Rahmen (≤ 300 Zeichen: $((lost_len - 1)))"
    else
        bad "B43b Verlust-Text: ${lost_len:-0} Zeichen (inkl. Zeilenende), erwartet 20–300  [$vm]"
    fi
    block_has "$vm" 'private func abandonDeadStreamIfNeeded(' 'backgroundStreamLostNotice' \
        "B43c der Abbruch-Pfad setzt den ehrlichen Text (E1)"
    block_has "$vm" 'private func abandonDeadStreamIfNeeded(' 'offerHistoryReload\(\)' \
        "B43d der Abbruch-Pfad bietet den Wiederholweg an (E1/A2)"
    block_lacks "$vm" 'private func abandonDeadStreamIfNeeded(' 'backgroundResumeNotice' \
        "B43e der Abbruch-Pfad behauptet keinen Erfolg (E1)"
    block_lacks "$vm" 'private func abandonDeadStreamIfNeeded(' 'noticeIsInformational = true' \
        "B43f der Verlust-Text behält die Warn-Optik (E1)"
    # B43g (V3a): geprüft wird der **Aufruf** im Abbruch-Rumpf, nicht das Wort
    # `announcesResume` in der Signatur. Mutation `false` -> `true` ist rot.
    block_has "$vm" 'private func abandonDeadStreamIfNeeded(' \
        'reconcileAfterBackground\(announcesResume: false\)' \
        "B43g der Erfolgs-Hinweis ist im Abbruch-Pfad abgeschaltet (E1/V3a)"

    # --- E2 (Befund 2): der Watchdog ist kontinuierlich ----------------------
    # Vorher galt „seit der Rückkehr kein Ereignis“ genau einmal; ein Strom,
    # der nach einem letzten Ereignis starb, blieb bis 900 s „lebendig“.
    block_has "$vm" 'private func scheduleResumeWatchdog()' 'while !Task\.isCancelled' \
        "B44a der Watchdog ist eine Task mit Schleife (E2)"
    block_has "$vm" 'private func scheduleResumeWatchdog()' 'Task\.sleep' \
        "B44b je Runde wird die Schonfrist abgewartet"
    block_has "$vm" 'private func scheduleResumeWatchdog()' 'continue' \
        "B44c neue Lebenszeichen lassen die nächste Runde beginnen"
    exactly "$vm" 'resumeWatchdogTask = Task' 1 \
        "B44d genau eine Stelle erzeugt den Watchdog-Task (kein Task je Ereignis)"
    block_lacks "$vm" 'private func streamTurn' 'Task \{' \
        "B44e im Ereignis-Pfad entsteht kein Task (E2)"
    need_fixed "$prov" 'liveness?.recordLine()' \
        "B44f jede gelesene Zeile zählt — auch Keepalive und verworfene Zeile (E2)"
    section_has "$prov" 'for try await line in bytes.lines' 'guard let event = decoder.consume' \
        'liveness\?\.recordLine\(\)' \
        "B44g die Zeile zählt vor dem Verwerfen (E2)"
    need_fixed "$vm" 'private let liveness = ChatStreamLiveness()' \
        "B44h die Zähler-Referenz gehört dem Modell (E2)"
    need_fixed "$vm" 'liveness.reset()' \
        "B44i der Zeilenzähler startet je Turn bei null (E2)"

    # --- E3 (Befund 3): begrenztes Warten und hartes Schließen ---------------
    block_has "$vm" 'private func abandonDeadStreamIfNeeded(' 'isStreaming = false' \
        "B45a der Turn-Zustand wird nach dem Abbruch hart geschlossen (E3)"
    block_has "$vm" 'private func abandonDeadStreamIfNeeded(' 'turnStartedAt = nil' \
        "B45b die Arbeits-Animation endet mit dem Turn (E3)"
    section_order "$vm" 'private func abandonDeadStreamIfNeeded(' 'private func waitForTurnStop' \
        'isStreaming = false' 'reconcileAfterBackground\(' \
        "B45c das Schließen steht vor dem Nachladen (E3)"
    # B45d (V3b): der Riegel wird im **Abbruch-Rumpf** gesetzt — die Generation
    # bindet ihn an genau diesen Turn. Mutation „Zuweisung löschen“ ist rot.
    block_has "$vm" 'private func abandonDeadStreamIfNeeded(' 'abandonedGeneration = generation' \
        "B45d der Abbruch-Riegel wird turn-gebunden gesetzt (E3/V2/V3b)"
    block_has "$vm" 'private func merge(sessionID: String)' 'guard abandonedGeneration != generation' \
        "B45e auch ein spätes Merge-Ergebnis wird verworfen (E3/V2)"

    # --- R-CH10 (MARAAA-192): Turn-Identität statt globalem Riegel -----------
    # Befund 1 (major, G-CH11/MARAAA-189): Ein `run`, der das begrenzte Warten
    # (`streamStopWaitLimit` = 3 s) überlebt, darf den Zustand eines inzwischen
    # gestarteten Turns nicht mehr setzen. Die Generation steigt in `send()`
    # und wird von `run`/`streamTurn`/`merge` als Konstante geführt; jeder
    # schreibende Schritt vergleicht sie. Ohne diese Marken ist der Fall
    # „Testanbieter ignoriert `Task.cancel`, wirft erst nach mehr als
    # `streamStopWaitLimit`, währenddessen startet ein zweiter Turn“ offen —
    # auf `b8863df` fehlen alle Marken (rot, siehe Bericht zu MARAAA-192).
    section_order "$vm" 'private func run(text: String, generation: Int) async' 'do {' \
        'if generation == turnGeneration' 'isStreaming = false' \
        "B48a der defer schließt nur den eigenen Turn (Befund 1)"
    section_order "$vm" 'private func run(text: String, generation: Int) async' 'do {' \
        'if generation == turnGeneration' 'cancelResumeWatchdog\(\)' \
        "B48b ein alter defer bricht nicht den Watchdog des neuen Turns ab (Befund 1)"
    at_least "$vm" 'guard generation == turnGeneration, abandonedGeneration != generation else \{ return \}' 7 \
        "B48c jeder Schritt in run/streamTurn prüft die Generation vor dem Schreiben (Befund 1: 4 in run, 3 in streamTurn)"
    block_has "$vm" 'private func merge(sessionID: String)' \
        'guard generation == turnGeneration, abandonedGeneration != generation' \
        "B48d ein Merge prüft die Generation nach dem await erneut (Befund 1)"
    block_has "$vm" 'private func run(text: String, generation: Int) async' \
        'guard generation == turnGeneration, abandonedGeneration != generation else \{ return \}' \
        "B48e der catch meldet keinen fremden Turn (Befund 1)"
    # Befund 2 (minor): `send()` öffnet den Riegel für den neuen Turn — genau
    # einmal und nach dem Hochzählen der Generation. Mutation „Zeile löschen“
    # ist rot (B48f/B48g/B48h).
    block_has "$vm" 'func send()' 'abandonedGeneration = nil' \
        "B48f send() öffnet den Riegel des Vorgängers (Befund 2)"
    exactly "$vm" '^[[:space:]]*abandonedGeneration = nil$' 1 \
        "B48g der Reset steht genau einmal im Baum (Befund 2)"
    section_order "$vm" 'func send()' 'isStreaming = true' \
        'turnGeneration \+= 1' 'abandonedGeneration = nil' \
        "B48h die neue Generation steht vor dem Reset (Befund 2)"
    # Befund 3 (minor): die Schonfrist wird an der Verwendungsstelle aus der
    # Konfiguration gelesen. Mutation `0.001` an genau dieser Stelle ist rot
    # (B48i), ebenso ein Literal im `sleep` statt `snapshot.gracePeriod` (B48j).
    block_has "$vm" 'private func resumeWatchdogSnapshot()' \
        'gracePeriod: max\(configuration\.backgroundResumeGracePeriod, 0\)' \
        "B48i der Watchdog liest die Schonfrist aus der Konfiguration (Befund 3)"
    block_has "$vm" 'private func scheduleResumeWatchdog()' \
        'UInt64\(snapshot\.gracePeriod \* 1_000_000_000\)' \
        "B48j die Schleife wartet die gelesene Schonfrist ab (Befund 3)"

    # --- Runde 4 (MARAAA-188, W1–W4): die letzte Verdrahtung pinnen -----------
    # W1: Die Rumpf-Prüfungen B34a/B41/B43g/B45a decken `abandonDeadStreamIfNeeded`
    # selbst ab; fehlte aber der **Aufruf** im Watchdog, bliebe der ganze
    # A1-Mechanismus unbewacht (genau die Lücke aus dem dritten Review).
    # Mutation „Aufruf löschen“ ist rot (B49a).
    block_has "$vm" 'private func scheduleResumeWatchdog()' \
        'await self\.abandonDeadStreamIfNeeded\(' \
        "B49a der Watchdog ruft den Abbruch-Pfad im eigenen Rumpf auf (W1)"
    # W2 (V1): Der Grund des Abbruchs wird am Aufruf übergeben. Stünde dort
    # `false`, wäre `backgroundApprovalExpiredNotice` toter Text und eine
    # abgelaufene Freigabe bekäme den falschen (Stream-Verlust-)Wortlaut.
    # Mutation `false` ist rot (B49b); die Auswahl im Rumpf pinnt B49c.
    block_has "$vm" 'private func scheduleResumeWatchdog()' \
        'approvalExpired: self\.hasExpiredApproval' \
        "B49b der Watchdog gibt den Freigabe-Ablauf als Grund mit (W2/V1)"
    block_has "$vm" 'private func abandonDeadStreamIfNeeded(' \
        'notice = approvalExpired' \
        "B49c der Abbruch-Pfad wählt den Text nach dem übergebenen Grund (W2/V1)"
    # W3: Abbrechen **vor** dem begrenzten Warten. Umgekehrt (erst 3 s warten,
    # dann abbrechen) bliebe der Test grün, wäre aber semantisch falsch —
    # `waitForTurnStop` sähe einen ungebrochen laufenden Strom und liefe in
    # jedem Fall in die volle Frist. Mutation „Reihenfolge tauschen“ ist rot.
    section_order "$vm" 'private func abandonDeadStreamIfNeeded(' 'private func waitForTurnStop' \
        'runningTask?.cancel()' 'await waitForTurnStop()' \
        "B49d der Strom wird abgebrochen, bevor begrenzt gewartet wird (W3)"
    # W4: `reconcileAfterBackground` gibt den Main-Actor ab; ein inzwischen
    # gestarteter Turn darf weder den Verlust-Text noch den Wiederholweg des
    # alten Turns erben. Geprüft wird der Riegel **nach** dem Nachladen und
    # **vor** dem Schreiben (Mutation „guard löschen“ ist rot).
    section_order "$vm" 'await reconcileAfterBackground\(announcesResume: false\)' \
        'private func waitForTurnStop' \
        'guard generation == turnGeneration' 'notice = approvalExpired' \
        "B49e nach dem Nachladen riegelt die Generation erneut vor dem Schreiben (W4)"

    # --- R-CH12 (MARAAA-198): die beiden Merge-Ausstiegspfade riegeln ---------
    # Review MARAAA-194, Befund 1 (minor): `merge` hielt die Generation beim
    # Eintritt fest, prüfte sie aber nur nach dem `await api.messages`. Der
    # Erfolgspfad schreibt nach `await loadSessions()` (das selbst eine
    # `notice` setzen kann), der Fehlerpfad im `catch` — beide ohne erneute
    # Prüfung. Geprüft wird die Reihenfolge der Marken im Rumpf von `merge`.
    section_sequence "$vm" 'private func merge(sessionID: String)' 'private func applyMergedUser' \
        "B50a nach dem Nachladen riegelt der Erfolgspfad vor dem Übernehmen (R-CH12)" \
        'await loadSessions()::guard generation == turnGeneration, abandonedGeneration != generation else::syncCurrentSessionWithList()'
    section_sequence "$vm" 'private func merge(sessionID: String)' 'private func applyMergedUser' \
        "B50b der Fehlerpfad prüft die Generation vor .failed (R-CH12)" \
        '} catch {::guard generation == turnGeneration, abandonedGeneration != generation else::return .failed'
    section_sequence "$vm" 'private func merge(sessionID: String)' 'private func applyMergedUser' \
        "B50c ein fremder Turn endet im catch als .skipped (R-CH12)" \
        '} catch {::return .skipped::return .failed'
    block_lacks "$vm" 'private func merge(sessionID: String)' 'notice =' \
        "B50d merge schreibt selbst keine Meldung — der Aufrufer entscheidet (R-CH12)"
    # Der Aufrufer schrieb die `.failed`-Meldung nach dem `await` ohne Prüfung.
    # Geprüft wird der Riegel **nach** dem Merge-Aufruf und **vor** dem Zweig,
    # der die Meldung setzt. Mutation „guard löschen“ ist rot (B50e).
    section_sequence "$vm" 'private func streamTurn' 'private func adoptSessionID' \
        "B50e der Merge-Aufrufer riegelt vor dem Schreiben der Meldung (R-CH12)" \
        'let outcome = await merge(sessionID: effectiveSessionID)::guard generation == turnGeneration, abandonedGeneration != generation::case .failed:'

    # --- E4 (Befund 4): Info-Optik überall ----------------------------------
    section_has "$view" 'private var emptyState' 'private func scrollToBottom' \
        '!viewModel\.noticeIsInformational' \
        "B46a die ChatView wertet die Info-Optik im Leerzustand aus (E4)"
    section_has "$view" 'private var emptyState' 'private func scrollToBottom' \
        'if !viewModel\.noticeIsInformational \{' \
        "B46b ein reiner Hinweis bekommt keinen zweiten Weg (E4)"
    need_fixed "$slv" 'let errorIsInformational: Bool' \
        "B46c die Verlaufsliste kennt den Unterschied (E4)"
    section_has "$slv" 'private var emptyState' '// MARK: Darstellung' \
        'errorIsInformational' \
        "B46d die Verlaufsliste zeigt einen Hinweis nicht als Verbindungsfehler (E4)"
    need_fixed "$view" 'errorIsInformational: viewModel.noticeIsInformational' \
        "B46e die View reicht die Unterscheidung durch, statt den Text zu prüfen (E4)"

    # --- E6 (Befund 7): der Wiederholweg überlebt ein gescheitertes Laden ----
    block_has "$vm" 'func reloadHistory() async' 'offerHistoryReload\(\)' \
        "B47 scheitert auch das erneute Laden, bleibt der Wiederholweg (E6)"
}

# ---------------------------------------------------------------------------
# (e) Querschnitt — §7.3.5, X1–X11
# ---------------------------------------------------------------------------
handover_section() {
    echo "--- (e) Querschnitt: keine Magic Number, Zusagen aus Rev 5/6 unberührt"

    # X1: §7.3 zählt die nackte Zahl; `300` steht am Ist-Code auch in
    # `maxNoticeCharacters` (Zeile 68, unverändert aus Rev 5). Geprüft wird
    # deshalb die Deklaration der beiden neuen Werte.
    exactly "$cfg" 'var approvalTimeout: TimeInterval = 300' 1 \
        "X1a die 300 steht genau einmal, als Freigabe-Frist"
    exactly "$cfg" 'var maxCommandCharacters = 12_000' 1 \
        "X1b die 12 000 steht genau einmal, als Befehls-Obergrenze"
    ban "$view" '\b300\b|12_000' \
        "X2a keine Magic Number in der View"
    ban "$chips" '\b300\b|12_000' \
        "X2b keine Magic Number in den Chips"
    ban "$phase" '\b300\b|12_000' \
        "X2c keine Magic Number im Freigabe-Zustand"
    # X2d ist die Kontrolle gegen ein ins Leere greifendes Ban-Muster: genau
    # dasselbe Muster muss in der erlaubten Datei treffen.
    need "$cfg" '\b300\b' \
        "X2d (Kontrolle: das Ban-Muster X2a-c trifft in der erlaubten Datei — es ist nicht leer)"
    section_has "$vm" 'func decideApproval(' 'switch choice' 'refreshConfiguration\(\)' \
        "X3  der Freigabe-Pfad liest die aktuelle Konfiguration"
    need "$vm" 'var showsWorkingIndicator: Bool' \
        "X4a die Arbeits-Animation ist noch da (O5)"
    section_has "$vm" 'var showsWorkingIndicator' '// MARK: Verlauf neu laden' \
        'toolStatus == \.running' \
        "X4b laufende Werkzeuge zeigen die Animation"
    section_has "$vm" 'var showsWorkingIndicator' '// MARK: Verlauf neu laden' \
        'return lastAgent\.text\.isEmpty' \
        "X4c ohne Agent-Text zeigt sie die Animation"
    need_fixed "$vm" '@Published private(set) var decidingApprovalEntryID: UUID?' \
        "X5  der laufende POST ist von außen nur lesbar"
    need "$vm" 'var turnStartedAt: Date\?' \
        "X6a die Startzeit des Turns ist optional"
    at_least "$vm" 'turnStartedAt = nil' 2 \
        "X6b die Startzeit wird an jedem Turn-Ende gelöscht"
    need_fixed "$net" 'let session = service == .hermes ? streamingSession : urlSession(for: service)' \
        "X7  der Strom nutzt weiter die Streaming-Session (O2)"
    need "$vm" 'try await api\.probeProfile\(\)' \
        "X8  der Profil-Test bleibt im Modell (O7)"
    exactly "$planerapp" '\.preferredColorScheme\(appearance\.colorScheme\)' 1 \
        "X9  die Erscheinungsbild-Wahl bleibt genau einmal (O6)"
    need "$cfg" 'var approvalPath' \
        "X10a der Freigabe-Pfad ist benannt"
    need "$cfg" 'func scoped' \
        "X10b der Pfad wird gescoped"
    ban_tree 'ToolCallPolicy|ToolCallConfirmation|MCPClient|callTool' \
        "X11 kein MCP-Lebenszyklus im Chat (Rev 5 §3.4)" "$chat"
}

case "${1:-all}" in
    copy)       copy_section ;;
    approval)   approval_section ;;
    phase|status) phase_section ;;
    background) background_section ;;
    handover)   handover_section ;;
    all)
        copy_section
        approval_section
        phase_section
        background_section
        handover_section
        ;;
    *)
        echo "Aufruf: $0 [copy|approval|phase|status|background|handover|all]"
        exit 2
        ;;
esac

if [[ "$fail" -ne 0 ]]; then
    echo "Ergebnis: FEHLGESCHLAGEN (chat-ux2)"
    exit 1
fi
echo "Ergebnis: OK (chat-ux2)"
