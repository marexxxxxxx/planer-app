//
//  MealieDTO.swift
//  Planer
//
//  Wire-Formate der Mealie-v2-API und ihre Normalform (spec-ios §2.4, §3.3).
//

import Foundation

/// Kleine Text-Helfer der Mealie-Schicht.
///
/// Zweck: die API liefert Namen und Titel als `string | null` und gelegentlich
/// leer; die Normalform braucht entschiedene Werte.
/// Grenze: reine String-Behandlung, keine Fachlogik.
enum MealieText {
    static func trimmed(_ value: String?) -> String {
        value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    static func nonEmpty(_ value: String?) -> String? {
        let trimmed = trimmed(value)
        return trimmed.isEmpty ? nil : trimmed
    }
}

/// Kalendertag aus Mealie (`YYYY-MM-DD`).
///
/// Zweck: Mealie-Daten sind reine Kalendertage ohne Zeitzone; sie werden im
/// lokalen Kalender auf Tagesbeginn abgebildet, damit die Anzeige nicht um
/// einen Tag springt.
/// Grenze: kein Zeitanteil, keine Zeitzonen-Umrechnung.
enum MealieDay {
    static func date(from text: String, calendar: Calendar = .current) -> Date? {
        let parts = text.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
    }

    static func text(for date: Date, calendar: Calendar = .current) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(
            format: "%04d-%02d-%02d",
            parts.year ?? 0,
            parts.month ?? 0,
            parts.day ?? 0
        )
    }

    /// Montag bis Sonntag bzw. der erste und letzte Tag der Kalenderwoche.
    static func weekRange(
        containing date: Date,
        calendar: Calendar = .current
    ) -> (start: Date, end: Date)? {
        guard let interval = calendar.dateInterval(of: .weekOfYear, for: date) else {
            return nil
        }
        let lastDay = calendar.date(byAdding: .day, value: -1, to: interval.end) ?? interval.end
        return (interval.start, lastDay)
    }
}

/// Anzeige-Reihenfolge und deutsche Bezeichnung der Mealie-Mahlzeiten
/// (`PlanEntryType`: breakfast, lunch, dinner, side, snack, drink, dessert).
enum MealieMealType {
    static let order = ["breakfast", "lunch", "dinner", "side", "snack", "drink", "dessert"]

    static func sortIndex(_ raw: String) -> Int {
        order.firstIndex(of: raw.lowercased()) ?? order.count
    }

    static func label(_ raw: String) -> String {
        switch raw.lowercased() {
        case "breakfast":
            return "Frühstück"
        case "lunch":
            return "Mittagessen"
        case "dinner":
            return "Abendessen"
        case "side":
            return "Beilage"
        case "snack":
            return "Snack"
        case "drink":
            return "Getränk"
        case "dessert":
            return "Dessert"
        default:
            return raw
        }
    }
}

/// Eine Seite der Mealie-Paginierung (`PaginationBase_*`, §2.4).
struct MealiePagination: Decodable, Equatable {
    let page: Int
    let perPage: Int
    let total: Int
    let totalPages: Int

    enum CodingKeys: String, CodingKey {
        case page
        case perPage = "per_page"
        case total
        case totalPages = "total_pages"
    }
}

/// Rohe Wochenplan-Zeile aus `GET /households/mealplans` (`ReadPlanEntry`).
///
/// Nur die Felder, die die Normalform braucht. `id`, `groupId`, `userId` und
/// `householdId` der Antwort werden bewusst nicht dekodiert.
struct MealiePlanEntry: Decodable, Equatable {
    let date: String
    let entryType: String?
    let recipeId: String?
    let recipeScale: Double?
    let title: String?
    let recipe: MealieRecipeSummary?

    enum CodingKeys: String, CodingKey {
        case date
        case entryType
        case recipeId
        case recipeScale
        case title
        case recipe
    }

    /// Normalform aus §2.4: `{date, meal_type, recipe_id, recipe_name, recipe_scale}`.
    ///
    /// `nil` für Freitext-Einträge ohne Rezeptbezug (`title`/`text`, z. B.
    /// „Reste“): die Normalform aus §2.4 verlangt eine `recipe_id`, und ein
    /// erfundenes Ersatz-Feld wäre keine Rezept-ID. Solche Einträge fehlen
    /// damit im Wochenplan (siehe Abschlussbericht, OFFEN).
    func normalize() -> MealieMealPlanItem? {
        guard let recipeID = MealieText.nonEmpty(recipeId),
              let day = MealieText.nonEmpty(date)
        else {
            return nil
        }
        let name = MealieText.nonEmpty(recipe?.name)
            ?? MealieText.nonEmpty(title)
            ?? recipeID
        return MealieMealPlanItem(
            date: day,
            mealType: MealieText.trimmed(entryType),
            recipeID: recipeID,
            recipeName: name,
            recipeScale: recipeScale ?? 1
        )
    }
}

/// Seite des Wochenplans (`PlanEntryPagination`).
struct MealieMealPlanPage: Decodable, Equatable {
    let items: [MealiePlanEntry]
    let pagination: MealiePagination

    private enum CodingKeys: String, CodingKey {
        case items
    }

    init(from decoder: Decoder) throws {
        items = try decoder.container(keyedBy: CodingKeys.self)
            .decode([MealiePlanEntry].self, forKey: .items)
        pagination = try MealiePagination(from: decoder)
    }
}

/// Normalform einer geplanten Mahlzeit (spec-ios §2.4, Schema §3.4).
struct MealieMealPlanItem: Equatable, Identifiable, Sendable {
    let date: String
    let mealType: String
    let recipeID: String
    let recipeName: String
    let recipeScale: Double

    var id: String { "\(date)|\(mealType)|\(recipeID)" }

    /// Anzeige-Reihenfolge innerhalb eines Tages.
    var sortIndex: Int { MealieMealType.sortIndex(mealType) }
}

/// Seite der Rezept-Bibliothek aus `GET /recipes` (`PaginationBase_RecipeSummary_`).
struct MealieRecipePage: Decodable, Equatable {
    let items: [MealieRecipeSummary]
    let pagination: MealiePagination

    private enum CodingKeys: String, CodingKey {
        case items
    }

    init(from decoder: Decoder) throws {
        items = try decoder.container(keyedBy: CodingKeys.self)
            .decode([MealieRecipeSummary].self, forKey: .items)
        pagination = try MealiePagination(from: decoder)
    }
}

/// Bildverweis eines Rezepts.
///
/// Mealie liefert `image` als String (Pfad) oder `null`; das OpenAPI-Schema
/// lässt den Typ offen. Jede andere Form gilt als „kein Bild“, damit ein
/// unbekanntes Bildfeld nicht die ganze Bibliothek unlesbar macht.
struct MealieImageReference: Decodable, Equatable, Sendable {
    let path: String?

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        path = try? container.decode(String.self)
    }
}

/// Rezept-Zusammenfassung (`RecipeSummary`) aus Bibliothek und Wochenplan.
struct MealieRecipeSummary: Decodable, Equatable, Sendable {
    let id: String?
    let name: String?
    let slug: String?
    let image: MealieImageReference?
    let totalTime: String?
    let recipeServings: Double?
}

/// Vollständiges Rezept (`Recipe-Output`) aus `GET /recipes/{slug}`.
///
/// Nur der Zutaten-Teil wird gebraucht; alles andere ignoriert `Decodable`.
struct MealieRecipeDetail: Decodable, Equatable, Sendable {
    let slug: String?
    let name: String?
    let recipeIngredient: [MealieRecipeIngredient]?

    enum CodingKeys: String, CodingKey {
        case slug
        case name
        case recipeIngredient
    }
}

/// Zutat eines Rezepts (`RecipeIngredient-Output`).
struct MealieRecipeIngredient: Decodable, Equatable, Sendable {
    let quantity: Double?
    let unit: MealieNamedValue?
    let food: MealieNamedValue?
    let note: String?
    let display: String?
    let originalText: String?
    let title: String?

    /// Normalform einer Zutat; `nil`, wenn weder Lebensmittel noch Anzeigetext
    /// vorhanden sind (dann gibt es nichts auf eine Einkaufsliste zu setzen).
    func normalize() -> MealieIngredient? {
        let displayText = MealieText.nonEmpty(display)
            ?? MealieText.nonEmpty(originalText)
            ?? MealieText.nonEmpty(title)
        guard let name = MealieText.nonEmpty(food?.name) ?? displayText else {
            return nil
        }
        return MealieIngredient(
            name: name,
            quantity: quantity ?? 0,
            unit: MealieText.trimmed(unit?.name),
            display: displayText ?? name
        )
    }
}

/// Ein `{name}`-Objekt der Mealie-Antwort (Einheit, Lebensmittel).
struct MealieNamedValue: Decodable, Equatable, Sendable {
    let name: String?
}

/// Normalform einer Zutat für den Grocy-Schreibpfad (spec-ios §3.3
/// `ingredientsJSON`, Struktur `[ANNAHME]` aus der Mealie-Doku).
struct MealieIngredient: Equatable, Sendable, Identifiable {
    let name: String
    let quantity: Double
    let unit: String
    let display: String

    var id: String { "\(name)|\(display)" }
}

/// Zeile der Rezept-Bibliothek, wie sie die Ansicht braucht.
///
/// `slug` ist nur nach einem Online-Laden bekannt; die Cache-Entity `Recipe`
/// aus I2 hat kein Slug-Feld (spec-ios §3.3).
struct MealieRecipeRow: Identifiable, Equatable {
    let id: String
    let name: String
    let slug: String?
    let imageURL: URL?
    let totalTime: String?
    let servings: Double
}

/// Ordnet Mealie-Zutaten den Produkten des Grocy-Katalogs zu.
///
/// Zweck: „Zutaten auf Einkaufsliste“ braucht eine Grocy-`product_id`; Grocy
/// nimmt keinen Freitext. Verglichen wird der Lebensmittelname ohne
/// Groß-/Kleinschreibung und ohne Akzente.
/// Grenze: nur exakte Treffer nach dieser Normalisierung — keine Ähnlichkeit,
/// keine Pluralformen, keine Synonyme. Nicht zugeordnete Zutaten meldet die
/// Ansicht, statt sie stillschweigend zu verwerfen.
enum MealieIngredientMatcher {
    static func product(for ingredient: MealieIngredient, in catalog: [GrocyProduct]) -> GrocyProduct? {
        let target = normalized(ingredient.name)
        guard !target.isEmpty else { return nil }
        return catalog.first { normalized($0.name) == target }
    }

    static func normalized(_ text: String) -> String {
        text
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
