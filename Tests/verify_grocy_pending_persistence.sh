#!/usr/bin/env bash
#
# Statischer Regressionstest für N3 (MARAAA-91): Die Grocy-Pending-Queue muss
# einen App-Neustart überleben und beim nächsten Lauf aus dem Cache repliziert
# werden (spec-ios §3.2/§10).
#
# Warum statisch: Auf diesem Prüfstand gibt es keine Swift-Toolchain; die
# übrigen WP-Abnahmen laufen ebenfalls über grep-/Schema-Prüfungen.
# Der Test schlägt fehl, solange die Queue nur im Speicher liegt, `GroceryItem`
# keinen Dirty-Marker trägt oder `replayPending()` nicht aus dem Cache liest.
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

entity="Planer/Cache/Entities/GroceryItem.swift"
repo="Planer/Features/Grocy/GrocyRepository.swift"
grocy_model="Planer/Features/Grocy/GrocyViewModel.swift"
mealie_model="Planer/Features/Mealie/MealieViewModel.swift"

# 1. Die Entity trägt den Dirty-/Pending-Marker (spec-ios §3).
require "GroceryItem trägt ein isDirty-Merkmal" \
    'var isDirty: Bool' "$entity"
require "isDirty hat im Init den Default false" \
    'isDirty: Bool = false' "$entity"
require "der Init setzt isDirty" \
    'self\.isDirty = isDirty' "$entity"

# 2. Der Read-through-Cache blendet Queue-Zeilen aus. Sonst würde `refresh()`
#    sie als „auf dem Server verschwunden“ löschen.
cached_body="$(sed -n '/func cachedItems(kind:/,/^    }$/p' "$repo")"
if grep -qE 'isDirty == false' <<<"$cached_body"; then
    pass "cachedItems blendet Queue-Zeilen aus"
else
    fail_check "cachedItems blendet Queue-Zeilen aus ($repo: cachedItems)"
fi

# 3. Die Queue wird aus dem Cache gelesen, älteste zuerst.
pending_body="$(sed -n '/func pendingItems()/,/^    }$/p' "$repo")"
if grep -qE 'isDirty == true' <<<"$pending_body"; then
    pass "pendingItems liest nur Queue-Zeilen"
else
    fail_check "pendingItems liest nur Queue-Zeilen ($repo: pendingItems)"
fi
if grep -qE 'SortDescriptor\(\\GroceryItem\.fetchedAt\)' <<<"$pending_body"; then
    pass "pendingItems sortiert nach Alter"
else
    fail_check "pendingItems sortiert nach Alter ($repo: pendingItems)"
fi

# 4. Die Queue ist keine flüchtige Instanzliste mehr.
forbid "pendingAdds ist keine gespeicherte Instanzliste" \
    'private\(set\) var pendingAdds' "$repo"
forbid "enqueue hängt nicht an ein In-Memory-Array an" \
    'pendingAdds\.append' "$repo"
forbid "replayPending schreibt kein In-Memory-Array zurück" \
    'pendingAdds = remaining' "$repo"

# 5. enqueue schreibt eine dauerhafte Cache-Zeile.
enqueue_body="$(sed -n '/func enqueue(/,/^    }$/p' "$repo")"
if grep -qE 'context\.insert\(item\)' <<<"$enqueue_body" \
    && grep -qE 'isDirty: true' <<<"$enqueue_body" \
    && grep -qE 'try context\.save\(\)' <<<"$enqueue_body"; then
    pass "enqueue legt eine dauerhafte, dirty markierte Zeile an"
else
    fail_check "enqueue legt eine dauerhafte, dirty markierte Zeile an ($repo: enqueue)"
fi
if grep -qE 'serverKey: "pending:' <<<"$enqueue_body"; then
    pass "Queue-Zeile nutzt einen eigenen serverKey"
else
    fail_check "Queue-Zeile nutzt einen eigenen serverKey ($repo: enqueue)"
fi

# 6. Replay liest die Queue aus dem Cache und räumt Erfolge weg.
replay_body="$(sed -n '/func replayPending()/,/^    }$/p' "$repo")"
if grep -qE 'try pendingItems\(\)' <<<"$replay_body"; then
    pass "replayPending liest die Queue aus dem Cache"
else
    fail_check "replayPending liest die Queue aus dem Cache ($repo: replayPending)"
fi
if grep -qE 'context\.delete\(item\)' <<<"$replay_body"; then
    pass "replayPending löscht übertragene Zeilen"
else
    fail_check "replayPending löscht übertragene Zeilen ($repo: replayPending)"
fi
if grep -qE 'try await addProduct\(' <<<"$replay_body"; then
    pass "replayPending überträgt die Zeile an Grocy"
else
    fail_check "replayPending überträgt die Zeile an Grocy ($repo: replayPending)"
fi

# Fehlerpfad: Eine fehlgeschlagene Übertragung darf die Zeile nicht löschen,
# sonst wäre die Operation verloren. `context.delete(item)` muss also im
# do-Block vor dem ersten `catch` stehen.
delete_line="$(grep -nE 'context\.delete\(item\)' <<<"$replay_body" | head -1 | cut -d: -f1)"
catch_line="$(grep -nE 'catch \{' <<<"$replay_body" | tail -1 | cut -d: -f1)"
if [[ -n "$delete_line" && -n "$catch_line" && "$delete_line" -lt "$catch_line" ]]; then
    pass "replayPending löscht nur erfolgreich übertragene Zeilen"
else
    fail_check "replayPending löscht nur erfolgreich übertragene Zeilen ($repo: replayPending)"
fi
if grep -qE 'failed \+= 1' <<<"$replay_body"; then
    pass "replayPending meldet Fehlschläge"
else
    fail_check "replayPending meldet Fehlschläge ($repo: replayPending)"
fi

# 7. Beide Aufrufer reichen den Produktnamen mit, den die Cache-Zeile braucht.
require "Einkaufs-Tab reicht den Produktnamen an die Queue" \
    'enqueue\(name: product\.name' "$grocy_model"
require "Rezepte-Tab reicht den Produktnamen an die Queue" \
    'enqueue\(name: product\.name' "$mealie_model"

# Ein Speicherfehler beim Vormerken darf nicht als Erfolg gelten.
require "Einkaufs-Tab meldet fehlgeschlagenes Vormerken" \
    'konnte nicht vorgemerkt werden' "$grocy_model"

if [[ "$fail" -ne 0 ]]; then
    echo "Ergebnis: FEHLGESCHLAGEN"
    exit 1
fi

echo "Ergebnis: OK"
