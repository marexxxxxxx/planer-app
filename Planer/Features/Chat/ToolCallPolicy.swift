//
//  ToolCallPolicy.swift
//  Planer
//
//  Freigaberegel für Modell-angeforderte Werkzeugaufrufe (spec-ios §8-1,
//  Design-Spec §4/Tab 1, Review-Befund N5).
//

import Foundation

/// Entscheidet, ob ein `tools/call` ohne Nutzerbestätigung laufen darf.
///
/// Zweck: die Sicherheitsgrenze des Chat-Tabs. Ein Werkzeug, das schreiben kann,
/// wird **nie** allein aufgrund einer Modell-Anforderung ausgeführt; es wartet
/// auf die Action-Chips in `ChatView`.
/// Grenze: die Entscheidung stützt sich ausschließlich auf die MCP-Annotation
/// `readOnlyHint` des Servers. Fehlt sie — oder ist das Werkzeug nicht im
/// Katalog —, gilt „bestätigungspflichtig“ (Default deny). Ein Name wie
/// `*_create` wird nicht geraten: Namen sind keine Zusage über Nebenwirkungen.
enum ToolCallPolicy {

    /// `true`, wenn der Aufruf eine Bestätigung braucht.
    static func requiresConfirmation(for tool: MCPTool?) -> Bool {
        guard let tool else { return true }
        return tool.annotations?.readOnlyHint != true
    }

    /// Satz über dem Chip-Paar; nennt das Werkzeug, damit die Entscheidung
    /// nicht auf einem erratenen Namen beruht.
    static func prompt(for toolName: String) -> String {
        "Hermes möchte „\(toolName)“ ausführen. Das kann Daten verändern."
    }

    /// Beschriftung des freigebenden Chips. Bewusst generisch: die App kennt die
    /// Semantik eines fremden Werkzeugs nicht und verspricht deshalb keine
    /// konkrete Wirkung („In To-Dos speichern“ wäre eine Behauptung).
    static let approveTitle = "Ausführen"

    /// Beschriftung des ablehnenden Chips.
    static let declineTitle = "Ablehnen"
}
