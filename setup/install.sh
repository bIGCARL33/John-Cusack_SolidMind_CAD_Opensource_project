#!/usr/bin/env bash
# SolidMind CAD — one-command setup for Linux.
#
# Verified end-to-end on Ubuntu 24.04 (x86_64) against FreeCAD 1.1.0:
# 2624 unit tests pass, the MCP server exposes 155 tools, and the
# planetary-gearbox example builds 6 real STEP parts that all pass validation.
#
# Usage:
#   setup/install.sh                 # full install (Python + Rust + FreeCAD + addon + MCP)
#   setup/install.sh --skip-freecad  # Python side only (tests + MCP server, no cad.* tools)
#   setup/install.sh --headless      # also install Xvfb so FreeCAD can run without a monitor
#
# Re-running is safe: every step is idempotent.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

FREECAD_VERSION="1.1.0"
FREECAD_APPIMAGE="FreeCAD_${FREECAD_VERSION}-Linux-x86_64-py311.AppImage"
FREECAD_URL="https://github.com/FreeCAD/FreeCAD/releases/download/${FREECAD_VERSION}/${FREECAD_APPIMAGE}"
APPS_DIR="${HOME}/Applications"

SKIP_FREECAD=0
HEADLESS=0
for arg in "$@"; do
  case "$arg" in
    --skip-freecad) SKIP_FREECAD=1 ;;
    --headless)     HEADLESS=1 ;;
    -h|--help)      sed -n '2,16p' "${BASH_SOURCE[0]}" | sed 's/^# \?//'; exit 0 ;;
    *) echo "Unknown option: $arg (try --help)" >&2; exit 2 ;;
  esac
done

say()  { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }
ok()   { printf '    \033[32m✓\033[0m %s\n' "$*"; }
warn() { printf '    \033[33m!\033[0m %s\n' "$*"; }
die()  { printf '\n\033[31mERROR: %s\033[0m\n' "$*" >&2; exit 1; }

# Use sudo only when we are not already root and sudo exists.
SUDO=""
if [ "$(id -u)" -ne 0 ]; then
  command -v sudo >/dev/null 2>&1 && SUDO="sudo" || warn "no sudo found; apt steps may fail"
fi

[ "$(uname -s)" = "Linux" ] || die "SolidMind CAD is Linux-only (macOS/Windows are not supported upstream)."

# ---------------------------------------------------------------- 1. system packages
say "1/7  System packages"
APT_PKGS="python3.12 python3.12-venv python3.12-dev build-essential curl wget"
# Qt needs these to open a window; the AppImage does not bundle them.
APT_PKGS="$APT_PKGS libxcb-cursor0 libxcb-xinerama0 libgl1"
[ "$HEADLESS" -eq 1 ] && APT_PKGS="$APT_PKGS xvfb"
if command -v apt-get >/dev/null 2>&1; then
  $SUDO apt-get update -qq
  # shellcheck disable=SC2086
  $SUDO apt-get install -y -qq $APT_PKGS
  ok "installed: $APT_PKGS"
else
  warn "not a Debian/Ubuntu system — install these yourself: $APT_PKGS"
fi

# ---------------------------------------------------------------- 2. python
say "2/7  Python interpreter (>= 3.12 required)"
PY=""
for cand in python3.12 python3.13; do
  command -v "$cand" >/dev/null 2>&1 && { PY="$cand"; break; }
done
if [ -z "$PY" ]; then
  if python3 -c 'import sys; sys.exit(0 if sys.version_info >= (3,12) else 1)' 2>/dev/null; then
    PY=python3
  else
    die "no Python >= 3.12 found. Install python3.12 and re-run."
  fi
fi
ok "using $PY ($($PY --version 2>&1))"

# ---------------------------------------------------------------- 3. rust
say "3/7  Rust toolchain (builds the solidmind_geometry kernel)"
if ! command -v cargo >/dev/null 2>&1; then
  [ -f "$HOME/.cargo/env" ] && . "$HOME/.cargo/env" || true
fi
if ! command -v cargo >/dev/null 2>&1; then
  curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --no-modify-path
  . "$HOME/.cargo/env"
fi
command -v cargo >/dev/null 2>&1 || die "cargo still not on PATH after rustup install"
ok "cargo $(cargo --version | awk '{print $2}')"

# ---------------------------------------------------------------- 4. venv + package
say "4/7  Virtualenv + SolidMind CAD"
[ -d .venv ] || "$PY" -m venv .venv
.venv/bin/pip install --quiet --upgrade pip
# `pip install -e .` uses the maturin build backend, which compiles the Rust
# extension as part of the editable install — a separate `maturin develop` is
# only needed after you edit the Rust sources.
.venv/bin/pip install -e . 2>&1 | tail -2
ok "solidmind-cad installed into .venv"

.venv/bin/python -c "import solidmind_geometry" \
  || die "solidmind_geometry failed to import — the Rust build did not produce a module"
ok "Rust geometry kernel imports"

# ---------------------------------------------------------------- 5. freecad
if [ "$SKIP_FREECAD" -eq 1 ]; then
  say "5/7  FreeCAD — skipped (--skip-freecad)"
  warn "cad.* tools and the examples will not run without FreeCAD"
else
  say "5/7  FreeCAD ${FREECAD_VERSION}"
  mkdir -p "$APPS_DIR"
  if [ ! -f "${APPS_DIR}/${FREECAD_APPIMAGE}" ]; then
    echo "    downloading ~800 MB, this takes a few minutes..."
    curl -fSL --retry 3 -o "${APPS_DIR}/${FREECAD_APPIMAGE}" "$FREECAD_URL"
  fi
  chmod +x "${APPS_DIR}/${FREECAD_APPIMAGE}"
  ok "AppImage at ${APPS_DIR}/${FREECAD_APPIMAGE}"

  # AppImages need FUSE. Where FUSE is unavailable (most containers, some
  # hardened hosts) the AppImage cannot self-mount, so extract it once and run
  # the extracted tree instead. Both layouts are supported below.
  if [ ! -d "${APPS_DIR}/squashfs-root" ]; then
    if command -v fusermount >/dev/null 2>&1 || command -v fusermount3 >/dev/null 2>&1; then
      ok "FUSE present — AppImage can run directly"
    else
      warn "no FUSE — extracting the AppImage (equally functional, just uses disk)"
      ( cd "$APPS_DIR" && "./${FREECAD_APPIMAGE}" --appimage-extract >/dev/null )
      ok "extracted to ${APPS_DIR}/squashfs-root"
    fi
  fi

  # Put `freecad` on PATH. Upstream says symlink the AppImage; when we had to
  # extract it, point at AppRun instead so the bundled Python/Qt still resolve.
  if [ -d "${APPS_DIR}/squashfs-root" ]; then
    FREECAD_TARGET="${APPS_DIR}/squashfs-root/AppRun"
  else
    FREECAD_TARGET="${APPS_DIR}/${FREECAD_APPIMAGE}"
  fi
  if [ -w /usr/local/bin ] || [ -n "$SUDO" ]; then
    $SUDO ln -sfn "$FREECAD_TARGET" /usr/local/bin/freecad
    ok "freecad -> $FREECAD_TARGET"
  else
    warn "cannot write /usr/local/bin; run: sudo ln -sfn $FREECAD_TARGET /usr/local/bin/freecad"
  fi
fi

# ---------------------------------------------------------------- 6. addon
say "6/7  FreeCAD addon"
# FreeCAD 1.1 keeps user data in ~/.local/share/FreeCAD/v1-1/ and only scans the
# Mod directory inside it, so the addon has to be linked there rather than into
# the legacy ~/.local/share/FreeCAD/Mod. scripts/install_freecad_addon.sh asks
# FreeCAD for that path itself, so just delegate to it.
[ -d "${REPO_ROOT}/freecad_addon" ] || die "freecad_addon/ not found — is this the SolidMind CAD repo?"
bash "${REPO_ROOT}/scripts/install_freecad_addon.sh"

# ---------------------------------------------------------------- 7. mcp config
say "7/7  MCP configuration"
if [ -f .mcp.json ]; then
  ok ".mcp.json already exists (left as-is)"
else
  cp .mcp.json.example .mcp.json
  ok "wrote .mcp.json from .mcp.json.example"
fi

say "Done."
cat <<EOF
Next steps:

  1. Start FreeCAD (it must be running before any cad.* tool works):
         freecad &
     Headless machine? Use:  setup/freecad-headless.sh start

  2. Check everything is wired up:
         setup/doctor.sh

  3. Start Claude Code in this directory — it reads .mcp.json and launches
     the bridge server automatically. Then ask for something, e.g.
         "Make a 20mm cube with 2mm fillets on all edges"

  Try the demo that proves the whole stack:
         PYTHONPATH=. .venv/bin/python examples/planetary_gearbox/run.py --out /tmp/gearbox
EOF
