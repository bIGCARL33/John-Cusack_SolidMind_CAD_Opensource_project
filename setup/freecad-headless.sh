#!/usr/bin/env bash
# Run FreeCAD (and therefore the SolidMind addon) on a machine with no monitor.
#
# The addon lives in FreeCAD's *GUI* startup path — freecadcmd will not start it
# — so a headless box still needs a real FreeCAD window, just on a virtual X
# display. Xvfb provides that. This is how the planetary-gearbox example was
# verified in a container with no graphics at all.
#
# Usage:
#   setup/freecad-headless.sh start    # launch on virtual display, wait for port 9876
#   setup/freecad-headless.sh stop     # shut it down
#   setup/freecad-headless.sh status   # is the addon reachable?

set -euo pipefail

PORT=9876
LOG=/tmp/solidmind-freecad.log
TIMEOUT=240

port_open() { timeout 3 bash -c "echo > /dev/tcp/127.0.0.1/${PORT}" 2>/dev/null; }

find_freecad() {
  if [ -x "${HOME}/Applications/squashfs-root/AppRun" ]; then
    echo "${HOME}/Applications/squashfs-root/AppRun"; return
  fi
  command -v freecad >/dev/null 2>&1 && { command -v freecad; return; }
  local img
  img="$(ls -1 "${HOME}/Applications"/FreeCAD_*.AppImage 2>/dev/null | head -1 || true)"
  [ -n "$img" ] && { echo "$img"; return; }
  echo ""
}

case "${1:-status}" in
  start)
    if port_open; then echo "Already running — addon reachable on port ${PORT}."; exit 0; fi
    command -v xvfb-run >/dev/null 2>&1 || {
      echo "xvfb-run not found. Install it:  sudo apt-get install -y xvfb" >&2; exit 1; }
    BIN="$(find_freecad)"
    [ -n "$BIN" ] || { echo "FreeCAD not found. Run setup/install.sh first." >&2; exit 1; }

    # Qt refuses to start under the C/POSIX locale.
    export LC_ALL="${LC_ALL:-C.UTF-8}" LANG="${LANG:-C.UTF-8}"
    echo "Starting $BIN on a virtual display (log: $LOG)"
    nohup xvfb-run -a --server-args="-screen 0 1600x1200x24" "$BIN" >"$LOG" 2>&1 &

    # FreeCAD takes ~60-90s to reach the point where the addon binds the socket.
    for _ in $(seq 1 $((TIMEOUT / 5))); do
      sleep 5
      if port_open; then echo "Ready — SolidMind addon listening on 127.0.0.1:${PORT}"; exit 0; fi
      if grep -q "SolidMind. Failed to start" "$LOG" 2>/dev/null; then
        echo "Addon failed to start:" >&2; cat "$LOG" >&2
        echo "Hint: re-run setup/install.sh — both Mod symlinks must exist." >&2
        exit 1
      fi
    done
    echo "Timed out after ${TIMEOUT}s. Log:" >&2; cat "$LOG" >&2; exit 1
    ;;
  stop)
    pkill -x freecad 2>/dev/null || true
    pkill -x AppRun  2>/dev/null || true
    pkill -x Xvfb    2>/dev/null || true
    echo "Stopped."
    ;;
  status)
    if port_open; then echo "SolidMind addon: reachable on 127.0.0.1:${PORT}"
    else echo "SolidMind addon: NOT reachable on 127.0.0.1:${PORT}"; exit 1; fi
    ;;
  *) echo "Usage: $0 {start|stop|status}" >&2; exit 2 ;;
esac
