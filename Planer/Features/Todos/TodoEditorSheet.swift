//
//  TodoEditorSheet.swift
//  Planer
//
//  Anlege-Formular des To-Dos-Tabs (WP I4).
//

import SwiftUI

/// Formular für ein neues To-Do.
///
/// Zweck: Titel (1…200 Zeichen), optionale Details, Priorität und optionales
/// Fälligkeitsdatum erfassen; die Grenzen stammen aus `TaskCreate` (§2.2).
/// Grenze: kein Bearbeiten bestehender Einträge — der Tab bietet Abhaken,
/// Anlegen und Löschen.
struct TodoEditorSheet: View {

    @ObservedObject var viewModel: TodosViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var title = ""
    @State private var details = ""
    @State private var priority: TodoPriority = .normal
    @State private var hasDueDate = false
    @State private var dueDate = Date()
    @State private var isSaving = false
    @State private var errorText: String?
    @FocusState private var titleFocused: Bool

    private var draft: TodoDraft {
        TodoDraft(
            title: title,
            details: details,
            priority: priority.rawValue,
            dueDate: hasDueDate ? TodoFormatting.normalizedDay(dueDate) : nil
        )
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Titel") {
                    TextField("Was ist zu tun?", text: $title, axis: .vertical)
                        .lineLimit(1...3)
                        .focused($titleFocused)

                    if title.count > 200 {
                        Label("Höchstens 200 Zeichen.", systemImage: "exclamationmark.circle")
                            .font(DesignTokens.Typography.footnote)
                            .foregroundStyle(DesignTokens.Palette.secondaryLabel)
                    }
                }

                Section("Details") {
                    TextField("Beschreibung (optional)", text: $details, axis: .vertical)
                        .lineLimit(2...5)
                }

                Section("Priorität") {
                    Picker("Priorität", selection: $priority) {
                        ForEach(TodoPriority.allCases) { value in
                            Text(value.label).tag(value)
                        }
                    }
                    .pickerStyle(.segmented)
                }

                Section("Fälligkeit") {
                    Toggle("Fälligkeitsdatum", isOn: $hasDueDate)

                    if hasDueDate {
                        DatePicker("Datum", selection: $dueDate, displayedComponents: .date)
                    }
                }

                if let errorText {
                    Section {
                        Label(errorText, systemImage: "exclamationmark.triangle")
                            .font(DesignTokens.Typography.footnote)
                            .foregroundStyle(DesignTokens.Palette.secondaryLabel)
                    }
                }
            }
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle("Neues To-Do")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Abbrechen") {
                        dismiss()
                    }
                    .disabled(isSaving)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Anlegen") {
                        Task { await save() }
                    }
                    .disabled(!draft.isValid || isSaving)
                }
            }
            .interactiveDismissDisabled(isSaving)
            .onAppear {
                titleFocused = true
            }
        }
    }

    @MainActor
    private func save() async {
        errorText = nil
        isSaving = true
        defer { isSaving = false }

        if let message = await viewModel.create(draft) {
            errorText = message
        } else {
            dismiss()
        }
    }
}

#Preview("TodoEditorSheet") {
    TodoEditorSheet(viewModel: TodosViewModel())
}
