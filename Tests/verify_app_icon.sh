#!/usr/bin/env bash
#
# Statischer Regressionstest für MARAAA-94 (G2-Hinweis H1): Das AppIcon-Set
# muss auf eine vorhandene 1024×1024-PNG-Datei ohne Alphakanal zeigen.
#
# Warum: Ein Eintrag ohne `filename` fällt im Simulator-Build nicht auf, lässt
# aber eine Archive-/App-Store-Validierung scheitern. App-Icons dürfen keinen
# Alphakanal tragen, weil iOS die Maskierung selbst vornimmt.
#
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$root"

set_dir="Planer/App/Assets.xcassets/AppIcon.appiconset"
contents="$set_dir/Contents.json"

fail=0

pass() { echo "ok:   $1"; }
fail_check() { echo "FAIL: $1"; fail=1; }

if grep -q '"filename"' "$contents"; then
    pass "Contents.json nennt eine Bilddatei"
else
    fail_check "Contents.json nennt keine Bilddatei"
fi

filename="$(sed -n 's/.*"filename"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$contents" | head -n 1)"
icon="$set_dir/${filename:-fehlt.png}"

if [ -n "$filename" ] && [ -f "$icon" ]; then
    pass "Bilddatei $filename existiert"
else
    fail_check "referenzierte Bilddatei fehlt"
fi

if [ -f "$icon" ]; then
    signature="$(od -An -tx1 -N8 "$icon" | tr -d ' \n')"
    if [ "$signature" = "89504e470d0a1a0a" ]; then
        pass "Datei ist ein PNG"
    else
        fail_check "Datei ist kein PNG"
    fi

    bytes=($(od -An -tu1 -j16 -N10 "$icon"))
    width=$(( ${bytes[0]} * 16777216 + ${bytes[1]} * 65536 + ${bytes[2]} * 256 + ${bytes[3]} ))
    height=$(( ${bytes[4]} * 16777216 + ${bytes[5]} * 65536 + ${bytes[6]} * 256 + ${bytes[7]} ))

    if [ "$width" -eq 1024 ] && [ "$height" -eq 1024 ]; then
        pass "Kantenlänge ist 1024x1024"
    else
        fail_check "Kantenlänge ist ${width}x${height}, erwartet 1024x1024"
    fi

    if [ "${bytes[8]}" -eq 8 ] && [ "${bytes[9]}" -eq 2 ]; then
        pass "8 Bit pro Kanal, RGB ohne Alphakanal"
    else
        fail_check "Bittiefe/Farbtyp ungeeignet (${bytes[8]} Bit, Typ ${bytes[9]})"
    fi
fi

if [[ "$fail" -ne 0 ]]; then
    echo "Ergebnis: FEHLGESCHLAGEN"
    exit 1
fi

echo "Ergebnis: OK"
