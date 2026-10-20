import SwiftUI

/// Stub-Root-View von Tab 1. Gehört I3 (Chat/MCP-Client) und wird dort ersetzt.
struct ChatView: View {
    var body: some View {
        NavigationStack {
            ContentUnavailableView(
                "Chat",
                systemImage: "bubble.left.and.bubble.right",
                description: Text("Der native MCP-Client folgt mit I3.")
            )
            .navigationTitle("Chat")
            .background(DesignTokens.Palette.groupedBackground)
        }
    }
}

#Preview("ChatView") {
    ChatView()
}
