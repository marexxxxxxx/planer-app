# Wire-Fixtures (MARAAA-138)

Diese Dateien sind **Antworten, wie sie über die Leitung kommen** — nicht die
Normalform der App. Sie sind die Grundlage von
`Tests/verify_wire_contracts.sh`: der Test vergleicht die Feldnamen hier mit den
`CodingKeys` der Decoder. Wer `per_page` in `perPage` umbenennt oder `qu_name`
entfernt, macht den Test rot (siehe `--selbsttest`).

| Datei | Endpunkt | Belegte Felder, um die es geht |
|---|---|---|
| `mealie_recipes.json` | `GET /api/recipes` | `per_page`, `total_pages`, `items`, `image` als Cache-Token (`"4LEY"`) |
| `mealie_mealplans.json` | `GET /api/households/mealplans` | `items[]` mit `entryType`, `recipeId`, `recipeScale`, `text` (Freitext, z. B. „Reste“) |
| `grocy_stock.json` | `GET /api/stock` | `product.qu_id_stock`; **kein** Einheitenname auf der Leitung |
| `grocy_shopping_list.json` | `GET /api/objects/shopping_list` | `qu_id`, `done` als Zahl 0/1, Freitext-Zeile mit `product_id`/`qu_id` null |
| `grocy_quantity_units.json` | `GET /api/objects/quantity_units` | `{id, name}` als Nachschlagetabelle |
| `hermes_sessions.json` | `GET /api/sessions` | `data[]`, `has_more`, `limit`, `offset` |
| `hermes_messages.json` | `GET /api/sessions/{id}/messages` | `data[]`, `pagination.returned`, `reasoning_content`, `tool_calls` |
| `worldplaner_tasks.json` | `GET /api/tasks` | `due_at`, `completed_at`, `version` |

## Herkunft

- **Grocy**: Form am 2026-10-21 gegen `https://demo.grocy.info/api/stock`,
  `/api/objects/shopping_list` und `/api/objects/quantity_units` abgerufen
  (HTTP 200). Übernommen sind die Felder, die die App liest, plus die
  Rauschfelder der echten Antwort (`amount_aggregated`, `value`,
  `row_created_timestamp`, `shopping_list_id`, `name_plural`, …).
  `qu_name` kommt in der Demo-Antwort **nicht** vor; die Zeile mit `qu_name`
  ist die in `GrocyDTO.swift` dokumentierte Anreicherung älterer/anderer
  Grocy-Versionen und prüft, dass der Decoder sie weiterhin akzeptiert.
- **Mealie**: Form aus `spec-ios.md` §2.4 und der Mealie-v2-OpenAPI
  (`PaginationBase_RecipeSummary_`, `ReadPlanEntry`); die Demo verlangt seit
  dem Prüfzeitpunkt Zugangsdaten (HTTP 401), die Bild-Token `4LEY`/`9KQ2`
  stammen aus der dokumentierten Demo.
- **Hermes**: Hüllen aus `spec-chat` Rev 4 §2.2/§5.1
  (`{object, data[], limit, offset, has_more}` bzw.
  `{object, session_id, data[], pagination{limit, offset, order, returned}}`).
- **worldplaner**: Vertrag aus `spec-ios.md` §2.2; Werte wie in der
  Diagnose MARAAA-132 live gegen `POST/PATCH /api/tasks` geprüft
  (201/409/204, `due_at`/`completed_at`).

Die Dateien sind bewusst **klein**: ein paar Zeilen je Dienst, genug für den
Querbezug (jede `qu_id` ist auflösbar, `returned` passt zu `data|length`),
aber ohne Zugangsdaten, Personenbezug oder echte Haushaltsdaten.
