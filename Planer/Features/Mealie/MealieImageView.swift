//
//  MealieImageView.swift
//  Planer
//
//  Authentifizierter Bild-Loader des Rezepte-Tabs.
//

import SwiftUI
import UIKit

/// In-Memory-Cache bereits geladener Rezeptbilder.
///
/// Zweck: beim Scrollen und beim Wechsel zwischen Wochenplan und Bibliothek
/// nicht erneut laden.
/// Grenze: reiner Speicher; nach einem App-Neustart ist der Cache leer.
@MainActor
final class MealieImageCache {
    static let shared = MealieImageCache()

    private let cache = NSCache<NSString, NSData>()

    init(countLimit: Int = 64) {
        cache.countLimit = countLimit
    }

    func data(for recipeID: String) -> Data? {
        cache.object(forKey: recipeID as NSString).map { $0 as Data }
    }

    func store(_ data: Data, for recipeID: String) {
        cache.setObject(data as NSData, forKey: recipeID as NSString)
    }
}

/// Bild-Loader der Mealie-Schicht.
///
/// Zweck: Die Bytes über `NetworkClient` holen — nur dort werden
/// Cloudflare-Access- und Bearer-Header injiziert (spec-ios §8) — und
/// erfolgreiche Antworten im Speicher halten.
/// Grenze: kein Schreiben auf die Platte.
@MainActor
enum MealieImageLoader {
    static func cachedData(for recipeID: String) -> Data? {
        MealieImageCache.shared.data(for: recipeID)
    }

    static func data(for recipeID: String, repository: MealieRepository) async throws -> Data {
        if let cached = cachedData(for: recipeID) {
            return cached
        }
        let data = try await repository.fetchImageData(forRecipeID: recipeID)
        MealieImageCache.shared.store(data, for: recipeID)
        return data
    }
}

/// Rezeptbild mit Platzhalter bei fehlender oder fehlgeschlagener Antwort.
struct MealieImageView: View {
    private enum Phase: Equatable {
        case loading
        case loaded(Data)
        case failed
    }

    let recipeID: String
    let repository: MealieRepository
    /// Adresse, die die Zeile mit der **damaligen** Basis gebildet hat. Sie
    /// steuert ausschließlich den Neustart des Loaders: wird die Basis-URL in
    /// den Einstellungen hinterlegt oder korrigiert, ändert sich der Wert und
    /// `.task(id:)` startet den Ladeversuch erneut — ohne App-Neustart
    /// (MARAAA-140/M1). Der Request selbst fragt die Basis im Repository und
    /// im `NetworkClient` bei jedem Zugriff neu ab.
    let imageURL: URL?

    @State private var phase: Phase = .loading

    /// Identität des Ladevorgangs: Rezept-ID plus Basis, mit der die Zeile
    /// gebaut wurde.
    private var loadKey: String {
        "\(recipeID)|\(imageURL?.absoluteString ?? "keine-basis")"
    }

    var body: some View {
        content
            .frame(width: DesignTokens.Size.thumbnail, height: DesignTokens.Size.thumbnail)
            .background(DesignTokens.Palette.tertiaryBackground)
            .clipShape(
                RoundedRectangle(cornerRadius: DesignTokens.Radius.card, style: .continuous)
            )
            .accessibilityHidden(true)
            .task(id: loadKey) {
                await load()
            }
    }

    @ViewBuilder
    private var content: some View {
        switch phase {
        case .loading:
            ProgressView()
        case .loaded(let data):
            if let image = UIImage(data: data) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                placeholder
            }
        case .failed:
            placeholder
        }
    }

    private var placeholder: some View {
        Image(systemName: "fork.knife")
            .foregroundStyle(DesignTokens.Palette.secondaryLabel)
    }

    @MainActor
    private func load() async {
        if let cached = MealieImageLoader.cachedData(for: recipeID) {
            phase = .loaded(cached)
            return
        }
        phase = .loading
        do {
            phase = .loaded(try await MealieImageLoader.data(for: recipeID, repository: repository))
        } catch APIError.cancelled {
            // Die Ansicht ist verschwunden; ein Fehlerzustand wäre hier falsch.
            return
        } catch {
            phase = .failed
        }
    }
}
