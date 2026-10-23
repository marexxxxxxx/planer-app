//
//  ChatPhaseStatusView.swift
//  Planer
//
//  Live-Status eines Turns (spec-chat Rev 7 Delta §3.4, L3).
//

import SwiftUI

/// Die sechs Phasen eines laufenden Turns; wörtliche Texte (§3.4.1,
/// spec-chat-live-activity §5.1/4).
///
/// Zweck: die Statuszeile benennt, **was** der Turn tut, während die Blase
/// zeigt, **was** er sagt. Abgeleitet in `ChatViewModel.turnPhase` — es gibt
/// keinen gespeicherten Phasenzustand.
enum ChatTurnPhase: Equatable, Sendable {

    case connecting
    /// Verbunden, aber weder Denken noch Text noch Werkzeug angekommen.
    case waitingForModel
    case thinking
    case tool(name: String)
    case awaitingApproval
    case writing

    /// Der Text der Zeile; wörtlich (§3.4.1).
    var title: String {
        switch self {
        case .connecting: return "Verbindet …"
        case .waitingForModel: return "Wartet auf das Modell …"
        case .thinking: return "Denkt nach …"
        case .tool(let name): return "Werkzeug \(name)"
        case .awaitingApproval: return "Wartet auf Freigabe …"
        case .writing: return "Schreibt …"
        }
    }
}

/// Eine Zeile im Statusbereich, außerhalb des Scrollinhalts.
///
/// Zweck: den Zustand des Turns für die gesamte Dauer von `isStreaming`
/// zeigen — auch wenn Text strömt. Sie ist **zusätzlich** zu
/// `WorkingIndicatorView`, nicht ersatzweise (O5 bleibt unverändert).
/// Grenze: keine eigene Animation und kein animierter Übergang; der Wechsel
/// tauscht den String derselben `Text`-Instanz, damit nichts flackert (§3.4.4).
/// Für VoiceOver ein eigenes Element ohne Ansage je Wechsel (§3.4.6).
struct ChatPhaseStatusView: View {

    private let phase: ChatTurnPhase

    init(phase: ChatTurnPhase) {
        self.phase = phase
    }

    var body: some View {
        Text(phase.title)
            .font(DesignTokens.Typography.footnote)
            .foregroundStyle(DesignTokens.Palette.secondaryLabel)
            .lineLimit(1)
            .padding(.horizontal, DesignTokens.Spacing.l)
            .padding(.vertical, DesignTokens.Spacing.xs)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(DesignTokens.Palette.groupedBackground)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text("Status: \(phase.title)"))
    }
}

#Preview("ChatPhaseStatusView") {
    VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
        ChatPhaseStatusView(phase: .connecting)
        ChatPhaseStatusView(phase: .waitingForModel)
        ChatPhaseStatusView(phase: .thinking)
        ChatPhaseStatusView(phase: .tool(name: "hermes_tasks_list"))
        ChatPhaseStatusView(phase: .awaitingApproval)
        ChatPhaseStatusView(phase: .writing)
    }
}
