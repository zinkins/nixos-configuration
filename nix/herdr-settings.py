"""Apply Herdr background network settings while preserving other user config.

The user systemd unit calls this on session startup. Existing configuration is
parsed and minimally modified, including comments, via tomlkit.
"""

import os
from pathlib import Path
import stat
import subprocess
import sys
import tempfile

import tomlkit


def config_path():
    override = os.environ.get("HERDR_CONFIG_PATH")
    if override:
        return Path(override).expanduser()
    base = os.environ.get("XDG_CONFIG_HOME")
    return (Path(base) if base else Path.home() / ".config") / "herdr" / "config.toml"


def configure(path):
    if path.is_symlink():
        raise RuntimeError(f"Refusing to replace symlinked Herdr configuration: {path}")

    old = path.read_text(encoding="utf-8") if path.exists() else ""
    doc = tomlkit.parse(old)
    update = doc.get("update")
    if update is None:
        doc.add("update", tomlkit.table())
        update = doc["update"]
    elif not hasattr(update, "__setitem__"):
        raise ValueError("Herdr config [update] must be a TOML table")

    # Release package updates are managed by Nix flake.lock, not Herdr.
    # Remote detection rules are refreshed by a daily systemd user timer.
    update["version_check"] = False
    update["manifest_check"] = False

    new = tomlkit.dumps(doc)
    if new == old:
        return False

    path.parent.mkdir(parents=True, exist_ok=True)
    if path.exists():
        permissions = stat.S_IMODE(path.stat().st_mode)
    else:
        permissions = 0o600
    fd, temporary = tempfile.mkstemp(prefix=".config.toml.", dir=path.parent)
    try:
        os.fchmod(fd, permissions)
        with os.fdopen(fd, "w", encoding="utf-8") as dest:
            dest.write(new)
            dest.flush()
            os.fsync(dest.fileno())
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)
    return True


def main():
    changed = configure(config_path())
    if changed and len(sys.argv) > 1:
        # An already-running Herdr reloads these two settings dynamically.
        # It may not be running yet; that is not an error for a login unit.
        subprocess.run(
            [sys.argv[1], "server", "reload-config"],
            check=False,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            timeout=8,
        )
    print("Herdr background checks disabled; daily timer handles agent manifests.")


if __name__ == "__main__":
    main()
