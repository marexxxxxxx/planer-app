import SwiftUI

/// Zentrale Design-Tokens der App.
///
/// `Config/DesignTokens.json` spiegelt dieselben Werte maschinenlesbar; beide
/// Dateien werden nur gemeinsam geändert. Farben sind iOS-Systemfarben, damit
/// Light und Dark ohne eigene Farbdefinition folgen.
enum DesignTokens {

    /// Semantische Farben. Aliase (`agentBubble`) benennen die Rolle, nicht den
    /// Farbton — Feature-WPs lesen die Rolle, nie den Systemnamen.
    enum Palette {
        static let groupedBackground = Color(.systemGroupedBackground)
        static let secondaryBackground = Color(.secondarySystemBackground)
        static let tertiaryBackground = Color(.tertiarySystemBackground)

        static let label = Color(.label)
        static let secondaryLabel = Color(.secondaryLabel)

        static let userBubble = Color.accentColor
        static let agentBubble = secondaryBackground
        static let toolCallBubble = tertiaryBackground

        static let success = Color(.systemGreen)
        static let danger = Color(.systemRed)
    }

    enum Spacing {
        static let xs: CGFloat = 4
        static let s: CGFloat = 8
        static let m: CGFloat = 12
        static let l: CGFloat = 16
        static let xl: CGFloat = 24
    }

    enum Radius {
        static let card: CGFloat = 16
        static let bubble: CGFloat = 18
    }

    /// Dynamic-Type-Styles statt fester Punktgrößen.
    enum Typography {
        static let headline = Font.headline
        static let body = Font.body
        static let callout = Font.callout
        static let footnote = Font.footnote
    }
}
