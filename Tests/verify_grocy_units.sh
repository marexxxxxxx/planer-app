#!/usr/bin/env bash
#
# Statischer Regressionstest für MARAAA-135: Grocy-Einheiten in Vorrat und
# Einkaufsliste auflösen und die Tastatur beim Scrollen ausblenden.
#
# Warum statisch: Auf diesem Prüfstand gibt es keine Swift-Toolchain; die
# übrigen Abnahmen laufen ebenfalls über grep-/Fixture-Prüfungen. Der Test
# fixiert die API-Zusage aus dem Auftrag:
#   - `/api/stock` trägt die Einheit nur als `product.qu_id_stock`,
#   - `/api/objects/shopping_list` nur als `qu_id`,
#   - `/api/objects/quantity_units` liefert `{id,name}`.
# Der Test schlägt fehl, solange die Einheitenmap nicht geladen/übergeben wird,
# die DTOs die IDs nicht dekodieren oder ein Einheitenfehler den Tab mitzieht.
#
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$root"

fail=0

pass() { echo "ok:   $1"; }
fail_check() { echo "FAIL: $1"; fail=1; }

require() {
    local description="$1"
    local pattern="$2"
    local file="$3"
    if grep -qE "$pattern" "$file"; then
        pass "$description"
    else
        fail_check "$description ($file)"
    fi
}

require_body() {
    local description="$1"
    local pattern="$2"
    local body="$3"
    if grep -qE "$pattern" <<<"$body"; then
        pass "$description"
    else
        fail_check "$description"
    fi
}

forbid() {
    local description="$1"
    local pattern="$2"
    local file="$3"
    if grep -qE "$pattern" "$file"; then
        fail_check "$description ($file)"
    else
        pass "$description"
    fi
}

dto="Planer/Features/Grocy/GrocyDTO.swift"
repo="Planer/Features/Grocy/GrocyRepository.swift"
view="Planer/Features/Grocy/GrocyView.swift"
model="Planer/Features/Grocy/GrocyViewModel.swift"

units_fixture="Tests/Fixtures/grocy_quantity_units.json"
stock_fixture="Tests/Fixtures/grocy_stock_raw.json"
shopping_fixture="Tests/Fixtures/grocy_shopping_list_raw.json"

units_body="$(sed -n '/func fetchQuantityUnits() async throws -> \[Int: String\] {/,/^    }$/p' "$repo")"
load_units_body="$(sed -n '/private func loadQuantityUnits() async -> (names: \[Int: String\], unavailable: Bool) {/,/^    }$/p' "$repo")"
refresh_body="$(sed -n '/func refresh() async throws -> GrocySnapshot {/,/^    }$/p' "$repo")"
resolved_unit_body="$(sed -n '/private func resolvedUnitName(unitNames: \[Int: String\]) -> String {/,/^    }$/p' "$dto")"
stock_normalize_body="$(awk '/func normalize\($/{count++} count==1{print} count==2{exit}' "$dto")"
shopping_normalize_body="$(awk '/func normalize\($/{count++} count==2{print}' "$dto")"

# 1. Repository lädt die Einheiten und übergibt die Namensmap.
require "GrocyRepository kennt den Einheiten-Endpunkt" \
    'static let quantityUnits = "/objects/quantity_units"' "$repo"
require "GrocyRepository lädt die Einheiten als ID-Name-Map" \
    'func fetchQuantityUnits\(\) async throws -> \[Int: String\]' "$repo"
require_body "Einheiten laufen über NetworkClient.send" \
    'client\.send\(' "$units_body"
require_body "Einheiten werden für den Dienst grocy gesendet" \
    'for: \.grocy' "$units_body"
require_body "Einheiten werden als GrocyQuantityUnit dekodiert" \
    'as: \[GrocyQuantityUnit\]\.self' "$units_body"
require_body "refresh lädt die Einheiten mit" \
    'async let unitsTask = loadQuantityUnits\(\)' "$refresh_body"
require_body "refresh übergibt die Namensmap an den Bestand" \
    'fetchStock\(unitNames: units\.names\)' "$refresh_body"
require_body "refresh übergibt die Namensmap an die Einkaufsliste" \
    'fetchShoppingList\(catalog: catalog, unitNames: units\.names\)' "$refresh_body"
require_body "refresh meldet den Einheitenausfall im Snapshot" \
    'unitsUnavailable: units\.unavailable' "$refresh_body"
require_body "Einheitenfehler liefert eine leere Map statt zu werfen" \
    'return \(\[:], true\)' "$load_units_body"
require_body "Einheitenfehler wird als Ausfall gemeldet, nicht verschluckt" \
    'return \(try await fetchQuantityUnits\(\), false\)' "$load_units_body"
require_body "Einheitenabruf wertet den Fehler im catch aus" \
    'catch \{' "$load_units_body"

# 2. DTOs dekodieren die Einheiten-IDs und lösen sie auf.
require "GrocyQuantityUnit dekodiert id und name" \
    'struct GrocyQuantityUnit: Decodable, Equatable, Sendable' "$dto"
require "GrocyProduct dekodiert qu_id_stock" \
    'let quantityUnitStockID: Int\?' "$dto"
require "qu_id_stock ist im CodingKey-Satz" \
    'case quantityUnitStockID = "qu_id_stock"' "$dto"
require "GrocyShoppingEntry dekodiert qu_id" \
    'let quantityUnitID: Int\?' "$dto"
require "qu_id ist im CodingKey-Satz" \
    'case quantityUnitID = "qu_id"' "$dto"
require_body "Bestand normalisiert mit der Einheitenmap" \
    'resolvedUnitName\(unitNames: unitNames\)' "$stock_normalize_body"
require_body "Bestand akzeptiert eine leere Einheitenmap als Fallback" \
    'unitNames: \[Int: String\] = \[:\]' "$stock_normalize_body"
require_body "Bestands-Einheit wird über product.qu_id_stock aufgelöst" \
    'product\?\.quantityUnitStockID' "$resolved_unit_body"
require_body "unbekannte Bestands-Einheit bleibt leer" \
    'unitNames\[id\] \?\? ""' "$resolved_unit_body"
require_body "Einkaufsliste normalisiert mit der Einheitenmap" \
    'unitNames: \[Int: String\] = \[:\]' "$shopping_normalize_body"
require_body "Einkaufs-Einheit wird über qu_id aufgelöst" \
    'quantityUnitID\.flatMap \{ unitNames\[\$0\] \}' "$shopping_normalize_body"
require_body "unbekannte Einkaufs-Einheit bleibt leer" \
    '\?\? ""' "$shopping_normalize_body"

# 3. Snapshot-/Katalog-Pfad bleibt kompatibel, Ausfall macht den Tab nicht
#    unbenutzbar.
require "GrocySnapshot behält Bestand, Einkaufsliste und Katalog" \
    'let stock: \[GrocyStockItem\]' "$repo"
require "GrocySnapshot behält den Katalog" \
    'let catalog: \[GrocyProduct\]' "$repo"
require "GrocySnapshot meldet den Einheitenausfall" \
    'let unitsUnavailable: Bool' "$repo"
require "Snapshot-Initialisierer bleibt ohne Ausfall aufrufbar" \
    'unitsUnavailable: Bool = false' "$repo"
require_body "fetchStock bleibt ohne Namensmap aufrufbar" \
    'unitNames: \[Int: String\] = \[:\]' "$(sed -n '/func fetchStock/,/^    }$/p' "$repo")"
require_body "fetchShoppingList bleibt ohne Namensmap aufrufbar" \
    'unitNames: \[Int: String\] = \[:\]' "$(sed -n '/func fetchShoppingList/,/^    }$/p' "$repo")"
require "ViewModel meldet fehlende Einheiten im Banner" \
    'Einheiten konnten nicht geladen werden' "$model"

# 4. Tastatur beim Scrollen dismissen.
require "GrocyView dismissiert die Tastatur beim Scrollen" \
    '\.scrollDismissesKeyboard\(\.interactively\)' "$view"

# 5. Fixtures: echte Grocy-Formen, IDs vollständig auflösbar.
for fixture in "$units_fixture" "$stock_fixture" "$shopping_fixture"; do
    if [[ -f "$fixture" ]]; then
        pass "Fixture $fixture vorhanden"
    else
        fail_check "Fixture $fixture vorhanden"
    fi
done

if jq -e 'type == "array" and length > 0
          and all(.[]; (.id | type) == "number" and (.name | type) == "string")' \
    "$units_fixture" >/dev/null; then
    pass "Einheiten-Fixture ist eine id/name-Liste"
else
    fail_check "Einheiten-Fixture ist eine id/name-Liste ($units_fixture)"
fi

if jq -e 'type == "array" and length > 0
          and all(.[]; (.product.qu_id_stock | type) == "number"
                       and (.product.name | type) == "string")' \
    "$stock_fixture" >/dev/null; then
    pass "Bestands-Fixture trägt product.qu_id_stock"
else
    fail_check "Bestands-Fixture trägt product.qu_id_stock ($stock_fixture)"
fi
forbid "Bestands-Fixture liefert keinen Einheitennamen" \
    '"qu_name"' "$stock_fixture"

if jq -e 'type == "array" and length > 0
          and all(.[]; has("qu_id"))' "$shopping_fixture" >/dev/null; then
    pass "Einkaufs-Fixture trägt qu_id"
else
    fail_check "Einkaufs-Fixture trägt qu_id ($shopping_fixture)"
fi

missing_stock="$(jq -r --slurpfile units "$units_fixture" \
    '[.[] | .product.qu_id_stock as $q
          | select(($units[0] | map(.id) | index($q)) == null)] | length' \
    "$stock_fixture")"
if [[ "$missing_stock" -eq 0 ]]; then
    pass "alle Bestands-qu_ids sind in der Einheitenmap auflösbar"
else
    fail_check "alle Bestands-qu_ids sind in der Einheitenmap auflösbar (fehlen: $missing_stock)"
fi

missing_shopping="$(jq -r --slurpfile units "$units_fixture" \
    '[.[] | select(.qu_id != null) | .qu_id as $q
          | select(($units[0] | map(.id) | index($q)) == null)] | length' \
    "$shopping_fixture")"
if [[ "$missing_shopping" -eq 0 ]]; then
    pass "alle Einkaufs-qu_ids sind in der Einheitenmap auflösbar"
else
    fail_check "alle Einkaufs-qu_ids sind in der Einheitenmap auflösbar (fehlen: $missing_shopping)"
fi

if [[ "$fail" -ne 0 ]]; then
    echo "Ergebnis: FEHLGESCHLAGEN"
    exit 1
fi

echo "Ergebnis: OK"
