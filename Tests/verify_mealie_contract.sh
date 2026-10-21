#!/usr/bin/env bash
#
# Statischer Regressionstest für MARAAA-134 und MARAAA-140: Mealie-Rezeptbilder
# laufen authentifiziert über den NetworkClient, die Bildbasis wird erst bei
# Zugriff aufgelöst, und Freitext-Einträge des Wochenplans (ReadPlanEntry mit
# recipeId = null) werden angezeigt — auch wenn zwei davon inhaltsgleich sind.
#
# Warum statisch: Auf diesem Prüfstand gibt es keine Swift-Toolchain; die
# übrigen Abnahmen laufen ebenfalls über grep-/Fixture-Prüfungen. Die
# Mealie-Demo verlangt Zugangsdaten, ein Live-Beleg ist ohne gültige Keychain
# nicht führbar. Die Prüfung fixiert deshalb die API-Zusagen aus dem Auftrag:
# `{basis}/media/recipes/{recipeId}/images/original.webp` bei Basis `…/api`,
# geladen über `NetworkClient.send` (einzige Header-Injektionsstelle), und eine
# Cache-ID des Freitexts, die die Server-ID des Planeintrags enthält.
#
# Der Test schlägt fehl, solange Bilder über `AsyncImage`/`URLSession.shared`
# ohne CF-/Bearer-Header laufen, die URL aus dem `image`-Token statt aus der
# Rezept-ID entsteht, die Basis-URL im Init eingefroren wird, die Ansicht den
# Bild-Loader an einer veralteten Adresse festmacht, Freitext-Zeilen verworfen
# werden oder zwei inhaltsgleiche Freitext-Zeilen zu einer Cache-ID kollidieren.
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

# jq_ok <Beschreibung> <jq-Filter> <Datei>
jq_ok() {
    local description="$1"
    local filter="$2"
    local file="$3"
    if jq -e "$filter" "$file" >/dev/null 2>&1; then
        pass "$description"
    else
        fail_check "$description ($file: $filter)"
    fi
}

dto="Planer/Features/Mealie/MealieDTO.swift"
repo="Planer/Features/Mealie/MealieRepository.swift"
view="Planer/Features/Mealie/MealieView.swift"
image_view="Planer/Features/Mealie/MealieImageView.swift"
fixture="Tests/Fixtures/mealie_mealplan_response.json"
duplicate_fixture="Tests/Fixtures/mealie_mealplan_duplicate_text.json"

normalize_body="$(sed -n '/func normalize() -> MealieMealPlanItem? {/,/^    }$/p' "$dto")"
hash_body="$(sed -n '/static func hashPrefix(_ value: String) -> String {/,/^    }$/p' "$dto")"
item_id_body="$(sed -n '/    var id: String {/,/^    }$/p' "$dto")"
image_url_body="$(sed -n '/func imageURL(forRecipeID recipeID: String) -> URL? {/,/^    }$/p' "$repo")"
image_path_body="$(sed -n '/static func imagePath(forRecipeID recipeID: String) -> String? {/,/^    }$/p' "$repo")"
fetch_body="$(sed -n '/func fetchImageData(forRecipeID recipeID: String) async throws -> Data {/,/^    }$/p' "$repo")"
plan_body="$(sed -n '/private func planRow(_ item: MealieMealPlanItem) -> some View {/,/^    }$/p' "$view")"
thumbnail_body="$(sed -n '/private func thumbnail(_ row: MealieRecipeRow) -> some View {/,/^    }$/p' "$view")"
init_body="$(sed -n '/^    init(/,/^    }$/p' "$repo")"
image_base_body="$(sed -n '/private var imageBaseURL: URL? {/,/^    }$/p' "$repo")"
load_key_body="$(sed -n '/private var loadKey: String {/,/^    }$/p' "$image_view")"
entry_parser_body="$(sed -n '/static func entryID(fromPlanCacheID id: String) -> String? {/,/^    }$/p' "$repo")"
entry_struct_body="$(sed -n '/^struct MealiePlanEntry: Decodable, Equatable {/,/^}$/p' "$dto")"

# 1. Bild-URL aus der Rezept-ID, Bilddaten über NetworkClient.send.
require "MealieRepository bildet die Bild-URL aus der Rezept-ID" \
    'func imageURL\(forRecipeID recipeID: String\) -> URL\?' "$repo"
require_body "Bild-Route ist /media/recipes/{id}/images/original.webp" \
    'media/recipes/.*/images/original\.webp' "$image_path_body"
require_body "Bild-URL hängt an die API-Basis die Bild-Route" \
    'Self\.imagePath\(forRecipeID: recipeID\)' "$image_url_body"
require "Bibliothekszeile nutzt die Rezept-ID für die Bild-URL" \
    'imageURL: recipeID\.flatMap \{ imageURL\(forRecipeID: \$0\) \}' "$repo"
forbid "Bild-URL entsteht nicht aus dem image-Token" \
    'summary\.image\?\.path' "$repo"
require "MealieRepository lädt Bilddaten" \
    'func fetchImageData\(forRecipeID recipeID: String\) async throws -> Data' "$repo"
require_body "Bilddaten laufen über NetworkClient.send" \
    'client\.send\(' "$fetch_body"
require_body "Bilddaten werden für den Dienst mealie gesendet" \
    'for: \.mealie' "$fetch_body"
require_body "leere Bildantwort ist ein Fehler" \
    'APIError\.emptyResponse' "$fetch_body"

if grep -rqE 'AsyncImage' Planer/Features/Mealie; then
    fail_check "kein AsyncImage mehr in Planer/Features/Mealie"
else
    pass "kein AsyncImage mehr in Planer/Features/Mealie"
fi
require "MealieView nutzt den authentifizierten Bild-Loader" \
    'recipeID: imageID,' "$view"
require "Bild-Loader hält Bilder in einem NSCache" \
    'NSCache<NSString, NSData>' "$image_view"
require "Bild-Loader liest aus dem In-Memory-Cache" \
    'MealieImageCache\.shared\.data' "$image_view"
require "Bild-Loader schreibt in den In-Memory-Cache" \
    'MealieImageCache\.shared\.store' "$image_view"
require "Bild-Loader lädt über das Repository" \
    'repository\.fetchImageData\(forRecipeID: recipeID\)' "$image_view"
require "Bild-Loader zeigt bei Fehler einen Platzhalter" \
    'case \.failed:' "$image_view"
require "Platzhalter ist als Symbol umgesetzt" \
    'private var placeholder' "$image_view"

# 2. Freitext-Einträge: text dekodieren, normalisieren, kennzeichnen.
require "MealiePlanEntry dekodiert text" \
    'let text: String\?' "$dto"
require "text ist im CodingKey-Satz" \
    '^        case text$' "$dto"
require_body "Freitext-Name kommt aus title, sonst text" \
    'MealieText\.nonEmpty\(title\) \?\? MealieText\.nonEmpty\(text\)' "$normalize_body"
require_body "Freitext behält recipeID = nil" \
    'recipeID: nil' "$normalize_body"
require "MealieMealPlanItem kennt Freitext-Zeilen" \
    'var isTextEntry: Bool \{ recipeID == nil \}' "$dto"
require "Freitext-Cache-ID trägt das Präfix plan:text:" \
    'static let textPrefix = "plan:text:"' "$dto"
require_body "Freitext-Cache-ID entsteht aus einem SHA-256-Präfix" \
    'SHA256\.hash\(data: Data\(value\.utf8\)\)' "$hash_body"
require "Freitext-ID nutzt Präfix und Hash" \
    'Self\.textPrefix \+ Self\.hashPrefix' "$dto"
require "Cache-Parser liefert für Freitext keine Rezept-ID" \
    'guard !id\.hasPrefix\(MealieMealPlanItem\.textPrefix\) else \{ return nil \}' "$repo"
require "Cache-Lesen übernimmt die optionale Rezept-ID" \
    'recipeID: Self\.recipeID\(fromPlanCacheID: row\.id\)' "$repo"
require_body "Anzeige kennzeichnet Freitext-Zeilen" \
    'item\.isTextEntry' "$plan_body"
require_body "Freitext-Zeile trägt die Kennzeichnung Freitext" \
    'Text\("Freitext"\)' "$plan_body"
forbid_body "Freitext-Zeile hat keine Zutaten-Aktion" \
    'addIngredients' "$plan_body"

# 3. Tastatur beim Scrollen dismissen.
require "MealieView dismissiert die Tastatur beim Scrollen" \
    '\.scrollDismissesKeyboard\(\.interactively\)' "$view"

# 4. Fixture: echter Mealie-Plan mit Freitext und image-Token.
if [[ -f "$fixture" ]]; then
    pass "Fixture $fixture vorhanden"
else
    fail_check "Fixture $fixture vorhanden"
fi
require "Fixture ist eine paginierte Mealie-Plan-Antwort" \
    '"per_page"' "$fixture"
require "Fixture enthält ein Rezept mit image-Token" \
    '"image": "4LEY"' "$fixture"
require "Fixture enthält einen Eintrag ohne Rezept-ID" \
    '"recipeId": null' "$fixture"
require "Fixture enthält einen Freitext-Eintrag" \
    '"text": "Reste"' "$fixture"

# 5. MARAAA-140 M1: Bildbasis wird bei Zugriff aufgelöst, nicht im Init.
require "Bildbasis ist eine bei Zugriff aufgelöste Eigenschaft" \
    'private var imageBaseURL: URL\? \{' "$repo"
require_body "Bildbasis wird bei jedem Zugriff aus der Keychain gelesen" \
    'ServiceConfiguration\.load\(\.mealie, keychain: keychain\)' "$image_base_body"
forbid_body "Init friert die Bildbasis nicht mehr ein" \
    'imageBaseURL' "$init_body"
forbid "kein zwischengespeicherter Basis-Wert im Repository" \
    'self\.imageBaseURL' "$repo"
require_body "Bild-URL nutzt die bei Zugriff aufgelöste Basis" \
    'guard let base = imageBaseURL' "$image_url_body"
require "Bibliothekszeile trägt die Rezept-ID für die Bild-Route" \
    'let imageID: String\?' "$dto"
require "Bibliothekszeile setzt imageID aus der Rezept-ID" \
    'imageID: recipeID,' "$repo"
require "Cache-Zeile setzt imageID aus der gespeicherten Rezept-ID" \
    'imageID: row\.id,' "$repo"
require_body "Thumbnail hängt an der Rezept-ID, nicht an der gebildeten Adresse" \
    'if let imageID = row\.imageID' "$thumbnail_body"
forbid_body "Thumbnail prüft nicht mehr die im Init gebildete Adresse" \
    'row\.imageURL != nil' "$thumbnail_body"
require "Bild-Loader wird bei geänderter Basis neu angestoßen" \
    '\.task\(id: loadKey\)' "$image_view"
require_body "Ladeschlüssel enthält Rezept-ID und gebildete Adresse" \
    'imageURL\?\.absoluteString' "$load_key_body"
require "Bild-Loader fragt die Basis bei jedem Ladeversuch neu ab" \
    'repository\.fetchImageData\(forRecipeID: recipeID\)' "$image_view"

# 6. MARAAA-140 N2: zwei inhaltsgleiche Freitext-Einträge bleiben zwei Zeilen.
if [[ -f "$duplicate_fixture" ]]; then
    pass "Fixture $duplicate_fixture vorhanden"
else
    fail_check "Fixture $duplicate_fixture vorhanden"
fi
jq_ok "Fixture enthält zwei inhaltsgleiche Freitext-Einträge mit verschiedenen Server-IDs" \
    '([.items[] | select(.recipeId == null)]
      | group_by([.date, .entryType, .text])
      | map(select((length == 2) and (([.[].id] | unique | length) == 2)))
      | length) == 1' "$duplicate_fixture"
jq_ok "Die beiden Freitext-Einträge ergeben zwei verschiedene Cache-IDs" \
    '([.items[] | select(.recipeId == null) | ("plan:text:" + .id)] | unique | length) == 2' \
    "$duplicate_fixture"
require_body "MealiePlanEntry dekodiert die Server-ID des Planeintrags" \
    'let id: String\?' "$entry_struct_body"
require_body "Server-ID ist im CodingKey-Satz der Planzeile" \
    '^        case id$' "$entry_struct_body"
require_body "Normalform liest die Server-ID des Eintrags" \
    'let entryID = MealieText\.nonEmpty\(id\)' "$normalize_body"
require_body "Normalform reicht die Server-ID in die Zeile" \
    'entryID: entryID,' "$normalize_body"
require_body "Freitext-Cache-ID enthält die Server-ID" \
    'Self\.textPrefix \+ entryID' "$item_id_body"
require_body "Freitext ohne Server-ID behält den Inhalts-Hash als Rückfall" \
    'Self\.textPrefix \+ Self\.hashPrefix' "$item_id_body"
require_body "Cache-Parser liest die Server-ID zurück" \
    'UUID\(uuidString: raw\)' "$entry_parser_body"
require "Cache-Roundtrip reicht die Server-ID in die Normalform" \
    'entryID: Self\.entryID\(fromPlanCacheID: row\.id\)' "$repo"
require "Cache-Schlüssel des Planeintrags ist die Normalform-ID" \
    '^        item\.id$' "$repo"

if [[ "$fail" -ne 0 ]]; then
    echo "Ergebnis: FEHLGESCHLAGEN"
    exit 1
fi

echo "Ergebnis: OK"
