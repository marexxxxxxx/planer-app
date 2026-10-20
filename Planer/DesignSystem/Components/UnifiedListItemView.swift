import SwiftUI

/// Gemeinsames Listenelement für To-Dos, Einkaufsartikel und Rezeptkarten.
/// Die drei Feature-Tabs teilen damit Höhe, Abstände und Sekundärzeile, statt
/// jeweils eine eigene Zeile zu bauen.
struct UnifiedListItemView<Trailing: View>: View {

    private let title: String
    private let subtitle: String?
    private let systemImage: String?
    private let trailing: Trailing

    init(
        _ title: String,
        subtitle: String? = nil,
        systemImage: String? = nil,
        @ViewBuilder trailing: () -> Trailing
    ) {
        self.title = title
        self.subtitle = subtitle
        self.systemImage = systemImage
        self.trailing = trailing()
    }

    var body: some View {
        HStack(spacing: DesignTokens.Spacing.m) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(DesignTokens.Typography.callout)
                    .foregroundStyle(DesignTokens.Palette.secondaryLabel)
                    .frame(width: 20)
            }

            VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
                Text(title)
                    .font(DesignTokens.Typography.headline)
                    .foregroundStyle(DesignTokens.Palette.label)

                if let subtitle {
                    Text(subtitle)
                        .font(DesignTokens.Typography.footnote)
                        .foregroundStyle(DesignTokens.Palette.secondaryLabel)
                }
            }

            Spacer(minLength: DesignTokens.Spacing.s)

            trailing
        }
        .padding(DesignTokens.Spacing.m)
        .background(
            DesignTokens.Palette.secondaryBackground,
            in: RoundedRectangle(cornerRadius: DesignTokens.Radius.card, style: .continuous)
        )
        .accessibilityElement(children: .combine)
    }
}

extension UnifiedListItemView where Trailing == EmptyView {

    init(_ title: String, subtitle: String? = nil, systemImage: String? = nil) {
        self.init(title, subtitle: subtitle, systemImage: systemImage) { EmptyView() }
    }
}

#Preview("UnifiedListItemView") {
    VStack(spacing: DesignTokens.Spacing.s) {
        UnifiedListItemView("Milch", subtitle: "2 Stück · Kühlschrank", systemImage: "cart")
        UnifiedListItemView("Wochenplan prüfen", systemImage: "checklist") {
            Image(systemName: "chevron.right")
                .foregroundStyle(DesignTokens.Palette.secondaryLabel)
        }
    }
    .padding()
}
