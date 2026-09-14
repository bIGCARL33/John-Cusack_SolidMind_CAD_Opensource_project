"""FreeCAD auto-start hook for SolidMind CAD addon.

When this package is installed as a FreeCAD Mod (see
``scripts/install_freecad_addon.sh``), FreeCAD execs this file on startup and
the SolidMind socket server starts automatically.

Two constraints shape the code below, and both are easy to trip over:

1. FreeCAD execs InitGui.py with no ``__file__``, so the usual
   ``Path(__file__).parent`` is unavailable. It does prepend each addon's own
   directory to ``sys.path`` first, so this file's directory can be recovered
   from there — which works whichever Mod directory the addon was installed
   into, and whatever the symlink was named.
2. FreeCAD execs this file with separate globals and locals mappings, so names
   bound here land in locals while nested scopes look names up in the (empty)
   globals. Helper functions and comprehensions therefore raise ``NameError``
   when they touch a name defined in this file. Everything stays inline, with
   plain loops rather than comprehensions.
"""

from __future__ import annotations

import sys
from pathlib import Path

_ADDON_MARKERS = ("InitGui.py", "socket_server.py", "protocol.py")

_repo_root = None

# 1. Preferred: the sys.path entry FreeCAD added for this addon. Match on files
#    that identify this addon so a different Mod is never picked up.
for _entry in sys.path:
    if not _entry:
        continue
    _candidate = Path(_entry)
    _is_addon = True
    for _marker in _ADDON_MARKERS:
        if not (_candidate / _marker).is_file():
            _is_addon = False
            break
    if _is_addon:
        _repo_root = _candidate.resolve().parent
        break

# 2. Fallback: the known Mod locations. FreeCAD 1.1 keeps user data in a
#    version-specific directory (~/.local/share/FreeCAD/v1-1/); older builds
#    used ~/.local/share/FreeCAD directly.
if _repo_root is None:
    _roots = []
    try:
        _roots.append(Path(FreeCAD.getUserAppDataDir()))
    except Exception:
        pass
    _roots.append(Path.home() / ".local" / "share" / "FreeCAD")
    for _root in _roots:
        _mod_dir = _root / "Mod" / "SolidMind"
        if _mod_dir.is_dir():
            _repo_root = _mod_dir.resolve().parent
            break

try:
    if _repo_root is None:
        raise RuntimeError(
            "could not locate the SolidMind repo root — reinstall the addon "
            "with scripts/install_freecad_addon.sh"
        )
    if str(_repo_root) not in sys.path:
        sys.path.insert(0, str(_repo_root))

    import freecad_addon

    freecad_addon.start()
    FreeCAD.Console.PrintMessage("[SolidMind] Addon started successfully\n")
except Exception as exc:
    import traceback

    FreeCAD.Console.PrintError(f"[SolidMind] Failed to start: {exc}\n")
    FreeCAD.Console.PrintError(traceback.format_exc() + "\n")
