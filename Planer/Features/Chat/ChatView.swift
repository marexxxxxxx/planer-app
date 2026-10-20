//
//  ChatView.swift
//  Planer
//
//  Tab 1 „Chat“: Verlauf, Eingabe, Werkzeugaufrufe — Oberfläche über
//  `ChatViewModel` (spec-ios §1/I3).
//

import SwiftUI

/// Chat-Tab mit nativem MCP-Client.
///
/// Zweck: zeigt den Verlauf als Blasen, Werkzeugaufrufe als Badge und macht
/// Verbindungszustand, Abbruch und Fehler sichtbar.
/// Grenze: kein Netzwerk und keine Fachlogik — beides liegt im `ChatViewModel`;
/// die View rendert nur dessen Zustand. Die konkrete Streaming-Anbindung ist
/// eine `[ANNAHME]` im `ChatStreamProvider`, nicht hier.
struct ChatView: View {

    @StateObject private var viewModel = ChatViewModel()
    @FocusState private var isInputFocused: Bool

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
                composer
            }
            .background(DesignTokens.Palette.groupedBackground)
            .navigationTitle("Chat")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    optionsMenu
                }
            }
            .task {
                await viewModel.connect()
            }
            .onDisappear {
                viewModel.disconnect()
            }
        }
    }

    // MARK: Status

    private var statusBar: some View {
        HStack(spacing: DesignTokens.Spacing.xs) {
            Circle()
                .fill(statusColor)
                .frame(width: 8, height: 8)

            Text(viewModel.statusText)
                .font(DesignTokens.Typography.footnote)
                .foregroundStyle(DesignTokens.Palette.secondaryLabel)
                .lineLimit(1)
                .accessibilityLabel(Text("Verbindungsstatus: \(viewModel.statusText)"))

            Spacer(minLength: DesignTokens.Spacing.s)

            if case .failed = viewModel.connection {
                Button("Erneut verbinden") {
                    Task { await viewModel.connect() }
                }
                .font(DesignTokens.Typography.footnote)
            }
        }
        .padding(.horizontal, DesignTokens.Spacing.l)
        .padding(.vertical, DesignTokens.Spacing.xs)
        .background(DesignTokens.Palette.groupedBackground)
    }

    private var statusColor: Color {
        switch viewModel.connection {
        case .idle:
            return DesignTokens.Palette.secondaryLabel
        case .connecting:
            return DesignTokens.Palette.secondaryLabel
        case .ready:
            return DesignTokens.Palette.success
        case .failed:
            return DesignTokens.Palette.danger
        }
    }

    private var optionsMenu: some View {
        Menu {
            Button("Verlauf löschen", systemImage: "trash") {
                viewModel.clear()
            }
            .disabled(viewModel.entries.isEmpty)

            Button("Verbindung trennen", systemImage: "bolt.slash") {
                viewModel.disconnect()
            }
            .disabled(!viewModel.isConnected)
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .accessibilityLabel("Chat-Optionen")
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
            .onChange(of: viewModel.entries.count) { _, _ in
                scrollToBottom(proxy)
            }
            .onChange(of: viewModel.entries.last?.text) { _, _ in
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
            MessageBubbleView(role: .agent, text: entry.text)
        case .tool:
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
                ToolCallBadge(
                    name: entry.toolName ?? "Werkzeug",
                    status: entry.toolStatus ?? .running,
                    detail: entry.text.isEmpty ? nil : entry.text
                )

                // Design-Spec §4/Tab 1: schreibende Aufrufe werden erst nach
                // einem Tipp auf „Ausführen“ an Hermes gesendet.
                if entry.awaitsConfirmation {
                    ToolConfirmationChips(
                        toolName: entry.toolName ?? "Werkzeug",
                        onApprove: { viewModel.approveToolCall(entry.id) },
                        onDecline: { viewModel.declineToolCall(entry.id) }
                    )
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.s) {
            Image(systemName: "bubble.left.and.bubble.right")
                .font(.largeTitle)
                .foregroundStyle(DesignTokens.Palette.secondaryLabel)

            Text("Frag Hermes")
                .font(DesignTokens.Typography.headline)

            Text(
                "Der Chat spricht über den nativen MCP-Client mit Hermes. "
                + "To-Dos, Einkauf und Wochenplan beantwortet Hermes über seine Werkzeuge."
            )
            .font(DesignTokens.Typography.callout)
            .foregroundStyle(DesignTokens.Palette.secondaryLabel)
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, DesignTokens.Spacing.xl)
        .accessibilityElement(children: .combine)
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
                .disabled(viewModel.isStreaming)
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
}
