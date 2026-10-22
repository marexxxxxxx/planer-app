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

        /// Textfarbe auf der Nutzerblase.
        ///
        /// `systemBackground` ist im Hell-Modus weiß und im Dunkel-Modus
        /// schwarz — also in beiden Schemata die Farbe, die gegen den Akzent
        /// Kontrast hält (4,6:1 hell, 7,8:1 dunkel). Festes Weiß wäre im
        /// Dunkel-Modus auf dem hellen Akzent (#6C9BFF) nicht lesbar.
        static let userBubbleLabel = Color(.systemBackground)
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

    /// Mindesthöhen der Zeilen (O9).
    ///
    /// `minHeight`, nicht `height`: bei Dynamic Type XXXL muss die Zeile
    /// wachsen dürfen, statt Text abzuschneiden.
    enum Size {
        static let settingsRow: CGFloat = 56
        static let recipeRow: CGFloat = 76
        static let thumbnail: CGFloat = 56
    }

    /// Dynamic-Type-Styles statt fester Punktgrößen.
    enum Typography {
        static let headline = Font.headline
        static let body = Font.body
        static let callout = Font.callout
        static let footnote = Font.footnote
    }
}
