#!/usr/bin/env bash
#
# Wire-Contract-Test für MARAAA-138 (Diagnose MARAAA-132, §5 B10).
#
# Warum dieser Test existiert:
# `Tests/Fixtures` enthielt bisher nur Normalformen (`meal_type`, `recipe_id`,
# `unit`). Die `verify_*.sh` prüften deshalb statischen Quelltext, aber nie die
# Feldnamen, die Mealie, Grocy, Hermes und worldplaner tatsächlich über die
# Leitung schicken. Genau daran sind Bild-URL (`image`-Token), Grocy-Einheiten
# (`qu_id_stock`/`qu_id`), Mealie-Freitext (`text`) und die Hermes-Hüllen
# (`data`, `has_more`, `pagination.returned`) vorbeigelaufen.
#
# Was der Test macht:
#   1. Er liest die echten Antwortformen aus `Tests/Fixtures/wire/` und prüft
#      ihre Pflichtfelder samt Typ (jq).
#   2. Er prüft die Decoder-Annahmen im Swift-Quelltext gegen genau diese
#      Feldnamen (CodingKeys, `nestedContainer`, Fallback-Reihenfolge).
#   3. Er prüft Querbezüge, die eine Schema-Prüfung allein nicht sieht:
#      jede `qu_id`/`qu_id_stock` ist in `quantity_units` auflösbar,
#      `pagination.returned` stimmt mit `data|length` überein,
#      `image` ist ein Token und keine Bild-URL.
#
# Warum bash+jq statt Swift-Test:
# Auf diesem Prüfstand gibt es keine Swift-Toolchain. Ein Swift-Test, der ohne
# Toolchain übersprungen wird, wäre hier wertlos — der Auftrag verlangt eine
# Prüfung, die auch ohne Mac läuft und rot werden kann.
#
# Selbsttest:
#   bash Tests/verify_wire_contracts.sh --selbsttest
# kopiert Tests/ und Planer/ in ein temporäres Verzeichnis und belegt, dass
# (a) `per_page` → `perPage`, (b) entferntes `qu_name` in der Fixture und
# (c) entferntes `qu_name` im Decoder den Test rot machen. Ein Test, der das
# nicht kann, wäre kein Test.
#
# Herkunft der Fixtures: siehe `Tests/Fixtures/wire/README.md`.
#
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$root"

wire="Tests/Fixtures/wire"
mealie_recipes="$wire/mealie_recipes.json"
mealie_mealplans="$wire/mealie_mealplans.json"
grocy_stock="$wire/grocy_stock.json"
grocy_shopping="$wire/grocy_shopping_list.json"
grocy_units="$wire/grocy_quantity_units.json"
hermes_sessions="$wire/hermes_sessions.json"
hermes_messages="$wire/hermes_messages.json"
worldplaner_tasks="$wire/worldplaner_tasks.json"

mealie_dto="Planer/Features/Mealie/MealieDTO.swift"
mealie_repo="Planer/Features/Mealie/MealieRepository.swift"
grocy_dto="Planer/Features/Grocy/GrocyDTO.swift"
grocy_repo="Planer/Features/Grocy/GrocyRepository.swift"
chat_dto="Planer/Features/Chat/ChatDTOs.swift"
todo_dto="Planer/Features/Todos/TodoDTO.swift"

checks=0
failures=0
selftest_tmp=""

pass() { checks=$((checks + 1)); echo "ok:   $1"; }
fail_check() { checks=$((checks + 1)); failures=$((failures + 1)); echo "FAIL: $1"; }

# jq_ok <Beschreibung> <jq-Filter> <Datei>
jq_ok() {
    local description="$1" filter="$2" file="$3"
    if jq -e "$filter" "$file" >/dev/null 2>&1; then
        pass "$description"
    else
        fail_check "$description ($file: $filter)"
    fi
}

# jq_slurp_ok <Beschreibung> <jq-Filter> <Datei A> <Datei B>
# Stellt beide Dateien als $a[0] und $b[0] bereit.
jq_slurp_ok() {
    local description="$1" filter="$2" file_a="$3" file_b="$4"
    if jq -e -n --slurpfile a "$file_a" --slurpfile b "$file_b" "$filter" >/dev/null 2>&1; then
        pass "$description"
    else
        fail_check "$description ($file_a + $file_b: $filter)"
    fi
}

require_fixed() {
    local description="$1" needle="$2" file="$3"
    if grep -qF -- "$needle" "$file"; then
        pass "$description"
    else
        fail_check "$description ($file: '$needle' fehlt)"
    fi
}

forbid_fixed() {
    local description="$1" needle="$2" file="$3"
    if grep -qF -- "$needle" "$file"; then
        fail_check "$description ($file: '$needle' gefunden)"
    else
        pass "$description"
    fi
}

require_regex() {
    local description="$1" pattern="$2" file="$3"
    if grep -qE -- "$pattern" "$file"; then
        pass "$description"
    else
        fail_check "$description ($file: /$pattern/ fehlt)"
    fi
}

forbid_regex() {
    local description="$1" pattern="$2" file="$3"
    if grep -qE -- "$pattern" "$file"; then
        fail_check "$description ($file: /$pattern/ gefunden)"
    else
        pass "$description"
    fi
}

run_checks() {
    # ------------------------------------------------------------------ #
    # 0. Alle Fixtures sind gültiges JSON.
    # ------------------------------------------------------------------ #
    local file
    for file in "$wire"/*.json; do
        if jq empty "$file" >/dev/null 2>&1; then
            pass "Fixture ist gültiges JSON: $(basename "$file")"
        else
            fail_check "Fixture ist kein gültiges JSON: $file"
        fi
    done

    # ------------------------------------------------------------------ #
    # 1. Mealie — Rezept-Bibliothek (`GET /recipes`)
    # ------------------------------------------------------------------ #
    jq_ok "Mealie recipes: page/per_page/total/total_pages sind Zahlen" \
        '(.page | type == "number") and (.per_page | type == "number")
         and (.total | type == "number") and (.total_pages | type == "number")' \
        "$mealie_recipes"
    jq_ok "Mealie recipes: wire-Feld heißt per_page, nicht perPage" \
        '(has("per_page")) and ((has("perPage")) | not)' \
        "$mealie_recipes"
    jq_ok "Mealie recipes: items ist eine nichtleere Liste" \
        '(.items | type == "array") and ((.items | length) > 0)' \
        "$mealie_recipes"
    jq_ok "Mealie recipes: jede Zeile trägt id/name/slug/image als String" \
        'all(.items[]; ((.id | type) == "string")
                    and ((.name | type) == "string")
                    and ((.slug | type) == "string")
                    and ((.image | type) == "string"))' \
        "$mealie_recipes"
    jq_ok "Mealie recipes: image ist ein Cache-Token, keine URL und kein Pfad" \
        'all(.items[]; (.image | test("^[A-Za-z0-9]+$")))' \
        "$mealie_recipes"
    jq_ok "Mealie recipes: Normalform-Schlüssel stehen nicht auf der Leitung" \
        'all(.items[]; ((has("meal_type") or has("recipe_id") or has("unit")) | not))' \
        "$mealie_recipes"

    require_fixed "MealiePagination dekodiert per_page" \
        'case perPage = "per_page"' "$mealie_dto"
    require_fixed "MealiePagination dekodiert total_pages" \
        'case totalPages = "total_pages"' "$mealie_dto"
    require_fixed "MealieRecipePage liest die Seitengrenzen aus derselben Hülle" \
        'pagination = try MealiePagination(from: decoder)' "$mealie_dto"
    require_fixed "MealieRecipePage liest das Wire-Array items" \
        'decode([MealieRecipeSummary].self, forKey: .items)' "$mealie_dto"
    if grep -qF 'let image: String' "$mealie_dto"; then
        fail_check "MealieRecipeSummary darf image nicht als Feld führen"
    else
        pass "MealieRecipeSummary führt image nicht als Feld"
    fi
    require_fixed "Bild-URL entsteht aus der Rezept-ID, nicht aus dem Token" \
        'imageURL: recipeID.flatMap { imageURL(forRecipeID: $0) }' "$mealie_repo"
    forbid_regex "Bild-URL greift nicht auf summary.image zu" \
        'summary\.image[^`]' "$mealie_repo"

    # ------------------------------------------------------------------ #
    # 2. Mealie — Wochenplan (`GET /households/mealplans`)
    # ------------------------------------------------------------------ #
    jq_ok "Mealie mealplans: Seitengrenzen sind auf der Leitung" \
        '(.page | type == "number") and (.per_page | type == "number")
         and (.total_pages | type == "number")' \
        "$mealie_mealplans"
    jq_ok "Mealie mealplans: jede Zeile trägt die ReadPlanEntry-Felder" \
        'all(.items[];
             has("date") and has("entryType") and has("recipeId")
             and has("recipeScale") and has("title") and has("text")
             and has("recipe"))' \
        "$mealie_mealplans"
    jq_ok "Mealie mealplans: Freitext-Eintrag (recipeId null, text gefüllt) ist enthalten" \
        'any(.items[]; (.recipeId == null) and (((.text // "") | length) > 0))' \
        "$mealie_mealplans"
    jq_ok "Mealie mealplans: Rezept-Eintrag trägt image-Token im verschachtelten recipe" \
        'any(.items[]; (.recipeId != null)
             and ((.recipe.image // "") | test("^[A-Za-z0-9]+$")))' \
        "$mealie_mealplans"
    jq_ok "Mealie mealplans: keine Normalform-Schlüssel auf der Leitung" \
        'all(.items[]; ((has("meal_type") or has("recipe_id")) | not))' \
        "$mealie_mealplans"

    require_fixed "MealiePlanEntry dekodiert entryType" \
        'let entryType: String?' "$mealie_dto"
    require_fixed "MealiePlanEntry dekodiert recipeId" \
        'let recipeId: String?' "$mealie_dto"
    require_fixed "MealiePlanEntry dekodiert den Freitext text" \
        'let text: String?' "$mealie_dto"
    require_regex "Freitext fällt in normalize auf text zurück" \
        'MealieText\.nonEmpty\(text\)' "$mealie_dto"
    require_fixed "Freitext-Zeile wird als solche erkannt" \
        'var isTextEntry: Bool { recipeID == nil }' "$mealie_dto"

    # ------------------------------------------------------------------ #
    # 3. Grocy — Bestand (`GET /stock`)
    # ------------------------------------------------------------------ #
    jq_ok "Grocy stock: nichtleere Liste" \
        '(. | type == "array") and ((. | length) > 0)' "$grocy_stock"
    jq_ok "Grocy stock: jede Zeile trägt product.qu_id_stock als Zahl" \
        'all(.[]; (.product.qu_id_stock | type == "number"))' "$grocy_stock"
    jq_ok "Grocy stock: die Einheit steht nicht als qu_name/stock_unit_name auf der Leitung" \
        'all(.[]; ((has("qu_name") or has("stock_unit_name")
                   or has("quantity_unit") or has("unit")) | not))' \
        "$grocy_stock"
    jq_slurp_ok "Grocy stock: jede qu_id_stock ist in quantity_units auflösbar" \
        '($b[0] | map(.id)) as $ids
         | all($a[0][]; . as $row
               | ($ids | index($row.product.qu_id_stock)) != null)' \
        "$grocy_stock" "$grocy_units"

    require_fixed "GrocyProduct dekodiert qu_id_stock" \
        'case quantityUnitStockID = "qu_id_stock"' "$grocy_dto"
    require_fixed "Bestands-Einheit wird über product.qu_id_stock aufgelöst" \
        'product?.quantityUnitStockID' "$grocy_dto"
    require_fixed "unbekannte Bestands-Einheit bleibt ein leerer String" \
        'unitNames[id] ?? ""' "$grocy_dto"

    # ------------------------------------------------------------------ #
    # 4. Grocy — Einkaufsliste + Einheiten
    # ------------------------------------------------------------------ #
    jq_ok "Grocy quantity_units: jede Zeile trägt id und name" \
        '(. | type == "array") and ((. | length) > 0)
         and all(.[]; ((.id | type) == "number") and ((.name | type) == "string"))' \
        "$grocy_units"
    jq_ok "Grocy shopping_list: jede Zeile hat das Feld qu_id" \
        'all(.[]; has("qu_id"))' "$grocy_shopping"
    jq_ok "Grocy shopping_list: mindestens eine Zeile hat eine qu_id" \
        'any(.[]; .qu_id != null)' "$grocy_shopping"
    jq_ok "Grocy shopping_list: Freitext-Zeile hat product_id und qu_id null" \
        'any(.[]; (.product_id == null) and (.qu_id == null)
             and (((.note // "") | length) > 0))' "$grocy_shopping"
    jq_ok "Grocy shopping_list: done ist die Zahl 0/1, kein Boolean" \
        'all(.[]; (.done | type == "number") and ((.done == 0) or (.done == 1)))' \
        "$grocy_shopping"
    jq_ok "Grocy shopping_list: qu_name-Anreicherung ist als Variante belegt" \
        'any(.[]; has("qu_name") and ((.qu_name // "") | length) > 0)' \
        "$grocy_shopping"
    jq_slurp_ok "Grocy shopping_list: jede gesetzte qu_id ist in quantity_units auflösbar" \
        '($b[0] | map(.id)) as $ids
         | all($a[0][]; . as $row
               | ($row.qu_id == null)
                 or (($ids | index($row.qu_id)) != null))' \
        "$grocy_shopping" "$grocy_units"

    require_fixed "GrocyShoppingEntry dekodiert qu_id" \
        'case quantityUnitID = "qu_id"' "$grocy_dto"
    require_fixed "GrocyShoppingEntry akzeptiert die qu_name-Anreicherung" \
        'case quantityUnitName = "qu_name"' "$grocy_dto"
    require_regex "Einkaufs-Einheit löst qu_id über die Einheitenmap auf" \
        'quantityUnitID\.flatMap \{ unitNames\[\$0\] \}' "$grocy_dto"
    require_regex "expliziter qu_name hat Vorrang vor der Einheitenmap" \
        '\[quantityUnitName, unit\]' "$grocy_dto"
    require_fixed "GrocyRepository kennt den quantity_units-Endpunkt" \
        'static let quantityUnits = "/objects/quantity_units"' "$grocy_repo"

    # ------------------------------------------------------------------ #
    # 5. Hermes — Sitzungen (`GET /api/sessions`)
    # ------------------------------------------------------------------ #
    jq_ok "Hermes sessions: object/data/limit/offset/has_more sind auf der Leitung" \
        '(.object == "list") and ((.data | type) == "array")
         and ((.limit | type) == "number") and ((.offset | type) == "number")
         and ((.has_more | type) == "boolean")' \
        "$hermes_sessions"
    jq_ok "Hermes sessions: das Array heißt data, nicht sessions" \
        '(has("data")) and ((has("sessions")) | not)' "$hermes_sessions"
    jq_ok "Hermes sessions: jede Zeile trägt id/source und numerische Zähler" \
        'all(.data[]; ((.id | type) == "string")
                     and ((.source | type) == "string")
                     and ((.message_count | type) == "number")
                     and ((.tool_call_count | type) == "number")
                     and ((.pinned | type) == "boolean")
                     and ((.archived | type) == "boolean"))' \
        "$hermes_sessions"
    require_fixed "SessionPage dekodiert data als sessions" \
        'case sessions = "data"' "$chat_dto"
    require_fixed "SessionPage dekodiert has_more" \
        'case hasMore = "has_more"' "$chat_dto"
    require_fixed "SessionSummary dekodiert message_count" \
        'case messageCount = "message_count"' "$chat_dto"
    require_fixed "SessionSummary dekodiert last_active" \
        'case lastActive = "last_active"' "$chat_dto"

    # ------------------------------------------------------------------ #
    # 6. Hermes — Nachrichten (`GET …/messages`)
    # ------------------------------------------------------------------ #
    jq_ok "Hermes messages: data und session_id sind auf der Leitung" \
        '((.data | type) == "array") and (((.data) | length) > 0)
         and ((.session_id | type) == "string")' \
        "$hermes_messages"
    jq_ok "Hermes messages: pagination.returned ist eine Zahl" \
        '(.pagination.returned | type == "number")' "$hermes_messages"
    jq_ok "Hermes messages: pagination.returned stimmt mit data|length überein" \
        '.pagination.returned == (.data | length)' "$hermes_messages"
    jq_ok "Hermes messages: returned steht nicht zusätzlich auf der obersten Ebene" \
        '((has("returned")) | not) and ((.pagination | has("returned")))' \
        "$hermes_messages"
    jq_ok "Hermes messages: jede Zeile trägt id/role; tool_calls und reasoning_content kommen vor" \
        'all(.data[]; ((.id | type) == "number") and ((.role | type) == "string"))
         and any(.data[]; (.reasoning_content | type) == "string")
         and any(.data[]; ((.tool_calls // []) | length) > 0)' \
        "$hermes_messages"
    require_fixed "MessagePage dekodiert data als messages" \
        'case messages = "data"' "$chat_dto"
    require_fixed "MessagePage erreicht pagination über einen nestedContainer" \
        'nestedContainer(keyedBy: PaginationKeys.self, forKey: .pagination)' "$chat_dto"
    require_fixed "MessagePage liest pagination.returned verpflichtend" \
        'returned = try p.decode(Int.self, forKey: .returned)' "$chat_dto"
    require_fixed "ChatMessage dekodiert reasoning_content" \
        'case reasoningContent = "reasoning_content"' "$chat_dto"
    require_fixed "ChatMessage dekodiert tool_calls" \
        'case toolCalls = "tool_calls"' "$chat_dto"

    # ------------------------------------------------------------------ #
    # 7. worldplaner — To-Dos (`GET /api/tasks`)
    # ------------------------------------------------------------------ #
    jq_ok "worldplaner tasks: nichtleere Liste" \
        '(. | type == "array") and ((. | length) > 0)' "$worldplaner_tasks"
    jq_ok "worldplaner tasks: due_at, completed_at und version stehen auf jeder Zeile" \
        'all(.[]; has("due_at") and has("completed_at") and has("version"))' \
        "$worldplaner_tasks"
    jq_ok "worldplaner tasks: version ist eine Zahl ab 1" \
        'all(.[]; ((.version | type) == "number") and (.version >= 1))' \
        "$worldplaner_tasks"
    jq_ok "worldplaner tasks: due_at ist null oder YYYY-MM-DD" \
        'all(.[]; (.due_at == null)
             or ((.due_at | type) == "string"
                 and (.due_at | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}$"))))' \
        "$worldplaner_tasks"
    jq_ok "worldplaner tasks: completed_at ist null oder ISO-8601-Zeitpunkt" \
        'all(.[]; (.completed_at == null)
             or ((.completed_at | type) == "string"
                 and (.completed_at | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$"))))' \
        "$worldplaner_tasks"
    jq_ok "worldplaner tasks: Fixture enthält gesetzte und leere Zeitfelder" \
        'any(.[]; .due_at != null) and any(.[]; .completed_at != null)
         and any(.[]; .due_at == null)' "$worldplaner_tasks"
    jq_ok "worldplaner tasks: keine camelCase-Schlüssel auf der Leitung" \
        'all(.[]; ((has("dueAt") or has("completedAt") or has("baseVersion")) | not))' \
        "$worldplaner_tasks"

    require_fixed "TodoDTO dekodiert due_at" \
        'case dueAt = "due_at"' "$todo_dto"
    require_fixed "TodoDTO dekodiert completed_at" \
        'case completedAt = "completed_at"' "$todo_dto"
    require_fixed "TodoDTO dekodiert version" \
        'let version: Int' "$todo_dto"
    require_fixed "TodoDTO führt due_at als optionales Datum" \
        'let dueAt: Date?' "$todo_dto"
    require_fixed "TodoDTO führt completed_at als optionales Datum" \
        'let completedAt: Date?' "$todo_dto"

    # ------------------------------------------------------------------ #
    # Ergebnis
    # ------------------------------------------------------------------ #
    echo
    echo "Prüfungen: $checks, fehlgeschlagen: $failures"
    if [ "$failures" -eq 0 ]; then
        echo "Ergebnis: OK"
        return 0
    fi
    echo "Ergebnis: FEHLGESCHLAGEN"
    return 1
}

# Belegt, dass der Test überhaupt rot werden kann. Jede Mutation läuft in einer
# Kopie; das Original bleibt unberührt.
run_selftest() {
    local tmp
    tmp="$(mktemp -d "${TMPDIR:-/tmp}/wire-selbsttest.XXXXXX")"
    selftest_tmp="$tmp"
    trap 'rm -rf "${selftest_tmp:-}"' EXIT

    cp -R Tests "$tmp/Tests"
    cp -R Planer "$tmp/Planer"

    local script="$tmp/Tests/verify_wire_contracts.sh"
    local selftest_fail=0
    local out rc

    # Baseline: unveränderte Kopie muss grün sein, sonst taugt der Selbsttest nicht.
    rc=0
    out="$(bash "$script" 2>&1)" || rc=$?
    if [ "$rc" -eq 0 ] && grep -q 'Ergebnis: OK' <<<"$out"; then
        echo "ok:   Selbsttest-Baseline ist grün"
    else
        echo "FAIL: Selbsttest-Baseline ist nicht grün (rc=$rc)"
        selftest_fail=1
    fi

    expect_red() {
        local label="$1"
        local run_rc=0 run_out
        run_out="$(bash "$script" 2>&1)" || run_rc=$?
        if [ "$run_rc" -eq 0 ]; then
            echo "FAIL: Mutation '$label' blieb grün — der Test fängt sie nicht"
            selftest_fail=1
            return
        fi
        if ! grep -q '^FAIL:' <<<"$run_out"; then
            echo "FAIL: Mutation '$label' wurde rot, aber ohne benannten Befund"
            selftest_fail=1
            return
        fi
        if grep -q 'Ergebnis: OK' <<<"$run_out"; then
            echo "FAIL: Mutation '$label' meldet trotz Rot 'Ergebnis: OK'"
            selftest_fail=1
            return
        fi
        echo "ok:   Mutation '$label' ist rot (rc=$run_rc)"
        grep '^FAIL:' <<<"$run_out" | head -2 | sed 's/^/      /'
    }

    local recipes="$tmp/Tests/Fixtures/wire/mealie_recipes.json"
    local shopping="$tmp/Tests/Fixtures/wire/grocy_shopping_list.json"
    local grocy_dto_copy="$tmp/Planer/Features/Grocy/GrocyDTO.swift"

    # (a) Feldname auf der Leitung vertauscht.
    sed -i 's/"per_page"/"perPage"/' "$recipes"
    expect_red "per_page → perPage in mealie_recipes.json"
    cp "$root/Tests/Fixtures/wire/mealie_recipes.json" "$recipes"

    # (b) Feld in der Fixture entfernt.
    jq 'map(del(.qu_name))' "$root/Tests/Fixtures/wire/grocy_shopping_list.json" > "$shopping"
    expect_red "qu_name aus grocy_shopping_list.json entfernt"
    cp "$root/Tests/Fixtures/wire/grocy_shopping_list.json" "$shopping"

    # (c) Feldannahme im Decoder entfernt.
    grep -v 'case quantityUnitName = "qu_name"' "$root/Planer/Features/Grocy/GrocyDTO.swift" \
        > "$grocy_dto_copy"
    expect_red "qu_name-Unterstützung aus GrocyDTO.swift entfernt"
    cp "$root/Planer/Features/Grocy/GrocyDTO.swift" "$grocy_dto_copy"

    echo
    if [ "$selftest_fail" -eq 0 ]; then
        echo "Selbsttest: OK (3/3 Mutationen rot)"
        return 0
    fi
    echo "Selbsttest: FEHLGESCHLAGEN"
    return 1
}

if [ "${1:-}" = "--selbsttest" ]; then
    run_selftest
else
    run_checks
fi
