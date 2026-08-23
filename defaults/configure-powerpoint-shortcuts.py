import os
import plistlib
import shutil
import tempfile
from pathlib import Path
from xml.parsers.expat import ExpatError

domain = "com.microsoft.Powerpoint"
plist_path = (
    Path.home()
    / "Library"
    / "Containers"
    / domain
    / "Data"
    / "Library"
    / "Preferences"
    / f"{domain}.plist"
)


def load_plist(path):
    if not path.exists():
        return {}
    with path.open("rb") as f:
        return plistlib.load(f)


def atomic_write(path, data):
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, temporary_path = tempfile.mkstemp(dir=path.parent, prefix=f".{path.name}.")
    try:
        with os.fdopen(fd, "wb") as f:
            plistlib.dump(data, f, fmt=plistlib.FMT_BINARY, sort_keys=False)
            f.flush()
            os.fsync(f.fileno())
        if path.exists():
            shutil.copystat(path, temporary_path)
            os.utime(temporary_path, None)
        os.replace(temporary_path, path)
    finally:
        if os.path.exists(temporary_path):
            os.unlink(temporary_path)


try:
    data = load_plist(plist_path)
    equivs = data.get("NSUserKeyEquivalents")
    if not isinstance(equivs, dict):
        equivs = {}

    # PowerPoint reads its sandbox-container preferences. Nested menu paths
    # use ESC separators, as written by macOS App Shortcuts settings.
    menu_prefix = "\x1bArrange\x1bAlign or Distribute\x1b"
    expected = {
        f"{menu_prefix}Align Left": "~^l",
        f"{menu_prefix}Align Center": "~^c",
        f"{menu_prefix}Align Right": "~^r",
        f"{menu_prefix}Align Top": "~^t",
        f"{menu_prefix}Align Middle": "~^m",
        f"{menu_prefix}Align Bottom": "~^b",
        f"{menu_prefix}Distribute Horizontally": "~^h",
        f"{menu_prefix}Distribute Vertically": "~^v",
    }

    # Remove only the invalid arrow-separated entries written by the previous
    # implementation while preserving any unrelated custom shortcuts.
    invalid_prefix = "Arrange->Align or Distribute->"
    invalid_keys = [
        f"{invalid_prefix}Align Left",
        f"{invalid_prefix}Align Center",
        f"{invalid_prefix}Align Right",
        f"{invalid_prefix}Align Top",
        f"{invalid_prefix}Align Middle",
        f"{invalid_prefix}Align Bottom",
        f"{invalid_prefix}Distribute Horizontally",
        f"{invalid_prefix}Distribute Vertically",
    ]
    removed = False
    for key in invalid_keys:
        removed = equivs.pop(key, None) is not None or removed

    changed = removed or not all(
        equivs.get(key) == value for key, value in expected.items()
    )
    if changed:
        equivs.update(expected)
        data["NSUserKeyEquivalents"] = equivs
        atomic_write(plist_path, data)

    if not changed:
        print("[INFO] PowerPoint shortcut settings are already set.")
        raise SystemExit(0)

    print("[SUCCESS] Updated PowerPoint shortcut settings.")
    raise SystemExit(10)
except PermissionError:
    print("[WARN] Skipped PowerPoint shortcut settings (permission denied).")
    raise SystemExit(1)
except (plistlib.InvalidFileException, ExpatError) as error:
    print(f"[WARN] Skipped PowerPoint shortcut settings (invalid plist: {error}).")
    raise SystemExit(1)
