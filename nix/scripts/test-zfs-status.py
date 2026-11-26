import subprocess
import unittest
from unittest.mock import patch, mock_open

from zfs_status import snapshot_status, arc_status


class SnapshotStatusTests(unittest.TestCase):
    def test_total_across_datasets(self):
        output = (
            "tank\t0\n"
            "tank/nas\t19327352832\n"
            "tank/nas@manual\t-\n"
            "tank/nas@automatic\t-\n"
            "tank/nas/films\t1073741824\n"
            "tank/nas/films@old\t-\n"
        )
        with patch("zfs_status.subprocess.check_output", return_value=output) as run:
            self.assertEqual(snapshot_status("zfs", "tank"), {
                "zfsSnapshotCount": "3", "zfsSnapshotSpace": "19,0 ГиБ",
            })
            self.assertEqual(run.call_args.args[0], [
                "zfs", "list", "-H", "-p", "-r", "-t",
                "filesystem,volume,snapshot", "-o", "name,usedbysnapshots", "tank",
            ])

    def test_no_snapshots(self):
        with patch("zfs_status.subprocess.check_output", return_value="tank\t0\ntank/nas\t0\n"):
            self.assertEqual(snapshot_status("zfs", "tank"), {
                "zfsSnapshotCount": "0", "zfsSnapshotSpace": "0 Б",
            })

    def test_errors_are_not_zero(self):
        unknown = {"zfsSnapshotCount": "—", "zfsSnapshotSpace": "—"}
        for error in (OSError(), subprocess.TimeoutExpired("zfs", 3),
                      subprocess.CalledProcessError(1, "zfs")):
            with patch("zfs_status.subprocess.check_output", side_effect=error):
                self.assertEqual(snapshot_status("zfs", "tank"), unknown)
        for output in ("", "tank/nas\t0\n", "tank\t-\n", "tank\tbad\n"):
            with patch("zfs_status.subprocess.check_output", return_value=output):
                self.assertEqual(snapshot_status("zfs", "tank"), unknown)


class ArcStatusTests(unittest.TestCase):
    def test_metrics(self):
        arc = "size 4 2147483648\nc_max 4 4294967296\nhits 4 90\nmisses 4 10\n"
        mem = "MemTotal: 8388608 kB\nMemAvailable: 3145728 kB\n"
        with patch("builtins.open", side_effect=[mock_open(read_data=arc)(), mock_open(read_data=mem)()]):
            self.assertEqual(arc_status(), {
                "zfsArcSize": "2,0 ГиБ", "zfsArcMax": "4,0 ГиБ",
                "zfsArcHitRate": "90,0%", "zfsRamWithoutArc": "3,0 ГиБ / 8,0 ГиБ",
            })

    def test_missing_arc(self):
        with patch("builtins.open", side_effect=OSError):
            self.assertEqual(arc_status(), dict.fromkeys(
                ("zfsArcSize", "zfsArcMax", "zfsArcHitRate", "zfsRamWithoutArc"), "—"))

    def test_no_requests_and_missing_memory(self):
        arc = "size 4 0\nc_max 4 1024\nhits 4 0\nmisses 4 0\n"
        with patch("builtins.open", side_effect=[mock_open(read_data=arc)(), OSError()]):
            result = arc_status()
        self.assertEqual(result["zfsArcSize"], "0 Б")
        self.assertEqual(result["zfsArcHitRate"], "—")
        self.assertEqual(result["zfsRamWithoutArc"], "—")


if __name__ == "__main__":
    unittest.main()
