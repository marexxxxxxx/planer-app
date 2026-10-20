//
//  ModelContainer.swift
//  Planer
//
//  Zusammenbau des SwiftData-Schemas (spec-ios §3, AD-3).
//

import Foundation
import SwiftData

/// Bündelt die drei kanonischen Cache-Entities in einem Schema.
///
/// Zweck: die Schema-Assembly liegt an genau einer Stelle; `PlanerApp` (I1)
/// injiziert den Container, I4–I6 konsumieren die Entities read-only.
/// Grenze: keine Migration und keine Sync-Logik; `inMemory` dient Previews und
/// Tests, nicht dem Produktivpfad.
enum PlanerModelContainer {
    /// Kanonische Entity-Liste aus spec-ios §3.
    static let entities: [any PersistentModel.Type] = [
        TodoItem.self,
        GroceryItem.self,
        Recipe.self
    ]

    /// Baut den SwiftData-Container.
    static func make(inMemory: Bool = false) throws -> ModelContainer {
        let schema = Schema(entities)
        let configuration = ModelConfiguration(isStoredInMemoryOnly: inMemory)
        return try ModelContainer(for: schema, configurations: [configuration])
    }
}
