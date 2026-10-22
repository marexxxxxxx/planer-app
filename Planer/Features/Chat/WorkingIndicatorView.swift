//
//  WorkingIndicatorView.swift
//  Planer
//
//  Arbeits-Animation während eines laufenden Turns (spec-chat Rev 6 §4.7.2).
//

import SwiftUI

/// Drei pulsierende Punkte, „Hermes arbeitet …“ und die verstrichenen Sekunden.
///
/// Zweck: der Nutzer sieht, dass der Turn läuft, ohne dass eine Statuszeile
/// umgedeutet wird. Die Sekunden kommen ausschließlich aus `startedAt` und
/// werden von `TimelineView` neu gerendert.
/// Grenze: keine Fachlogik, keine Startzeit-Berechnung, kein eigener Timer.
struct WorkingIndicatorView: View {

    /// Startzeit des Turns aus `ChatViewModel.turnStartedAt`.
    let startedAt: Date

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isPulsing = false

    var body: some View {
        TimelineView(.periodic(from: startedAt, by: 1)) { context in
            let seconds = max(0, Int(context.date.timeIntervalSince(startedAt)))

            HStack(spacing: DesignTokens.Spacing.s) {
                HStack(spacing: DesignTokens.Spacing.xs) {
                    ForEach(0..<3, id: \.self) { index in
                        Circle()
                            .fill(DesignTokens.Palette.secondaryLabel)
                            .frame(width: 6, height: 6)
                            .scaleEffect(reduceMotion ? 1 : (isPulsing ? 1 : 0.55))
                            .animation(
                                reduceMotion
                                    ? nil
                                    : .easeInOut(duration: 0.6)
                                        .repeatForever(autoreverses: true)
                                        .delay(Double(index) * 0.15),
                                value: isPulsing
                            )
                    }
                }

                Text("Hermes arbeitet …")
                    .font(DesignTokens.Typography.footnote)
                    .foregroundStyle(DesignTokens.Palette.secondaryLabel)

                Text("\(seconds) s")
                    .font(DesignTokens.Typography.footnote.monospacedDigit())
                    .foregroundStyle(DesignTokens.Palette.secondaryLabel)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text("Hermes arbeitet seit \(seconds) Sekunden"))
        }
        .onAppear { isPulsing = true }
    }
}

#Preview("WorkingIndicatorView") {
    WorkingIndicatorView(startedAt: Date().addingTimeInterval(-12))
        .padding()
}
