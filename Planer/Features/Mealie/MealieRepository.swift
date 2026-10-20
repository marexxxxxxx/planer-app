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
    static let planCachePrefix = "plan:"

    private let client: NetworkClient
    private let context: ModelContext
    private let now: () -> Date
    private let calendar: Calendar
    /// Origin der Mealie-Instanz für relative Bildpfade; `nil`, solange keine
    /// gültige Basis-URL in der Keychain liegt (dann bleibt das Bild aus).
    private let imageBaseURL: URL?

    init(
        client: NetworkClient = NetworkClient(),
        context: ModelContext,
        keychain: KeychainManager = KeychainManager(),
        now: @escaping () -> Date = Date.init,
        calendar: Calendar = .current
    ) {
        self.client = client
        self.context = context
        self.now = now
        self.calendar = calendar
        self.imageBaseURL = (try? ServiceConfiguration.load(.mealie, keychain: keychain))?.baseURL
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
        return entries.compactMap { $0.normalize() }
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
    func row(from summary: MealieRecipeSummary) -> MealieRecipeRow? {
        let identifier = MealieText.nonEmpty(summary.id) ?? MealieText.nonEmpty(summary.slug)
        guard let identifier else { return nil }
        return MealieRecipeRow(
            id: identifier,
            name: MealieText.nonEmpty(summary.name) ?? MealieText.nonEmpty(summary.slug) ?? identifier,
            slug: MealieText.nonEmpty(summary.slug),
            imageURL: imageURL(for: summary.image?.path),
            totalTime: MealieText.nonEmpty(summary.totalTime),
            servings: summary.recipeServings ?? 0
        )
    }

    /// Erlaubte Schemes für Bild-URLs aus der Mealie-Antwort (G2-Befund 10).
    ///
    /// Nur `https`: `file:`/`data:`-URLs haben in `AsyncImage` nichts zu suchen,
    /// und die Basis-URL ist seit I2 ohnehin https-pflichtig.
    static let allowedImageSchemes: Set<String> = ["https"]

    /// Macht aus Mealies relativem Bildpfad (`/api/media/…`) eine absolute URL.
    ///
    /// Serverwerte werden vor der URL-Bildung geprüft: absolute URLs nur mit
    /// einem Scheme aus `allowedImageSchemes`, relative Pfade werden in
    /// Einzelsegmente zerlegt, prozentkodiert (`/` und `%` ausgenommen) und an
    /// den https-Origin der Basis-URL gehängt. `nil` bei fehlendem Pfad,
    /// fehlender Basis-URL oder nicht erlaubtem Scheme — ein fehlendes Bild ist
    /// kein Fehlerzustand des Tabs.
    func imageURL(for rawPath: String?) -> URL? {
        guard let path = MealieText.nonEmpty(rawPath) else { return nil }
        if let absolute = URL(string: path), let scheme = absolute.scheme {
            guard Self.allowedImageSchemes.contains(scheme.lowercased()) else { return nil }
            return absolute
        }
        guard let base = imageBaseURL,
              let scheme = base.scheme?.lowercased(),
              Self.allowedImageSchemes.contains(scheme),
              let host = base.host,
              let encoded = Self.encodedPath(path)
        else { return nil }
        var components = URLComponents()
        components.scheme = scheme
        components.host = host
        components.port = base.port
        components.percentEncodedPath = encoded
        return components.url
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

    /// Kodiert einen relativen Bildpfad segmentweise; `nil`, wenn nichts übrig
    /// bleibt.
    ///
    /// `.`/`..`-Segmente werden verworfen, damit ein Serverwert nicht aus dem
    /// erwarteten Pfad herausklettern kann.
    static func encodedPath(_ raw: String) -> String? {
        let segments = raw
            .split(separator: "/", omittingEmptySubsequences: true)
            .map(String.init)
            .filter { $0 != "." && $0 != ".." }
        guard !segments.isEmpty else { return nil }
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "/%")
        let encoded = segments.compactMap { $0.addingPercentEncoding(withAllowedCharacters: allowed) }
        guard encoded.count == segments.count else { return nil }
        return "/" + encoded.joined(separator: "/")
    }

    // MARK: - Cache: Wochenplan

    /// Plan-Zeilen aus dem Cache, nach Tag und Mahlzeit sortiert.
    func cachedPlan() throws -> [MealieMealPlanItem] {
        let rows = try context.fetch(FetchDescriptor<Recipe>())
            .filter { $0.id.hasPrefix(Self.planCachePrefix) }
        return rows.compactMap { row -> MealieMealPlanItem? in
            guard let date = row.date else { return nil }
            let recipeID = Self.recipeID(fromPlanCacheID: row.id) ?? row.id
            return MealieMealPlanItem(
                date: MealieDay.text(for: date, calendar: calendar),
                mealType: row.mealType,
                recipeID: recipeID,
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
    func cachedLibrary() throws -> [MealieRecipeRow] {
        let rows = try context.fetch(
            FetchDescriptor<Recipe>(sortBy: [SortDescriptor(\Recipe.name)])
        )
        return rows.filter { !$0.id.hasPrefix(Self.planCachePrefix) }.map { row in
            MealieRecipeRow(
                id: row.id,
                name: row.name,
                slug: nil,
                imageURL: imageURL(for: row.imageURL),
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

    /// `plan:{date}:{meal_type}:{recipe_id}` — stabil und kollisionsfrei.
    static func planCacheID(for item: MealieMealPlanItem) -> String {
        "\(planCachePrefix)\(item.date):\(item.mealType):\(item.recipeID)"
    }

    /// Liest die Mealie-Rezept-ID aus einer Plan-Cache-ID zurück.
    static func recipeID(fromPlanCacheID id: String) -> String? {
        let parts = id.split(separator: ":", maxSplits: 3, omittingEmptySubsequences: false)
        guard parts.count == 4, parts[0] == "plan" else { return nil }
        return String(parts[3])
    }

    // MARK: - Intern

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
