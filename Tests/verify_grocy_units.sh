#!/usr/bin/env bash
#
# Statischer Regressionstest für MARAAA-135: Grocy-Einheiten in Vorrat und
# Einkaufsliste auflösen und die Tastatur beim Scrollen ausblenden.
# Ergänzt um MARAAA-141 (Review M2): der Einheitenabruf darf den Tab nicht
# aufhalten, wenn `/objects/quantity_units` hängt oder 5xx liefert.
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
# Zeitgrenze (MARAAA-141 M2): Der Einheitenabruf läuft mit einem Versuch und
# `unitsTimeout` = 4 s; Bestand und Einkaufsliste werden gleichzeitig gestartet
# und erst nach dem Einheitenabruf aufgelöst. Ein 503 kostet damit einen
# Fehlversuch, ein hängender Endpunkt höchstens 4 s — nicht 3 × 10 s + Backoff.
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

forbid_body() {
    local description="$1"
    local pattern="$2"
    local body="$3"
    if grep -qE "$pattern" <<<"$body"; then
        fail_check "$description"
    else
        pass "$description"
    fi
}

# Prüft einen Ausdruck über mehrere Zeilen: Zeilenumbrüche und Einrückung
# werden zu einem Leerzeichen zusammengefasst.
require_body_flat() {
    local description="$1"
    local pattern="$2"
    local body="$3"
    if tr -s '[:space:]' ' ' <<<"$body" | grep -qE "$pattern"; then
        pass "$description"
    else
        fail_check "$description"
    fi
}

# Zeilennummer des ersten Treffers im Rumpf; leer, wenn nichts passt.
body_line() {
    local pattern="$1"
    local body="$2"
    awk -v p="$pattern" '$0 ~ p { print NR; exit }' <<<"$body"
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
stock_entries_body="$(sed -n '/private func fetchStockEntries() async throws -> \[GrocyStockEntry\] {/,/^    }$/p' "$repo")"
shopping_entries_body="$(sed -n '/private func fetchShoppingListEntries() async throws -> \[GrocyShoppingEntry\] {/,/^    }$/p' "$repo")"
resolved_unit_body="$(sed -n '/private func resolvedUnitName(unitNames: \[Int: String\]) -> String {/,/^    }$/p' "$dto")"
stock_normalize_body="$(awk '/func normalize\($/{count++} count==1{print} count==2{exit}' "$dto")"
shopping_normalize_body="$(awk '/func normalize\($/{count++} count==2{print}' "$dto")"

# 1. Repository lädt die Einheiten und übergibt die Namensmap.
require "GrocyRepository kennt den Einheiten-Endpunkt" \
    'static let quantityUnits = "/objects/quantity_units"' "$repo"
require "GrocyRepository lädt die Einheiten als ID-Name-Map" \
    'func fetchQuantityUnits\(\) async throws -> \[Int: String\]' "$repo"
require_body "Einheiten laufen über den eigenen Client" \
    'unitsClient\.send\(' "$units_body"
require_body "Einheiten werden für den Dienst grocy gesendet" \
    'for: \.grocy' "$units_body"
require_body "Einheiten werden als GrocyQuantityUnit dekodiert" \
    'as: \[GrocyQuantityUnit\]\.self' "$units_body"
require_body "refresh lädt die Einheiten mit" \
    'async let unitsTask = loadQuantityUnits\(\)' "$refresh_body"
require_body_flat "Bestandsabruf startet ohne Einheiten" \
    'async let stockEntriesTask = fetchStockEntries\(\)' "$refresh_body"
require_body_flat "Einkaufsabruf startet ohne Einheiten" \
    'async let shoppingEntriesTask = fetchShoppingListEntries\(\)' "$refresh_body"
require_body_flat "refresh löst den Bestand mit der Namensmap auf" \
    'normalizeStock\(stockEntries, unitNames: units\.names, today: fetchedAt\)' "$refresh_body"
require_body_flat "refresh löst die Einkaufsliste mit der Namensmap auf" \
    'normalizeShoppingList\( shoppingEntries, catalog: catalog, unitNames: units\.names \)' "$refresh_body"
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
require_body "Bestandsabruf dekodiert Rohzeilen" \
    'as: \[GrocyStockEntry\]\.self' "$stock_entries_body"
require_body "Einkaufsabruf dekodiert Rohzeilen" \
    'as: \[GrocyShoppingEntry\]\.self' "$shopping_entries_body"
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

# 6. MARAAA-141 M2: Der Einheitenabruf blockiert den Tab nicht mehr.
require "Einheitenabruf läuft mit genau einem Versuch" \
    'RetryPolicy\(maxAttempts: 1\)' "$repo"
require "Einheitenabruf hat einen eigenen, benannten Timeout" \
    'unitsTimeout: TimeInterval = [0-9]+' "$repo"

units_timeout="$(sed -n 's/.*unitsTimeout: TimeInterval = \([0-9][0-9]*\).*/\1/p' "$repo" | head -1)"
if [[ -n "$units_timeout" && "$units_timeout" -ge 1 && "$units_timeout" -le 5 ]]; then
    pass "Einheiten-Timeout ist ${units_timeout} s (≤ 5 s)"
else
    fail_check "Einheiten-Timeout ist ≤ 5 s (gefunden: '${units_timeout}')"
fi

forbid_body "Einheiten werden nicht gemeinsam mit dem Bestand abgewartet" \
    'try await \(catalogTask, unitsTask\)' "$refresh_body"

stock_start="$(body_line 'async let stockEntriesTask' "$refresh_body")"
shopping_start="$(body_line 'async let shoppingEntriesTask' "$refresh_body")"
units_wait="$(body_line 'let units = await unitsTask' "$refresh_body")"

if [[ -n "$stock_start" && -n "$units_wait" && "$stock_start" -lt "$units_wait" ]]; then
    pass "Bestand startet vor dem Warten auf die Einheiten"
else
    fail_check "Bestand startet vor dem Warten auf die Einheiten (Bestand: '${stock_start}', Einheiten: '${units_wait}')"
fi

if [[ -n "$shopping_start" && -n "$units_wait" && "$shopping_start" -lt "$units_wait" ]]; then
    pass "Einkaufsliste startet vor dem Warten auf die Einheiten"
else
    fail_check "Einkaufsliste startet vor dem Warten auf die Einheiten (Einkauf: '${shopping_start}', Einheiten: '${units_wait}')"
fi

if [[ "$fail" -ne 0 ]]; then
    echo "Ergebnis: FEHLGESCHLAGEN"
    exit 1
fi

echo "Ergebnis: OK"
