//
//  ToolCallConfirmation.swift
//  Planer
//
//  Ein modell-angeforderter Werkzeugaufruf, der auf die Nutzerfreigabe wartet
//  (spec-ios §8-1, Design-Spec §4/Tab 1, Review-Befund N5).
//

import Foundation

/// Ein `tools/call`, den das Modell angefordert hat und der **noch nicht**
/// ausgeführt ist.
///
/// Zweck: den wartenden Aufruf als eigenen Wert halten — zusammen mit der
/// Entscheidung, ob er überhaupt freigabepflichtig ist. `ChatViewModel` setzt
/// ihn als `pendingToolCall`, solange die Action-Chips sichtbar sind, und leert
/// ihn bei Freigabe, Ablehnung, Abbruch oder Trennen. Solange dieser Wert
/// existiert, ist kein Aufruf an den Server gegangen.
/// Grenze: enthält weder die Fortsetzung des Wartens noch Netzwerkzugriff — die
/// Ausführung bleibt in `ChatViewModel.execute`. Die Freigaberegel selbst
/// stammt aus `ToolCallPolicy` und wird hier nur mitgeführt, nicht neu
/// entschieden.
struct ToolCallConfirmation: Identifiable, Equatable {

    /// Identität der Verlaufszeile (Badge + Chips), **nicht** die MCP-Aufruf-ID:
    /// die Zeile entsteht vor der Antwort des Servers, die Aufruf-ID erst mit
    /// dem Delta.
    let id: UUID

    /// Die Anforderung des Modells, unverändert — Name, Argumente, Aufruf-ID.
    let pendingToolCall: ToolCallRequest

    /// `true`, wenn der Aufruf ohne Tipp auf „Ausführen“ nicht laufen darf.
    /// Kommt aus `ToolCallPolicy`; `false` nur bei ausdrücklichem
    /// `readOnlyHint: true` des Servers. Ein unbekanntes Werkzeug (`nil` im
    /// Katalog) ist immer bestätigungspflichtig.
    let requiresConfirmation: Bool

    /// Name des Werkzeugs, wie er im Chip und im Badge steht.
    var toolName: String { pendingToolCall.name }
}
