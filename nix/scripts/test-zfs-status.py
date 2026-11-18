import subprocess
import unittest
from unittest.mock import patch

from zfs_status import snapshot_status


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


if __name__ == "__main__":
    unittest.main()
