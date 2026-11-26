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


def arc_status(arc_path="/proc/spl/kstat/zfs/arcstats",
               mem_path="/proc/meminfo"):
    """Host-wide ARC counters and estimated RAM usage excluding ARC."""
    result = dict.fromkeys(("zfsArcSize", "zfsArcMax", "zfsArcHitRate",
                            "zfsRamWithoutArc"), "—")
    try:
        with open(arc_path, encoding="ascii") as stream:
            stats = {}
            for line in stream:
                parts = line.split()
                if len(parts) == 3 and parts[0] in ("size", "c_max", "hits", "misses"):
                    stats[parts[0]] = int(parts[2])
    except (OSError, ValueError):
        return result
    size = stats.get("size", -1)
    maximum = stats.get("c_max", -1)
    hits, misses = stats.get("hits", -1), stats.get("misses", -1)
    if size >= 0:
        result["zfsArcSize"] = format_bytes(size)
    if maximum > 0:
        result["zfsArcMax"] = format_bytes(maximum)
    if hits >= 0 and misses >= 0 and hits + misses > 0:
        result["zfsArcHitRate"] = f"{100 * hits / (hits + misses):.1f}%".replace(".", ",")
    try:
        with open(mem_path, encoding="ascii") as stream:
            mem = {}
            for line in stream:
                parts = line.split()
                if len(parts) == 3 and parts[0] in ("MemTotal:", "MemAvailable:") and parts[2] == "kB":
                    mem[parts[0]] = int(parts[1]) * 1024
        total, available = mem["MemTotal:"], mem["MemAvailable:"]
        if size >= 0 and 0 <= available <= total and total > 0:
            used = max(0, total - available - size)
            result["zfsRamWithoutArc"] = f"{format_bytes(used)} / {format_bytes(total)}"
    except (OSError, ValueError, KeyError):
        pass
    return result
