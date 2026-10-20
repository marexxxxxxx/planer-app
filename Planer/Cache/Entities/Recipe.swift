//
//  Recipe.swift
//  Planer
//
//  Kanonisches SwiftData-Schema eines Rezepts (spec-ios §3.3).
//

import Foundation
import SwiftData

/// Read-through-Cache für Mealie-Wochenplan und Rezept-Bibliothek.
///
/// Zweck: Wochenplan und zuletzt geladene Rezepte offline anzeigen.
/// Grenze: reiner Lese-Cache; Schreiben nach Mealie ist nicht Teil der App
/// (spec-ios §3.3 / AD-8), Sync liegt bei I6.
@Model
final class Recipe: Syncable {
    @Attribute(.unique) var id: String
    var name: String
    var mealType: String
    /// Skalierungsfaktor aus Mealie v2 (`recipeScale`), nicht `servings`.
    var recipeScale: Double
    var date: Date?
    var imageURL: String?
    var totalTime: String?
    /// Zutaten als JSON-Liste (spec-ios §3.3).
    var ingredientsJSON: String
    var fetchedAt: Date

    init(
        id: String,
        name: String,
        mealType: String,
        recipeScale: Double,
        date: Date? = nil,
        imageURL: String? = nil,
        totalTime: String? = nil,
        ingredientsJSON: String = "[]",
        fetchedAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.mealType = mealType
        self.recipeScale = recipeScale
        self.date = date
        self.imageURL = imageURL
        self.totalTime = totalTime
        self.ingredientsJSON = ingredientsJSON
        self.fetchedAt = fetchedAt
    }

    var syncIdentifier: String { id }
    var syncTimestamp: Date { fetchedAt }
}
