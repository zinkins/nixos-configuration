"""Read-only ZFS snapshot metrics for the local dashboard."""

import subprocess


def format_bytes(size):
    units = ("Б", "КиБ", "МиБ", "ГиБ", "ТиБ", "ПиБ")
    value = size
    for unit in units:
        if value < 1024 or unit == units[-1]:
            text = str(value) if unit == "Б" else f"{value:.1f}".replace(".", ",")
            return f"{text} {unit}"
        value /= 1024


def snapshot_status(zfs, pool):
    unknown = {"zfsSnapshotCount": "—", "zfsSnapshotSpace": "—"}
    try:
        output = subprocess.check_output(
            [zfs, "list", "-H", "-p", "-r", "-t", "filesystem,volume,snapshot",
             "-o", "name,usedbysnapshots", pool],
            text=True, stderr=subprocess.DEVNULL, timeout=3,
        )
        count = 0
        space = 0
        found_pool = False
        for line in output.splitlines():
            name, used = line.split("\t")
            if name == pool:
                found_pool = True
            if "@" in name:
                count += 1
            else:
                # Each dataset's usedbysnapshots excludes its children's
                # snapshots; summing these values does not double-count them.
                value = int(used)
                if value < 0:
                    return unknown
                space += value
        if not found_pool:
            return unknown
        return {"zfsSnapshotCount": str(count),
                "zfsSnapshotSpace": format_bytes(space)}
    except (OSError, subprocess.SubprocessError, ValueError):
        return unknown
