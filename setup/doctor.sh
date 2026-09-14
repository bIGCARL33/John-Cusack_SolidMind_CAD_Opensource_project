#!/usr/bin/env bash
# Check every link in the SolidMind CAD chain and say exactly what is broken.
#
#   MCP host (Claude Code) -> bridge server (server.main) -> TCP :9876 -> FreeCAD addon
#
# Exit code 0 = everything needed for cad.* tools is working.

set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

PASS=0; FAIL=0; WARN=0
ok()   { printf '  \033[32m✓\033[0m %s\n' "$*"; PASS=$((PASS+1)); }
bad()  { printf '  \033[31m✗\033[0m %s\n' "$*"; FAIL=$((FAIL+1)); }
warn() { printf '  \033[33m!\033[0m %s\n' "$*"; WARN=$((WARN+1)); }
hdr()  { printf '\n\033[1m%s\033[0m\n' "$*"; }

hdr "Python environment"
if [ -x .venv/bin/python ]; then
  V=$(.venv/bin/python -c 'import sys;print("%d.%d"%sys.version_info[:2])' 2>/dev/null)
  if .venv/bin/python -c 'import sys;sys.exit(0 if sys.version_info>=(3,12) else 1)' 2>/dev/null; then
    ok ".venv present, Python $V"
  else
    bad ".venv is Python $V — the project requires >= 3.12. Delete .venv and re-run setup/install.sh"
  fi
else
  bad "no .venv — run setup/install.sh"
fi

if .venv/bin/python -c 'import server.main' 2>/dev/null; then ok "server package imports"
else bad "cannot import server.main — run setup/install.sh"; fi

if .venv/bin/python -c 'import solidmind_geometry' 2>/dev/null; then
  ok "solidmind_geometry (Rust kernel) imports"
else
  bad "solidmind_geometry missing — rebuild with: .venv/bin/maturin develop --manifest-path geometry/Cargo.toml"
fi

hdr "MCP bridge server"
TOOLS=$(printf '%s\n%s\n%s\n' \
  '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"doctor","version":"1"}}}' \
  '{"jsonrpc":"2.0","method":"notifications/initialized"}' \
  '{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}' \
  | timeout 120 .venv/bin/python -m server.main 2>/dev/null \
  | .venv/bin/python -c '
import sys, json
for line in sys.stdin:
    line = line.strip()
    if not line:
        continue
    try:
        msg = json.loads(line)
    except ValueError:
        continue
    if msg.get("id") == 2 and "result" in msg:
        print(len(msg["result"]["tools"]))
        break
' 2>/dev/null)
if [ -n "${TOOLS:-}" ] && [ "$TOOLS" -gt 0 ] 2>/dev/null; then
  ok "bridge server responds — $TOOLS tools exposed"
else
  bad "bridge server did not answer tools/list"
fi

if [ -f .mcp.json ]; then ok ".mcp.json present (Claude Code will auto-start the server)"
else warn "no .mcp.json — run: cp .mcp.json.example .mcp.json"; fi

hdr "FreeCAD"
if command -v freecad >/dev/null 2>&1; then ok "freecad on PATH -> $(readlink -f "$(command -v freecad)")"
elif [ -x "${HOME}/Applications/squashfs-root/AppRun" ]; then warn "freecad not on PATH, but an extracted AppImage exists"
else bad "FreeCAD not installed — run setup/install.sh"; fi

# Both symlinks matter, for different reasons. See setup/install.sh step 6.
LEGACY="${HOME}/.local/share/FreeCAD/Mod/SolidMind"
[ -L "$LEGACY" ] && ok "addon symlink (for InitGui.py path resolution): $LEGACY" \
                 || bad "missing $LEGACY — addon will fail with ModuleNotFoundError: freecad_addon"

VERSIONED=$(ls -d "${HOME}/.local/share/FreeCAD"/v*/Mod/SolidMind 2>/dev/null | head -1)
if [ -n "$VERSIONED" ]; then ok "addon symlink (the one FreeCAD 1.1 actually scans): $VERSIONED"
else bad "no <UserAppData>/Mod/SolidMind symlink — FreeCAD will never load the addon (port 9876 stays silently closed)"; fi

hdr "Live connection"
if timeout 3 bash -c 'echo > /dev/tcp/127.0.0.1/9876' 2>/dev/null; then
  ok "FreeCAD addon is listening on 127.0.0.1:9876 — cad.* tools will work"
else
  bad "nothing on 127.0.0.1:9876 — start FreeCAD (\`freecad &\`, or setup/freecad-headless.sh start)"
fi

hdr "Optional simulation backends (only needed for motion.simulate / rl.*)"
for spec in "9877:Chrono daemon" "9878:Isaac bridge" "9879:Gazebo bridge"; do
  p="${spec%%:*}"; n="${spec#*:}"
  if timeout 2 bash -c "echo > /dev/tcp/127.0.0.1/${p}" 2>/dev/null; then ok "$n up on :$p"
  else printf '  \033[90m-\033[0m %s not running (:%s) — fine unless you need dynamic sim\n' "$n" "$p"; fi
done

printf '\n\033[1mSummary:\033[0m %d passed, %d failed, %d warnings\n' "$PASS" "$FAIL" "$WARN"
[ "$FAIL" -eq 0 ] || { echo "Fix the ✗ items above, then re-run setup/doctor.sh"; exit 1; }
echo "All good — start Claude Code in this directory and ask it to build something."
