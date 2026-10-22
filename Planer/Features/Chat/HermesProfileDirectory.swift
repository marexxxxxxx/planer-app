//
//  HermesProfileDirectory.swift
//  Planer
//
//  Profilliste der Hermes-Dashboard-Oberfläche (spec-chat Rev 6 §4.5, O8).
//

import Foundation

/// Ein Hermes-Profil aus `GET /api/profiles`.
///
/// Zweck: `name` ist der Wert des Pfad-Präfixes; `display_name` nur die
/// Anzeige. Unbekannte Wire-Felder bleiben ungelesen.
struct HermesProfile: Identifiable, Decodable, Equatable, Sendable {
    let name: String
    let displayName: String?
    let isDefault: Bool

    var id: String { name }

    /// Anzeigename: `displayName`, wenn nicht leer, sonst `name`.
    var label: String {
        guard let displayName, !displayName.isEmpty else { return name }
        return displayName
    }

    private enum CodingKeys: String, CodingKey {
        case name
        case displayName = "display_name"
        case isDefault = "is_default"
    }
}

/// Hülle der Antwort: `{"profiles":[…]}`.
struct HermesProfilePage: Decodable, Sendable {
    let profiles: [HermesProfile]
}

/// Liest die Profilliste der Dashboard-Oberfläche.
///
/// Zweck: keine fest verdrahtete Namensliste — die Namen sind
/// installationsabhängig (O8).
/// Grenze: liest nur; jede Störung wird weitergeworfen, damit die Oberfläche
/// auf die Handeingabe wechseln kann (F-R6-6).
struct HermesProfileDirectory: Sendable {

    private let networkClient: NetworkClient

    init(
        configuration: HermesChatConfiguration = HermesChatConfiguration(),
        networkClient: NetworkClient? = nil
    ) {
        self.networkClient = networkClient ?? NetworkClient(timeout: configuration.restTimeout)
    }

    /// `GET /api/profiles` über den Dienst `.dashboard`; die Route gehört zur
    /// Dashboard-Oberfläche, nicht zum Chat-Vertrag.
    func profiles() async throws -> [HermesProfile] {
        let request = APIRequest(method: .get, path: "/api/profiles")
        let page = try await networkClient.send(
            request,
            for: .dashboard,
            as: HermesProfilePage.self
        )
        return page.profiles
    }
}
