//
//  ApprovalPhase.swift
//  Planer
//
//  Die sechs Zustände einer Server-Freigabe (spec-chat Rev 7 Delta §3.3.1).
//

import Foundation

/// Zustand einer Freigabe — als reine Funktion ihres Falls.
///
/// Zweck: die Karte und der Riegel in `ChatViewModel.decideApproval` sprechen
/// über **einen** benannten Zustand statt über `Bool`-Kombinationen.
/// Grenze: kein gespeicherter Verlauf. `.expired` wird ausschließlich aus Uhr
/// und Frist abgeleitet (`derive`), nie gesetzt.
enum ApprovalPhase: Equatable, Sendable {

    /// Ereignis empfangen, nichts gesendet.
    case open
    /// POST läuft.
    case sending
    /// Server hat die Freigabe angenommen (nicht: der Befehl war erfolgreich).
    case executed
    /// Von hier abgelehnt.
    case denied
    /// Frist vorbei, nichts gesendet.
    case expired
    /// Der Server hat bereits entschieden — welche Entscheidung, weiß der
    /// Client nicht.
    case conflict

    /// Der Text auf der Karte; wörtlich (§3.3.1).
    var label: String {
        switch self {
        case .open: return "Offen"
        case .sending: return "Wird gesendet …"
        case .executed: return "Ausgeführt"
        case .denied: return "Abgelehnt"
        case .expired: return "Abgelaufen"
        case .conflict: return "Nicht mehr aktiv"
        }
    }

    /// Nur aus `.open` darf noch ein POST werden. Der Riegel und die
    /// Sichtbarkeit der Knöpfe lesen genau das.
    var acceptsDecision: Bool { self == .open }

    /// `true`, solange der **Server** noch auf eine Antwort wartet. Nach
    /// `.expired` wartet er weiter, auch wenn der Client nichts mehr sendet.
    var waitsForUser: Bool {
        switch self {
        case .open, .sending, .expired: return true
        case .executed, .denied, .conflict: return false
        }
    }

    /// Leitet den Anzeigezustand ab: der gespeicherte Zustand gewinnt immer;
    /// nur `.open` kippt nach Fristablauf zu `.expired`.
    ///
    /// Grenze: die Frist ist der Client-Default. Hat der Betreiber
    /// `approvals.timeout` erhöht, zeigt die Karte zu früh „Abgelaufen“; sie
    /// behauptet dabei nicht, der Server habe abgelehnt (§3.3.6).
    static func derive(stored: ApprovalPhase, receivedAt: Date?, timeout: TimeInterval, now: Date) -> ApprovalPhase {
        guard stored == .open, let receivedAt else { return stored }
        if now.timeIntervalSince(receivedAt) >= timeout {
            return .expired
        }
        return .open
    }
}
