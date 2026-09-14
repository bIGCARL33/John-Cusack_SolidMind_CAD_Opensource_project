#!/usr/bin/env bash
# Install SolidMind CAD as a FreeCAD addon (symlink into FreeCAD's Mod directory).
# After running this, FreeCAD will auto-start the SolidMind socket server
# on every launch — no manual Python console commands needed.

set -euo pipefail

ADDON_DIR="$(cd "$(dirname "$0")/../freecad_addon" && pwd)"

# FreeCAD 1.1 keeps user data in a version-specific directory
# (~/.local/share/FreeCAD/v1-1/), and only scans the Mod directory inside it.
# Pre-1.1 builds used ~/.local/share/FreeCAD/Mod directly. Ask FreeCAD where
# its user data lives rather than guessing, so this keeps working across
# versions; fall back to probing the known layouts when FreeCAD cannot be run
# (headless CI, FreeCAD not yet on PATH).
query_freecad_appdata() {
    local out=""
    if command -v freecadcmd >/dev/null 2>&1; then
        out="$(freecadcmd -c 'import FreeCAD; print(FreeCAD.getUserAppDataDir())' 2>/dev/null | tail -1)"
    elif command -v freecad >/dev/null 2>&1; then
        # The AppImage's AppRun dispatches to usr/bin/<name> when given one.
        out="$(freecad freecadcmd -c 'import FreeCAD; print(FreeCAD.getUserAppDataDir())' 2>/dev/null | tail -1)"
    fi
    out="$(printf '%s' "$out" | tr -d '\r')"
    case "$out" in
        /*) printf '%s' "$out" ;;
        *)  printf '' ;;
    esac
}

resolve_mod_dir() {
    local appdata
    appdata="$(query_freecad_appdata)"
    if [ -n "$appdata" ]; then
        printf '%s/Mod' "${appdata%/}"
        return
    fi

    # Newest versioned directory (v1-1, v1-0, ...) if one already exists.
    local newest=""
    for d in "${HOME}/.local/share/FreeCAD"/v*/; do
        [ -d "$d" ] && newest="$d"
    done
    if [ -n "$newest" ]; then
        printf '%sMod' "$newest"
        return
    fi

    # Pre-1.1 layout.
    printf '%s' "${HOME}/.local/share/FreeCAD/Mod"
}

MOD_DIR="$(resolve_mod_dir)"
LINK="${MOD_DIR}/SolidMind"

mkdir -p "${MOD_DIR}"

if [ -L "${LINK}" ]; then
    echo "Symlink already exists: ${LINK} -> $(readlink "${LINK}")"
    echo "Removing old symlink..."
    rm "${LINK}"
elif [ -e "${LINK}" ]; then
    echo "Error: ${LINK} exists and is not a symlink. Remove it manually."
    exit 1
fi

ln -s "${ADDON_DIR}" "${LINK}"
echo "Installed: ${LINK} -> ${ADDON_DIR}"
echo ""
echo "Restart FreeCAD and the SolidMind addon will start automatically."
echo "If it does not, check the Report view (View -> Panels -> Report view)."
