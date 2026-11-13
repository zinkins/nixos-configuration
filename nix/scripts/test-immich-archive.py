"""Regression tests for archive-only, once-only album membership."""
import importlib.util
from pathlib import Path
from unittest.mock import patch

spec = importlib.util.spec_from_file_location("operator", Path(__file__).with_name("immich-operator.py"))
op = importlib.util.module_from_spec(spec)
spec.loader.exec_module(op)
assert op.archive_remote("Family/Photos") == "mailru:Family/Photos"
for invalid in ("", "/", "..", "ImmichBackups/restic", "a/../b", "mailru:"):
    try:
        op.archive_remote(invalid)
    except op.SetupError:
        pass
    else:
        raise AssertionError(invalid)
rows = [{"id": "a", "path": "/a", "member": True, "visible": True},
        {"id": "b", "path": "/b", "member": False, "visible": True},
        {"id": "c", "path": "/c", "member": False, "visible": False}]
assert op.archive_plan(["/a", "/b", "/c"], rows) == (set(), set(), ["b"])
assert op.archive_plan(["/a", "/d"], rows) == ({"/d"}, {"/b", "/c"}, [])
with patch.object(op, "archive_state", return_value={"phase": "complete"}), \
     patch.object(op, "ask", side_effect=AssertionError("Repeated prompt")):
    op.configure_archive()
print("Archive plan tests passed")
