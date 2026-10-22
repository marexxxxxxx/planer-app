//
//  TextClipboard.swift
//  Planer
//
//  Kopieren als lokale Operation (spec-chat Rev 7 Delta §3.2, L1).
//

import SwiftUI
import UIKit

/// Schreibt Text in die Zwischenablage und sonst nichts.
///
/// Zweck: die **einzige** Stelle im Baum, die die Zwischenablage kennt. Die
/// beiden Modifier hängen eine Kopier-Affordanz an eine View; der Text selbst
/// bleibt, wo er gerendert wird.
/// Grenze: kein Netzwerk, keine Historie, keine Persistenz. Kopiert wird der
/// getrimmte Text zum Zeitpunkt des Tipps — ein weiterlaufender Strom wird
/// nicht angehalten (§3.2.6).
enum TextClipboard {

    /// Die Ansage nach erfolgreichem Kopieren; wörtlich (§3.2.4).
    static let announcement = "Kopiert"

    /// Schreibt den getrimmten Text und meldet Erfolg. Leerer Text wird nicht
    /// geschrieben — die vorhandene Zwischenablage bleibt unangetastet.
    @discardableResult
    static func copy(_ text: String?) -> Bool {
        guard isCopyable(text), let text else { return false }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        UIPasteboard.general.string = trimmed
        AccessibilityNotification.Announcement(TextClipboard.announcement).post()
        return true
    }

    /// `nil`, `""` und reiner Leerraum sind nicht kopierbar (§3.2.3).
    fileprivate static func isCopyable(_ text: String?) -> Bool {
        guard let text else { return false }
        return !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

extension View {

    /// Kontextmenü **und** benannte VoiceOver-Aktion — für Flächen ohne
    /// Textauswahl (Blasen, Kurzfelder).
    func copyableText(_ text: String?) -> some View {
        modifier(CopyableTextModifier(text: text))
    }

    /// Nur die benannte VoiceOver-Aktion — für Flächen, auf denen
    /// `textSelection` bereits ein Systemmenü liefert (Befehl, Argumente,
    /// Ergebnis).
    func copyableAction(_ text: String?) -> some View {
        modifier(CopyableActionModifier(text: text))
    }
}

/// Kontextmenü plus VoiceOver-Aktion. Bei nicht kopierbarem Text bleibt die
/// View unverändert — kein Menü, keine Aktion.
private struct CopyableTextModifier: ViewModifier {

    let text: String?

    @ViewBuilder
    func body(content: Content) -> some View {
        if TextClipboard.isCopyable(text) {
            content
                .contextMenu {
                    Button("Kopieren") {
                        TextClipboard.copy(text)
                    }
                }
                .accessibilityAction(named: Text("Kopieren")) {
                    TextClipboard.copy(text)
                }
        } else {
            content
        }
    }
}

/// Nur die VoiceOver-Aktion; das Long-Press-Menü kommt dort vom
/// `textSelection` des Systems.
private struct CopyableActionModifier: ViewModifier {

    let text: String?

    @ViewBuilder
    func body(content: Content) -> some View {
        if TextClipboard.isCopyable(text) {
            content
                .accessibilityAction(named: Text("Kopieren")) {
                    TextClipboard.copy(text)
                }
        } else {
            content
        }
    }
}
