//
//  ChatView.swift
//  Planer
//
//  Tab 1 „Chat“: Verlauf, Eingabe, Denken, Werkzeugkarten und Freigaben —
//  Oberfläche über `ChatViewModel` (spec-chat Rev 4 §4, §6.3, §9.3).
//

import SwiftUI

/// Chat-Tab.
///
/// Zweck: rendert ausschließlich den Zustand aus `ChatViewModel` — Verlauf,
/// Denk-Klappen, Werkzeugkarten, Freigabe-Chips, Statuszeile und Eingabe.
/// Grenze: keine Fachlogik und kein Netzwerk. Die View liest die öffentliche
/// API (§9.3) und ruft nur deren Methoden; Laden, Senden, Abbruch, Freigabe
/// und Merge liegen im ViewModel. Einen MCP-Lebenszyklus gibt es nicht mehr —
/// deshalb kein `connect()`/`disconnect()`.
struct ChatView: View {

    @StateObject private var viewModel = ChatViewModel()
    @EnvironmentObject private var voice: VoiceCoordinator
    @FocusState private var isInputFocused: Bool
    @State private var showsSessions = false

    /// Anker für das automatische Scrollen ans Ende.
    private let bottomAnchor = "chat-bottom"

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                statusBar
                if let notice = viewModel.notice {
                    noticeBar(notice)
                }
                transcript
                Divider()
                VoiceControlBar()
                composer
            }
            .background(DesignTokens.Palette.groupedBackground)
            .navigationTitle("Chat")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        viewModel.newChat()
                    } label: {
                        Image(systemName: "square.and.pencil")
                    }
                    .disabled(viewModel.isStreaming)
                    .accessibilityLabel("Neuer Chat")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showsSessions = true
                        Task { await viewModel.loadSessions() }
                    } label: {
                        Image(systemName: "clock.arrow.circlepath")
                    }
                    .accessibilityLabel("Verlauf")
                }
            }
            .sheet(isPresented: $showsSessions) {
                SessionListView(
                    sessions: viewModel.sessions,
                    isLoading: viewModel.isLoadingSessions,
                    loadedAll: viewModel.loadedAllSessions,
                    isStreaming: viewModel.isStreaming,
                    selectedSessionID: viewModel.currentSession?.id,
                    errorText: viewModel.sessions.isEmpty ? viewModel.notice : nil,
                    onSelect: { session in
                        showsSessions = false
                        Task { await viewModel.openSession(session) }
                    },
                    onNewChat: {
                        showsSessions = false
                        viewModel.newChat()
                    },
                    onLoadMore: {
                        Task { await viewModel.loadMoreSessions() }
                    },
                    onRetry: {
                        Task { await viewModel.loadSessions() }
                    }
                )
            }
            .task { @MainActor in
                // N1: `@StateObject` erlaubt keinen Environment-Zugriff im
                // Initializer — die Verdrahtung passiert hier. Ein
                // MCP-Lebenszyklus existiert nicht mehr (Befund 10).
                viewModel.voice = voice
                voice.onTranscript = { [weak viewModel] text in
                    viewModel?.appendDictation(text)
                }
            }
            .onDisappear {
                viewModel.detach()
            }
        }
    }

    // MARK: Status (§4.9)

    private var statusBar: some View {
        HStack(spacing: DesignTokens.Spacing.xs) {
            Text(statusText)
                .font(DesignTokens.Typography.footnote)
                .foregroundStyle(DesignTokens.Palette.secondaryLabel)
                .lineLimit(1)

            Spacer(minLength: DesignTokens.Spacing.s)
        }
        .padding(.horizontal, DesignTokens.Spacing.l)
        .padding(.vertical, DesignTokens.Spacing.xs)
        .background(DesignTokens.Palette.groupedBackground)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text("Status: \(statusText)"))
    }

    private var statusText: String {
        if viewModel.isLoadingSessions {
            return "Lade Verlauf …"
        }
        if let statusNote = viewModel.statusNote {
            return statusNote.text
        }
        if let session = viewModel.currentSession {
            return SessionListView.displayTitle(for: session)
        }
        return "Neue Unterhaltung"
    }

    private func noticeBar(_ notice: String) -> some View {
        HStack(alignment: .top, spacing: DesignTokens.Spacing.s) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(DesignTokens.Typography.footnote)
                .foregroundStyle(DesignTokens.Palette.danger)

            Text(notice)
                .font(DesignTokens.Typography.footnote)
                .foregroundStyle(DesignTokens.Palette.label)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: DesignTokens.Spacing.xs)

            Button {
                viewModel.dismissNotice()
            } label: {
                Image(systemName: "xmark")
                    .font(DesignTokens.Typography.footnote)
            }
            .accessibilityLabel("Hinweis schließen")
        }
        .padding(DesignTokens.Spacing.m)
        .background(DesignTokens.Palette.secondaryBackground)
    }

    // MARK: Verlauf

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: DesignTokens.Spacing.s) {
                    if viewModel.hasMoreOlder {
                        Button {
                            // M3/E5: Anker ist die `Entry.id` des bisher ersten
                            // sichtbaren Eintrags — kein Index, kein Offset.
                            let anchorID = viewModel.entries.first?.id
                            Task { @MainActor in
                                await viewModel.loadOlderMessages()
                                guard let anchorID else { return }
                                // Erst rendern lassen, dann auf den Anker springen.
                                await Task.yield()
                                proxy.scrollTo(anchorID, anchor: .top)
                            }
                        } label: {
                            Text(viewModel.isLoadingHistory ? "Lade ältere Nachrichten …" : "Ältere laden")
                                .font(DesignTokens.Typography.footnote)
                        }
                        .disabled(viewModel.isLoadingHistory)
                        .frame(maxWidth: .infinity)
                        .accessibilityLabel("Ältere Nachrichten laden")
                    }

                    if viewModel.entries.isEmpty {
                        emptyState
                    }

                    ForEach(viewModel.entries) { entry in
                        row(for: entry)
                            .id(entry.id)
                    }

                    Color.clear
                        .frame(height: 1)
                        .id(bottomAnchor)
                }
                .padding(DesignTokens.Spacing.l)
            }
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: viewModel.entries.last?.id) { _, _ in
                scrollToBottom(proxy)
            }
        }
    }

    @ViewBuilder
    private func row(for entry: ChatViewModel.Entry) -> some View {
        switch entry.kind {
        case .user:
            MessageBubbleView(role: .user, text: entry.text)

        case .agent:
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
                // §4.5: leerer Text mit Reasoning rendert keine leere Bubble.
                if !entry.text.isEmpty {
                    MessageBubbleView(role: .agent, text: entry.text)

                    // §7 (spec-voice): jede Antwort trägt ihre Herkunft.
                    if let engine = entry.engine {
                        Text(engine.title)
                            .font(DesignTokens.Typography.footnote)
                            .foregroundStyle(DesignTokens.Palette.secondaryLabel)
                            .accessibilityLabel(Text("Antwort von \(engine.title)"))
                    }
                }

                if let reasoning = entry.reasoning, !reasoning.isEmpty {
                    ThinkingDisclosureView(
                        text: reasoning,
                        isExpanded: entry.reasoningDisclosure == .expanded,
                        onToggle: {
                            viewModel.toggleReasoning(entry.id)
                        }
                    )
                }
            }

        case .tool:
            ToolCallCard(
                name: entry.toolName ?? "Werkzeug",
                emoji: entry.toolEmoji,
                status: entry.toolStatus ?? .running,
                argumentsText: entry.toolArgs,
                resultText: entry.toolResult,
                isExpanded: entry.toolDetailDisclosure == .expanded,
                onToggle: {
                    viewModel.toggleToolDetail(entry.id)
                }
            )

        case .approval:
            approvalCard(for: entry)
        }
    }

    private func approvalCard(for entry: ChatViewModel.Entry) -> some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.s) {
            HStack(spacing: DesignTokens.Spacing.xs) {
                Image(systemName: "hand.raised")
                    .font(DesignTokens.Typography.footnote)
                    .foregroundStyle(DesignTokens.Palette.secondaryLabel)

                Text("Freigabe")
                    .font(DesignTokens.Typography.footnote)
                    .foregroundStyle(DesignTokens.Palette.label)

                Spacer(minLength: DesignTokens.Spacing.xs)

                Text((entry.toolStatus ?? .awaitingApproval).displayLabel)
                    .font(DesignTokens.Typography.footnote)
                    .foregroundStyle(
                        (entry.toolStatus ?? .awaitingApproval).displayTint
                    )
            }

            if let command = entry.approval?.command, !command.isEmpty {
                Text(command)
                    .font(DesignTokens.Typography.footnote.monospaced())
                    .foregroundStyle(DesignTokens.Palette.label)
                    .lineLimit(3)
                    .textSelection(.enabled)
            }

            if !entry.text.isEmpty {
                Text(entry.text)
                    .font(DesignTokens.Typography.footnote)
                    .foregroundStyle(DesignTokens.Palette.secondaryLabel)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let approval = entry.approval, !entry.approvalResolved {
                ToolConfirmationChips(
                    approval: approval,
                    isSending: viewModel.decidingApprovalEntryID == entry.id,
                    onDecide: { choice in
                        Task {
                            await viewModel.decideApproval(entry.id, choice: choice)
                        }
                    }
                )
            }
        }
        .padding(DesignTokens.Spacing.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            DesignTokens.Palette.secondaryBackground,
            in: RoundedRectangle(cornerRadius: DesignTokens.Radius.card, style: .continuous)
        )
        .accessibilityElement(children: .contain)
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.s) {
            if viewModel.isLoadingHistory {
                ProgressView("Lade Verlauf …")
            } else if let session = viewModel.currentSession, let notice = viewModel.notice {
                // Fehler + leerer Verlauf: Fehlerzustand statt Leerzustand.
                Image(systemName: "wifi.slash")
                    .font(.largeTitle)
                    .foregroundStyle(DesignTokens.Palette.secondaryLabel)

                Text(notice)
                    .font(DesignTokens.Typography.callout)
                    .foregroundStyle(DesignTokens.Palette.label)
                    .fixedSize(horizontal: false, vertical: true)

                Button("Erneut laden") {
                    Task { await viewModel.openSession(session) }
                }
                .buttonStyle(.bordered)
                .accessibilityLabel("Verlauf erneut laden")
            } else if let session = viewModel.currentSession {
                Image(systemName: "text.bubble")
                    .font(.largeTitle)
                    .foregroundStyle(DesignTokens.Palette.secondaryLabel)

                Text("Noch keine Nachrichten in dieser Unterhaltung.")
                    .font(DesignTokens.Typography.callout)
                    .foregroundStyle(DesignTokens.Palette.secondaryLabel)
                    .fixedSize(horizontal: false, vertical: true)

                Button("Erneut laden") {
                    Task { await viewModel.openSession(session) }
                }
                .buttonStyle(.bordered)
                .accessibilityLabel("Verlauf erneut laden")
            } else {
                Image(systemName: "bubble.left.and.bubble.right")
                    .font(.largeTitle)
                    .foregroundStyle(DesignTokens.Palette.secondaryLabel)

                Text("Frag Hermes")
                    .font(DesignTokens.Typography.headline)

                Text(
                    "Der Chat spricht mit Hermes über den Server. "
                    + "To-Dos, Einkauf und Wochenplan beantwortet Hermes über seine Werkzeuge."
                )
                .font(DesignTokens.Typography.callout)
                .foregroundStyle(DesignTokens.Palette.secondaryLabel)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, DesignTokens.Spacing.xl)
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy) {
        withAnimation(.easeOut(duration: 0.2)) {
            proxy.scrollTo(bottomAnchor, anchor: .bottom)
        }
    }

    // MARK: Eingabe

    private var composer: some View {
        HStack(alignment: .bottom, spacing: DesignTokens.Spacing.s) {
            TextField("Nachricht an Hermes", text: $viewModel.draft, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1...4)
                .padding(.horizontal, DesignTokens.Spacing.m)
                .padding(.vertical, DesignTokens.Spacing.s)
                .background(
                    DesignTokens.Palette.secondaryBackground,
                    in: RoundedRectangle(
                        cornerRadius: DesignTokens.Radius.card,
                        style: .continuous
                    )
                )
                .focused($isInputFocused)
                .submitLabel(.send)
                .onSubmit {
                    viewModel.send()
                }
                .disabled(viewModel.isStreaming || viewModel.isLoadingHistory)
                .accessibilityLabel("Nachricht an Hermes")

            if viewModel.isStreaming {
                Button {
                    viewModel.cancel()
                } label: {
                    Image(systemName: "stop.circle.fill")
                        .font(.title2)
                        .foregroundStyle(DesignTokens.Palette.danger)
                }
                .accessibilityLabel("Antwort abbrechen")
            } else {
                Button {
                    viewModel.send()
                } label: {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.title2)
                }
                .disabled(!viewModel.canSend)
                .accessibilityLabel("Nachricht senden")
            }
        }
        .padding(DesignTokens.Spacing.l)
        .background(DesignTokens.Palette.groupedBackground)
    }
}

#Preview("ChatView") {
    ChatView()
        .environmentObject(VoiceCoordinator())
}
