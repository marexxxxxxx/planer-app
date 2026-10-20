import SwiftUI

/// Stub-Tab-Provider für Chat. Gehört I3 und wird dort ersetzt.
enum ChatTabDefinition: TabDefinition {
    static func makeRootView() -> some View {
        ChatView()
    }
}
