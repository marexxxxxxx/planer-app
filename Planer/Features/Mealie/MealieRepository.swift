//
//  MealieRepository.swift
//  Planer
//
//  Mealie-Zugriff und Read-through-Cache des Rezepte-Tabs (spec-ios §2.4, §3.3).
//

import Foundation
import SwiftData

/// Spricht Mealie v2 direkt an und spiegelt Wochenplan und Bibliothek in den
/// SwiftData-Cache aus I2.
///
/// Zweck: eine Stelle für die Lese-Pfade aus §2.4 (`/households/mealplans`,
/// `/recipes`, `/recipes/{slug}`), die Normalformen aus §3.4 und die
/// Cache-Regel aus §3.3 (Server autoritativ, reiner Lese-Cache).
/// Grenze: kein Schreibpfad nach Mealie (AD-8); „Zutaten auf Einkaufsliste“
/// liegt im ViewModel und schreibt ausschließlich nach Grocy.
@MainActor
final class MealieRepository {

    /// Pfade relativ zur Basis-URL `https://<mealie>/api` (§2.4).
    enum Path {
        static let mealPlans = "/households/mealplans"
        static let recipes = "/recipes"
    }

    /// Präfix der Cache-IDs von Wochenplan-Zeilen.
    ///
    /// Die Cache-Entity `Recipe` (I2) hat einen eindeutigen `id`; ein Rezept
    /// kann in der Bibliothek **und** mehrfach im Wochenplan stehen. Ohne
    /// Präfix würde jeder weitere Plan-Eintrag den vorherigen überschreiben.
    static let planCachePrefix = MealieMealPlanItem.cachePrefix

    private let client: NetworkClient
    private let context: ModelContext
    private let keychain: KeychainManager
    private let now: () -> Date
    private let calendar: Calendar

    /// Origin der Mealie-Instanz für relative Bildpfade; wird **einmal pro
    /// Ladevorgang** aus der Keychain aufgelöst (MARAAA-144).
    ///
    /// Bewusst nicht im Init gelesen: wer eine Basis-URL erst nach dem Öffnen
    /// des Rezepte-Tabs hinterlegt oder korrigiert, sähe sonst bis zum
    /// App-Neustart nur Platzhalter (MARAAA-140/M1). Der Aufrufer reicht den
    /// Wert an die Zeilenbildung weiter, damit nicht jede Zeile erneut vier
    /// Keychain-Items liest. `nil`, solange keine gültige Basis in der
    /// Keychain liegt (dann bleibt das Bild aus).
    func resolveImageBaseURL() -> URL? {
        (try? ServiceConfiguration.load(.mealie, keychain: keychain))?.baseURL
    }

    init(
        client: NetworkClient = NetworkClient(),
        context: ModelContext,
        keychain: KeychainManager = KeychainManager(),
        now: @escaping () -> Date = Date.init,
        calendar: Calendar = .current
    ) {
        self.client = client
        self.context = context
        self.keychain = keychain
        self.now = now
        self.calendar = calendar
    }

    // MARK: - Netz: Wochenplan

    /// `GET /households/mealplans?start_date&end_date` für die Woche um `date`.
    ///
    /// Die Antwort ist paginiert (`PlanEntryPagination`); alle Seiten werden
    /// gelesen, bis `total_pages` erreicht ist.
    func fetchWeek(containing date: Date) async throws -> [MealieMealPlanItem] {
        guard let range = MealieDay.weekRange(containing: date, calendar: calendar) else {
            return []
        }
        var page = 1
        var totalPages = 1
        var entries: [MealiePlanEntry] = []
        while page <= totalPages {
            let response = try await client.send(
                APIRequest(
                    method: .get,
                    path: Path.mealPlans,
                    query: [
                        URLQueryItem(name: "start_date", value: MealieDay.text(for: range.start, calendar: calendar)),
                        URLQueryItem(name: "end_date", value: MealieDay.text(for: range.end, calendar: calendar)),
                        URLQueryItem(name: "page", value: String(page)),
                        URLQueryItem(name: "perPage", value: String(Self.mealPlanPageSize))
                    ]
                ),
                for: .mealie,
                as: MealieMealPlanPage.self
            )
            entries.append(contentsOf: response.items)
            // `max(_, page)` hält die Schleife auch dann endlich, wenn der
            // Server `total_pages = 0` meldet, aber Einträge liefert.
            totalPages = max(response.pagination.totalPages, page)
            page += 1
        }
        var unique: [MealieMealPlanItem] = []
        var seen = Set<String>()
        for item in entries.compactMap({ $0.normalize() }) {
            // Die Cache-ID enthält bei Freitext die Server-ID, bei
            // Rezeptzeilen Tag, Mahlzeit und Rezept-ID; nur ein echter
            // Doppeleintrag aus der Paginierung fällt hier heraus, zwei
            // inhaltsgleiche Freitext-Zeilen bleiben zwei Zeilen (MARAAA-140/N2).
            guard seen.insert(item.id).inserted else { continue }
            unique.append(item)
        }
        return unique
    }

    // MARK: - Netz: Bibliothek

    /// `GET /recipes?page&perPage&queryFilter&orderBy&orderDirection` (§2.4).
    ///
    /// `queryFilter` ist Mealies Filter-DSL, kein Freitext; die Suche wird
    /// deshalb als `name LIKE "%…%"` formuliert (docs.mealie.io, „Filtering“).
    func searchRecipes(query: String, page: Int, perPage: Int) async throws -> MealieRecipePage {
        var queryItems = [
            URLQueryItem(name: "page", value: String(page)),
            URLQueryItem(name: "perPage", value: String(perPage)),
            URLQueryItem(name: "orderBy", value: "name"),
            URLQueryItem(name: "orderDirection", value: "asc")
        ]
        if let filter = Self.nameFilter(for: query) {
            queryItems.append(URLQueryItem(name: "queryFilter", value: filter))
        }
        return try await client.send(
            APIRequest(method: .get, path: Path.recipes, query: queryItems),
            for: .mealie,
            as: MealieRecipePage.self
        )
    }

    /// Baut den `queryFilter`-Ausdruck der Namenssuche; `nil` bei leerer Suche.
    static func nameFilter(for query: String) -> String? {
        let trimmed = MealieText.trimmed(query)
        guard !trimmed.isEmpty else { return nil }
        // Anführungszeichen würden die Filter-Grammatik zerlegen; sie sind in
        // Rezeptnamen die einzigen Sonderzeichen, die Mealie nicht escapt.
        let sanitized = trimmed.replacingOccurrences(of: "\"", with: "")
        guard !sanitized.isEmpty else { return nil }
        return "name LIKE \"%\(sanitized)%\""
    }

    /// `GET /recipes/{slug}` — vollständige Zutatenliste eines Rezepts.
    ///
    /// Nicht in §2.4 aufgeführt, aber die einzige Mealie-v2-Quelle für
    /// `recipeIngredient[]` (RecipeSummary trägt keine Zutaten); §3.3 verlangt
    /// `ingredientsJSON` (siehe Abschlussbericht, ABWEICHUNG).
    ///
    /// Der `slug` stammt aus der Mealie-Antwort und wird vor der URL-Bildung als
    /// einzelnes Pfad-Segment prozentkodiert; `/` und `%` sind dabei ausgenommen,
    /// damit ein Serverwert keine zusätzlichen Segmente einschleusen kann
    /// (G2-Befund 10).
    func fetchIngredients(slug: String) async throws -> [MealieIngredient] {
        guard let segment = Self.pathSegment(slug) else {
            throw APIError.invalidRequest("Ungültiger Rezept-Slug.")
        }
        let detail = try await client.send(
            APIRequest(method: .get, path: "\(Path.recipes)/\(segment)"),
            for: .mealie,
            as: MealieRecipeDetail.self
        )
        return (detail.recipeIngredient ?? []).compactMap { $0.normalize() }
    }

    // MARK: - Normalform und Bilder

    /// Wandelt eine Rezept-Zusammenfassung in eine Zeile der Bibliothek.
    /// `nil`, wenn weder `id` noch `slug` vorhanden ist (nicht adressierbar).
    ///
    /// Die Bild-URL entsteht aus der Rezept-ID, nicht aus `summary.image`:
    /// Mealie liefert dort nur ein Cache-Token (Demo: `"4LEY"`). `imageBaseURL`
    /// wird vom Ladevorgang hereingereicht, damit die Keychain nicht pro Zeile
    /// gelesen wird (MARAAA-144).
    func row(from summary: MealieRecipeSummary, imageBaseURL: URL?) -> MealieRecipeRow? {
        let recipeID = MealieText.nonEmpty(summary.id)
        let identifier = recipeID ?? MealieText.nonEmpty(summary.slug)
        guard let identifier else { return nil }
        return MealieRecipeRow(
            id: identifier,
            name: MealieText.nonEmpty(summary.name) ?? MealieText.nonEmpty(summary.slug) ?? identifier,
            slug: MealieText.nonEmpty(summary.slug),
            imageID: recipeID,
            imageURL: recipeID.flatMap { Self.imageURL(forRecipeID: $0, baseURL: imageBaseURL) },
            totalTime: MealieText.nonEmpty(summary.totalTime),
            servings: summary.recipeServings ?? 0
        )
    }

    /// Erlaubte Schemes für Bild-URLs aus der Mealie-Antwort (G2-Befund 10).
    ///
    /// Nur `https`: `file:`/`data:`-URLs haben in einem Bild-Loader nichts zu
    /// suchen, und die Basis-URL ist seit I2 ohnehin https-pflichtig.
    static let allowedImageSchemes: Set<String> = ["https"]

    /// Bild-URL eines Rezepts: `{basis}/media/recipes/{id}/images/original.webp`.
    ///
    /// `baseURL` ist die API-Basis-URL (`…/api`, §2.4), die der Ladevorgang
    /// einmal auflöst und an alle Zeilen weitergibt (MARAAA-144). Die
    /// Rezept-ID wird als einzelnes Pfad-Segment kodiert, damit ein Serverwert
    /// keine zusätzlichen Segmente einschleusen kann. `nil` bei fehlender ID,
    /// fehlender Basis-URL oder nicht erlaubtem Scheme — ein fehlendes Bild
    /// ist kein Fehlerzustand des Tabs.
    static func imageURL(forRecipeID recipeID: String, baseURL: URL?) -> URL? {
        guard let base = baseURL,
              let scheme = base.scheme?.lowercased(),
              Self.allowedImageSchemes.contains(scheme),
              let host = base.host,
              let imagePath = Self.imagePath(forRecipeID: recipeID)
        else { return nil }
        let basePath = base.path(percentEncoded: true)
        let path = basePath.hasSuffix("/") ? String(basePath.dropLast()) : basePath
        var components = URLComponents()
        components.scheme = scheme
        components.host = host
        components.port = base.port
        components.percentEncodedPath = path + imagePath
        return components.url
    }

    /// Pfad der Bild-Route relativ zur API-Basis-URL; `nil` bei leerer ID.
    static func imagePath(forRecipeID recipeID: String) -> String? {
        guard let segment = pathSegment(recipeID) else { return nil }
        return "/media/recipes/\(segment)/images/original.webp"
    }

    /// Lädt die Bild-Bytes eines Rezepts über `NetworkClient.send`.
    ///
    /// Zweck: `NetworkClient` ist die einzige Stelle der Header-Injektion
    /// (spec-ios §8); nur so erreichen Cloudflare-Access- und Bearer-Header den
    /// Bild-Endpunkt. `URLSession.shared` kann das nicht.
    /// - Throws: `APIError`, wenn ID, Konfiguration oder Transport scheitern;
    ///   `APIError.emptyResponse` bei leerer Antwort.
    func fetchImageData(forRecipeID recipeID: String) async throws -> Data {
        guard let path = Self.imagePath(forRecipeID: recipeID) else {
            throw APIError.invalidRequest("Ungültige Rezept-ID.")
        }
        let data = try await client.send(
            APIRequest(
                method: .get,
                path: path,
                accept: "image/webp,image/*"
            ),
            for: .mealie
        )
        guard !data.isEmpty else { throw APIError.emptyResponse }
        return data
    }

    /// Kodiert einen Serverwert als einzelnes Pfad-Segment.
    ///
    /// `/` und `%` fliegen aus der erlaubten Menge: `/` würde zusätzliche
    /// Segmente erzeugen, ein rohes `%2F` würde beim Dekodieren wieder zu einem
    /// Trenner.
    static func pathSegment(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "/%")
        return trimmed.addingPercentEncoding(withAllowedCharacters: allowed)
    }

    // MARK: - Cache: Wochenplan

    /// Plan-Zeilen aus dem Cache, nach Tag und Mahlzeit sortiert.
    func cachedPlan() throws -> [MealieMealPlanItem] {
        let rows = try context.fetch(FetchDescriptor<Recipe>())
            .filter { $0.id.hasPrefix(Self.planCachePrefix) }
        return rows.compactMap { row -> MealieMealPlanItem? in
            guard let date = row.date else { return nil }
            return MealieMealPlanItem(
                date: MealieDay.text(for: date, calendar: calendar),
                mealType: row.mealType,
                recipeID: Self.recipeID(fromPlanCacheID: row.id),
                entryID: Self.entryID(fromPlanCacheID: row.id),
                recipeName: row.name,
                recipeScale: row.recipeScale
            )
        }
        .sorted {
            $0.date == $1.date ? $0.sortIndex < $1.sortIndex : $0.date < $1.date
        }
    }

    /// Ersetzt die Plan-Zeilen im Cache; nicht mehr geplante Einträge fliegen
    /// raus (Mealie ist autoritativ, §3.3).
    func cachePlan(_ items: [MealieMealPlanItem], fetchedAt: Date? = nil) throws {
        let stamp = fetchedAt ?? now()
        var leftovers = try planCacheByID()
        for item in items {
            let cacheID = Self.planCacheID(for: item)
            let row: Recipe
            if let existing = leftovers.removeValue(forKey: cacheID) {
                row = existing
            } else {
                row = Recipe(
                    id: cacheID,
                    name: item.recipeName,
                    mealType: item.mealType,
                    recipeScale: item.recipeScale,
                    fetchedAt: stamp
                )
                context.insert(row)
            }
            row.name = item.recipeName
            row.mealType = item.mealType
            row.recipeScale = item.recipeScale
            row.date = MealieDay.date(from: item.date, calendar: calendar)
            row.fetchedAt = stamp
        }
        for gone in leftovers.values {
            context.delete(gone)
        }
        try context.save()
    }

    // MARK: - Cache: Bibliothek

    /// Bibliotheks-Zeilen aus dem Cache; Plan-Zeilen tragen das Präfix
    /// `plan:` und bleiben außen vor.
    ///
    /// Die Bildbasis wird **einmal vor** der Zeilenbildung aufgelöst
    /// (MARAAA-144), nicht pro Zeile.
    func cachedLibrary() throws -> [MealieRecipeRow] {
        let imageBaseURL = resolveImageBaseURL()
        let rows = try context.fetch(
            FetchDescriptor<Recipe>(sortBy: [SortDescriptor(\Recipe.name)])
        )
        return rows.filter { !$0.id.hasPrefix(Self.planCachePrefix) }.map { row in
            MealieRecipeRow(
                id: row.id,
                name: row.name,
                slug: nil,
                imageID: row.id,
                // Die gespeicherte Adresse kann mit einer inzwischen
                // korrigierten Basis entstanden sein; fehlt sie ganz (Bibliothek
                // ohne hinterlegte URL gecacht), wird sie hier mit der
                // aktuellen Basis gebildet (MARAAA-140/M1).
                imageURL: storedImageURL(row.imageURL) ?? Self.imageURL(forRecipeID: row.id, baseURL: imageBaseURL),
                totalTime: row.totalTime,
                servings: 0
            )
        }
    }

    /// Ersetzt die Bibliotheks-Zeilen im Cache; ersetzt nur die Zeilen ohne
    /// Plan-Präfix, damit der Wochenplan-Cache erhalten bleibt.
    func cacheLibrary(_ rows: [MealieRecipeRow], fetchedAt: Date? = nil) throws {
        let stamp = fetchedAt ?? now()
        var leftovers = try libraryCacheByID()
        for item in rows {
            let cached: Recipe
            if let existing = leftovers.removeValue(forKey: item.id) {
                cached = existing
            } else {
                cached = Recipe(
                    id: item.id,
                    name: item.name,
                    mealType: "",
                    recipeScale: 1,
                    fetchedAt: stamp
                )
                context.insert(cached)
            }
            cached.name = item.name
            cached.mealType = ""
            cached.imageURL = item.imageURL?.absoluteString
            cached.totalTime = item.totalTime
            cached.fetchedAt = stamp
        }
        for gone in leftovers.values {
            context.delete(gone)
        }
        try context.save()
    }

    // MARK: - Cache-IDs

    /// `plan:{date}:{meal_type}:{recipe_id}` bzw. `plan:text:{entry_id}` —
    /// stabil und kollisionsfrei.
    static func planCacheID(for item: MealieMealPlanItem) -> String {
        item.id
    }

    /// Liest die Mealie-Rezept-ID aus einer Plan-Cache-ID zurück; `nil` für
    /// Freitext-Zeilen (`plan:text:…`).
    static func recipeID(fromPlanCacheID id: String) -> String? {
        guard !id.hasPrefix(MealieMealPlanItem.textPrefix) else { return nil }
        let parts = id.split(separator: ":", maxSplits: 3, omittingEmptySubsequences: false)
        guard parts.count == 4, parts[0] == "plan" else { return nil }
        return String(parts[3])
    }

    /// Liest die Server-ID eines Freitext-Eintrags aus seiner Plan-Cache-ID
    /// zurück; `nil` für Rezeptzeilen und für den Inhalts-Hash-Rückfall.
    ///
    /// Ohne diesen Rückweg verlöre der Cache die Unterscheidung zweier
    /// inhaltsgleicher Einträge: `cachedPlan` baut die Normalform neu und
    /// berechnet ihre ID erneut (MARAAA-140/N2). Mealie vergibt
    /// `ReadPlanEntry.id` als UUID; der Rückfall-Hash besteht aus 16
    /// Hex-Zeichen ohne Bindestriche und ist deshalb keine UUID.
    static func entryID(fromPlanCacheID id: String) -> String? {
        guard id.hasPrefix(MealieMealPlanItem.textPrefix) else { return nil }
        let raw = String(id.dropFirst(MealieMealPlanItem.textPrefix.count))
        return UUID(uuidString: raw) == nil ? nil : raw
    }

    // MARK: - Intern

    /// Prüft eine gespeicherte absolute Bild-URL aus dem Cache; nur `https`.
    private func storedImageURL(_ raw: String?) -> URL? {
        guard let raw = MealieText.nonEmpty(raw),
              let url = URL(string: raw),
              let scheme = url.scheme?.lowercased(),
              Self.allowedImageSchemes.contains(scheme)
        else { return nil }
        return url
    }

    private func planCacheByID() throws -> [String: Recipe] {
        let rows = try context.fetch(FetchDescriptor<Recipe>()).filter { $0.id.hasPrefix(Self.planCachePrefix) }
        return Dictionary(rows.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    }

    private func libraryCacheByID() throws -> [String: Recipe] {
        let rows = try context.fetch(FetchDescriptor<Recipe>()).filter { !$0.id.hasPrefix(Self.planCachePrefix) }
        return Dictionary(rows.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    }

    /// Seitengröße des Wochenplans: eine Woche hat höchstens 7 × 7 Mahlzeiten.
    private static let mealPlanPageSize = 100
}
