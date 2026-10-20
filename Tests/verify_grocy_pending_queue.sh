#!/usr/bin/env bash
#
# Statischer Regressionstest für N2 (MARAAA-90): Die Grocy-Pending-Queue muss
# zwischen Rezepte- und Einkaufs-Tab geteilt sein.
#
# Warum statisch: Auf diesem Prüfstand gibt es keine Swift-Toolchain; die
# übrigen WP-Abnahmen laufen ebenfalls über grep-/Schema-Prüfungen.
# Der Test schlägt fehl, solange die geteilte Instanz oder das Nachlesen der
# Queue beim Öffnen des Einkaufs-Tabs fehlt.
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

repo="Planer/Features/Grocy/GrocyRepository.swift"
grocy_view="Planer/Features/Grocy/GrocyView.swift"
grocy_model="Planer/Features/Grocy/GrocyViewModel.swift"
mealie_view="Planer/Features/Mealie/MealieView.swift"
mealie_model="Planer/Features/Mealie/MealieViewModel.swift"

# 1. Es gibt genau eine app-weite Bezugsstelle für die geteilte Instanz.
require "geteilte Grocy-Instanz ist definiert" \
    'enum GrocyRepositoryProvider' "$repo"
require "geteilte Instanz wird über den Kontext aufgelöst" \
    'static func shared\(context: ModelContext\)' "$repo"
require "geteilte Instanz wird wiederverwendet" \
    'if let existing = instances\[key\]' "$repo"
require "geteilte Instanz wird je Kontext genau einmal angelegt" \
    'instances\[key\] = created' "$repo"
construction_count="$(grep -rc 'GrocyRepository(context:' Planer | awk -F: '{sum += $2} END {print sum+0}')"
if [[ "$construction_count" -eq 1 ]]; then
    pass "genau eine Konstruktionsstelle im App-Code"
else
    fail_check "genau eine Konstruktionsstelle im App-Code (gefunden: $construction_count)"
fi

# 2. Beide Tabs beziehen dieselbe Instanz statt eigener Repositories.
require "Einkaufs-Tab nutzt die geteilte Instanz" \
    'GrocyRepositoryProvider\.shared\(context: modelContext\)' "$grocy_view"
require "Rezepte-Tab nutzt die geteilte Instanz" \
    'GrocyRepositoryProvider\.shared\(context: modelContext\)' "$mealie_view"
forbid "Einkaufs-Tab baut keine eigene Instanz" \
    'GrocyRepository\(context:' "$grocy_view"
forbid "Rezepte-Tab baut keine eigene Instanz" \
    'GrocyRepository\(context:' "$mealie_view"
require "Rezepte-Tab legt Offline-Zutaten in die geteilte Queue" \
    'grocy\.enqueue\(' "$mealie_model"

# 3. Beim Öffnen des Einkaufs-Tabs wird die Queue neu gelesen, sonst bleibt
#    eine im Rezepte-Tab gefüllte Queue unsichtbar (Init-Wert ist dann stale).
#    Gezielt im Rumpf von load(), nicht irgendwo in der Datei (init reicht nicht).
load_body="$(sed -n '/func load() async {/,/^    }$/p' "$grocy_model")"
if grep -qE 'pendingCount = repository\.pendingAdds\.count' <<<"$load_body"; then
    pass "Öffnen des Einkaufs-Tabs liest die Queue neu"
else
    fail_check "Öffnen des Einkaufs-Tabs liest die Queue neu ($grocy_model: load())"
fi

# 4. Das Banner verspricht nur den tatsächlichen Ablauf: Der Einkaufs-Tab
#    versucht die Übertragung beim nächsten Öffnen.
require "Banner nennt den Einkaufs-Tab als Übertragungsstelle" \
    'Einkaufs-Tab.*nächsten Öffnen' "$mealie_model"
forbid "Banner verspricht keine sofortige Grocy-Übertragung" \
    'Grocy überträgt beim nächsten Öffnen' "$mealie_model"

if [[ "$fail" -ne 0 ]]; then
    echo "Ergebnis: FEHLGESCHLAGEN"
    exit 1
fi

echo "Ergebnis: OK"
