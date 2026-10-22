//
//  ChatSettingsSection.swift
//  Planer
//
//  Einstellungs-Sektion „Chat“: Zeitlimits und Hermes-Profil
//  (spec-chat Rev 6 §4.9, O1/O7/O8).
//

import SwiftUI

/// Sektion „Chat“ im Einstellungs-Tab.
///
/// Zweck: die beiden Zeitlimits und das Hermes-Profil ändern — und zwar
/// ausschließlich über `ChatPreferences`, damit View und `ChatViewModel` keine
/// zweite Wahrheit über dieselben Werte haben (§3.2.3).
/// Grenze: keine Chat-Fachlogik und kein Senden; die Profilliste wird nur
/// gelesen. Ob ein Profil ausgeliefert wird, entscheidet der Server beim
/// ersten Senden (§3.7.4) — diese Sektion behauptet es nicht.
///
/// Serverbegriff für „ausgeliefert“: `served_profiles` in
/// `gateway_state.json`; ein Präfix, das dort nicht vorkommt, antwortet mit
/// `404` (F-R6-4).
struct ChatSettingsSection: View {

    /// Zustand der Profilliste. Drei Fälle statt eines `nil`, weil „lädt noch“
    /// und „nicht erreichbar“ verschiedene Oberflächen ergeben (F-R6-6).
    private enum ProfileList: Equatable {
        case loading
        case loaded([HermesProfile])
        case unreachable
    }

    /// Eine Zeile des Profil-Pickers: `id` ist der gespeicherte Wert, `label`
    /// die Anzeige.
    private struct ProfileOption: Identifiable, Equatable {
        let id: String
        let label: String
    }

    /// Schrittweiten: 60 s liegt auf dem Raster der Untergrenze, 5 s lässt den
    /// Default von 30 s in einem Schritt erreichen.
    private enum Step {
        static let streamIdle = 60
        static let rest = 5
    }

    /// Die Regel wird wörtlich angezeigt, wenn `normalizeProfile` ablehnt.
    private static let profileNameRule = "Profilname: nur a–z, 0–9, _ und -, 1–64 Zeichen."

    @ObservedObject private var preferences = ChatPreferences.shared

    @State private var profileList: ProfileList = .loading
    /// Eingabe der Handeingabe; bleibt bei Ablehnung stehen (F-R6-7).
    @State private var manualProfile = ""
    @State private var message: String?

    var body: some View {
        Section {
            // Der Stepper kann den Bereich nicht verlassen; ein von außen
            // geklemmter Wert ist an der Wertanzeige ablesbar (F-R6-8).
            Stepper(
                value: Binding(
                    get: { preferences.streamIdleTimeout },
                    set: { preferences.setStreamIdleTimeout($0) }
                ),
                in: ChatPreferences.streamIdleTimeoutRange,
                step: Step.streamIdle
            ) {
                LabeledContent {
                    Text("\(preferences.streamIdleTimeout) s")
                        .monospacedDigit()
                } label: {
                    Text("Zeitlimit Antwortstrom")
                }
            }

            Text(
                hint(
                    range: ChatPreferences.streamIdleTimeoutRange,
                    default: ChatPreferences.defaultStreamIdleTimeout
                )
            )
            .font(DesignTokens.Typography.footnote)
            .foregroundStyle(DesignTokens.Palette.secondaryLabel)

            Stepper(
                value: Binding(
                    get: { preferences.restTimeout },
                    set: { preferences.setRestTimeout($0) }
                ),
                in: ChatPreferences.restTimeoutRange,
                step: Step.rest
            ) {
                LabeledContent {
                    Text("\(preferences.restTimeout) s")
                        .monospacedDigit()
                } label: {
                    Text("Zeitlimit Serveranfragen")
                }
            }

            Text(
                hint(
                    range: ChatPreferences.restTimeoutRange,
                    default: ChatPreferences.defaultRestTimeout
                )
            )
            .font(DesignTokens.Typography.footnote)
            .foregroundStyle(DesignTokens.Palette.secondaryLabel)

            profileRow

            if let message {
                Text(message)
                    .font(DesignTokens.Typography.footnote)
                    .foregroundStyle(DesignTokens.Palette.secondaryLabel)
            }
        } header: {
            Text("Chat")
        } footer: {
            Text(
                "Nur ausgelieferte Profile funktionieren. Der Server nennt ein nicht "
                + "ausgeliefertes Profil beim ersten Senden. Schritt auf dem Server: "
                + "hermes gateway migrate --multiplex (danach das Gateway neu starten)."
            )
        }
        .task {
            await loadProfiles()
        }
    }

    /// Sichtbarer Bereich und Default stehen unter jedem Stepper — die Zahl im
    /// Code ist keine Auskunft für den Nutzer.
    private func hint(range: ClosedRange<Int>, default defaultValue: Int) -> String {
        "\(range.lowerBound)–\(range.upperBound) s, Standard \(defaultValue) s"
    }

    // MARK: Profil

    @ViewBuilder
    private var profileRow: some View {
        switch profileList {
        case .loading:
            LabeledContent("Hermes-Profil") {
                ProgressView()
            }

        case .loaded(let profiles):
            Picker("Hermes-Profil", selection: profileSelection) {
                Text("Standard (ohne Profil)").tag("")
                ForEach(profileOptions(profiles)) { option in
                    Text(option.label).tag(option.id)
                }
            }

        case .unreachable:
            TextField("Profilname", text: $manualProfile)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()

            Button("Übernehmen") {
                applyManualProfile()
            }

            Text("Profilliste nicht erreichbar — Profilnamen von Hand eintragen.")
                .font(DesignTokens.Typography.footnote)
                .foregroundStyle(DesignTokens.Palette.secondaryLabel)
        }
    }

    /// Der Setter prüft über `ChatPreferences.normalizeProfile`; ein ungültiger
    /// Wert speichert nichts und hinterlässt die vorherige Auswahl.
    private var profileSelection: Binding<String> {
        Binding(
            get: { preferences.profile },
            set: { newValue in
                if preferences.setProfile(newValue) {
                    message = nil
                } else {
                    message = Self.profileNameRule
                }
            }
        )
    }

    /// Ein von Hand gesetztes Profil kann fehlen, wenn die Liste erst später
    /// erreichbar ist. Ohne diesen Eintrag zeigte der Picker eine leere Auswahl,
    /// obwohl ein Profil gespeichert ist.
    private func profileOptions(_ profiles: [HermesProfile]) -> [ProfileOption] {
        var options = profiles.map { ProfileOption(id: $0.name, label: $0.label) }
        let current = preferences.profile
        if !current.isEmpty, !options.contains(where: { $0.id == current }) {
            options.append(ProfileOption(id: current, label: current))
        }
        return options
    }

    private func applyManualProfile() {
        guard preferences.setProfile(manualProfile) else {
            message = Self.profileNameRule
            return
        }
        manualProfile = preferences.profile
        message = nil
    }

    /// Liest `GET /api/profiles` über die Dashboard-Oberfläche (O8).
    ///
    /// Jede Störung — nicht konfiguriert, offline, kein JSON — führt zur
    /// Handeingabe; der Grund ist für den Nutzer nicht unterscheidbar und wird
    /// deshalb nicht behauptet. Eine leere Liste gibt es dadurch nicht.
    /// Explizit `@MainActor`, weil die Präferenz-Klasse main-actor-isoliert ist.
    @MainActor
    private func loadProfiles() async {
        let directory = HermesProfileDirectory(configuration: preferences.configuration)
        do {
            profileList = .loaded(try await directory.profiles())
        } catch {
            // Vorbelegung mit der gespeicherten Auswahl, damit das Feld den
            // Ist-Zustand zeigt statt leer zu starten.
            manualProfile = preferences.profile
            profileList = .unreachable
        }
    }
}

#Preview("ChatSettingsSection") {
    Form {
        ChatSettingsSection()
    }
}
