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

    @ObservedObject private var viewModel = ChatViewModel.shared
    @EnvironmentObject private var voice: VoiceCoordinator
    @FocusState private var isInputFocused: Bool
    @State private var showsSessions = false
    /// Die Freigabe, deren Bestätigungsdialog offen ist. Genau **ein**
    /// Presenter im Baum (§3.3.4).
    @State private var confirmingApprovalEntryID: UUID?

    /// Anker für das automatische Scrollen ans Ende.
    private let bottomAnchor = "chat-bottom"

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                statusBar
                phaseBar
                if let notice = viewModel.notice {
                    noticeBar(notice)
                }
                transcript
                Divider()
                VoiceControlBar()
                composer
            }
            .background(DesignTokens.Palette.groupedBackground)
            .confirmationDialog(
                "Befehl ausführen?",
                isPresented: Binding(
                    get: { confirmingApprovalEntryID != nil },
                    set: { isPresented in
                        if !isPresented { confirmingApprovalEntryID = nil }
                    }
                ),
                titleVisibility: .visible
            ) {
                Button("Ausführen", role: .destructive) {
                    guard let entryID = confirmingApprovalEntryID else { return }
                    confirmingApprovalEntryID = nil
                    Task { await viewModel.decideApproval(entryID, choice: .once) }
                }
                Button("Abbrechen", role: .cancel) {
                    confirmingApprovalEntryID = nil
                }
            } message: {
                if let entryID = confirmingApprovalEntryID,
                   let command = viewModel.approvalCommand(for: entryID) {
                    Text(command)
                } else {
                    Text("Der Befehl ist nicht mehr verfügbar.")
                }
            }
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

    // MARK: Live-Status (§3.4)

    /// Die Phasen-Zeile: für die gesamte Dauer von `isStreaming` sichtbar,
    /// außerhalb des Scrollinhalts, zusätzlich zu `WorkingIndicatorView` (O5).
    @ViewBuilder
    private var phaseBar: some View {
        if let phase = viewModel.turnPhase {
            ChatPhaseStatusView(phase: phase)
        }
    }

    private func noticeBar(_ notice: String) -> some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.s) {
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

            // O3: nach einem Strom-Timeout ist der Verlauf der Anschluss an den
            // serverseitig weiterlaufenden Turn.
            if viewModel.offersHistoryReload {
                Button("Verlauf neu laden") {
                    Task { await viewModel.reloadHistory() }
                }
                .font(DesignTokens.Typography.footnote)
                .buttonStyle(.borderless)
                .accessibilityLabel("Verlauf neu laden")
            }
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

                    if viewModel.showsWorkingIndicator, let startedAt = viewModel.turnStartedAt {
                        WorkingIndicatorView(startedAt: startedAt)
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
        // §3.3.6 / §4.6: die Uhr liegt um Zustandstext und Chips, damit
        // „Abgelaufen“ nach der Frist ohne Timer und ohne Nutzeraktion
        // erscheint. Die Reihenfolge der Zeilen folgt §3.3.2.
        TimelineView(.periodic(from: entry.approvalReceivedAt ?? .distantPast, by: 1)) { context in
            let approvalPhase = ApprovalPhase.derive(
                stored: entry.approvalPhase,
                receivedAt: entry.approvalReceivedAt,
                timeout: TimeInterval(viewModel.approvalTimeoutSeconds),
                now: context.date
            )

            VStack(alignment: .leading, spacing: DesignTokens.Spacing.s) {
                HStack(spacing: DesignTokens.Spacing.xs) {
                    Image(systemName: "hand.raised")
                        .font(DesignTokens.Typography.footnote)
                        .foregroundStyle(DesignTokens.Palette.secondaryLabel)

                    Text("Freigabe")
                        .font(DesignTokens.Typography.footnote)
                        .foregroundStyle(DesignTokens.Palette.label)

                    Spacer(minLength: DesignTokens.Spacing.xs)

                    Text(approvalPhase.label)
                        .font(DesignTokens.Typography.footnote)
                        .foregroundStyle(DesignTokens.Palette.secondaryLabel)
                }

                if entry.approvalCommandTooLong {
                    // FF-4: wer den Befehl nicht lesen kann, darf ihn nicht
                    // autorisieren — deshalb wird er hier gar nicht gerendert.
                    Text(
                        "Der Befehl ist zu lang, um ihn geprüft freizugeben "
                        + "(\(entry.approval?.command?.count ?? 0) Zeichen)."
                    )
                    .font(DesignTokens.Typography.footnote)
                    .foregroundStyle(DesignTokens.Palette.label)
                    .fixedSize(horizontal: false, vertical: true)
                } else if let command = entry.approval?.command, !command.isEmpty {
                    // A1: der Befehl wird vollständig gerendert — kein `lineLimit`.
                    Text(command)
                        .font(DesignTokens.Typography.footnote.monospaced())
                        .foregroundStyle(DesignTokens.Palette.label)
                        .textSelection(.enabled)
                        .copyableAction(entry.approval?.command)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    Button("Befehl kopieren") {
                        TextClipboard.copy(entry.approval?.command)
                    }
                    .font(DesignTokens.Typography.footnote)
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Befehl kopieren")
                }

                if !entry.text.isEmpty {
                    // F4: die Klartext-Folge hat eine Quelle — der beim
                    // Empfang gespeicherte `Entry.text` (§3.3.2, C5).
                    Text(entry.text)
                        .font(DesignTokens.Typography.footnote)
                        .foregroundStyle(DesignTokens.Palette.secondaryLabel)
                        .fixedSize(horizontal: false, vertical: true)
                        .copyableText(entry.text)
                } else {
                    Text("Keine Beschreibung vom Server. Der Befehl oben wird unverändert ausgeführt.")
                        .font(DesignTokens.Typography.footnote)
                        .foregroundStyle(DesignTokens.Palette.secondaryLabel)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Text("Werkzeug: \(entry.approvalToolName ?? "vom Server nicht benannt")")
                    .font(DesignTokens.Typography.footnote)
                    .foregroundStyle(DesignTokens.Palette.secondaryLabel)
                    .fixedSize(horizontal: false, vertical: true)

                if let approval = entry.approval {
                    Text(approval.runID)
                        .font(DesignTokens.Typography.footnote.monospaced())
                        .foregroundStyle(DesignTokens.Palette.secondaryLabel)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .copyableText(approval.runID)
                        .accessibilityLabel(Text("Run-ID \(approval.runID)"))
                }

                if let approval = entry.approval, !entry.approvalResolved {
                    ToolConfirmationChips(
                        approval: approval,
                        phase: approvalPhase,
                        allowsExecute: !entry.approvalCommandTooLong,
                        onRequestExecute: {
                            confirmingApprovalEntryID = entry.id
                        },
                        onDeny: {
                            Task { await viewModel.decideApproval(entry.id, choice: .deny) }
                        }
                    )
                }

                Text(
                    "Die Freigabe verfällt \(viewModel.approvalTimeoutSeconds) s nach dem Ereignis. "
                    + "Ohne Antwort führt der Server den Befehl nicht aus."
                )
                .font(DesignTokens.Typography.footnote)
                .foregroundStyle(DesignTokens.Palette.secondaryLabel)
                .fixedSize(horizontal: false, vertical: true)
            }
            .padding(DesignTokens.Spacing.m)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                DesignTokens.Palette.secondaryBackground,
                in: RoundedRectangle(cornerRadius: DesignTokens.Radius.card, style: .continuous)
            )
            .accessibilityElement(children: .contain)
        }
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
