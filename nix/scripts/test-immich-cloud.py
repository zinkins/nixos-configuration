"""Exercise encrypted config handling with real rclone and synthetic local data."""
import contextlib
import importlib.util
import io
import os
from pathlib import Path
import subprocess
import tempfile
from unittest.mock import patch

spec = importlib.util.spec_from_file_location("operator", Path(__file__).with_name("immich-operator.py"))
operator = importlib.util.module_from_spec(spec)
spec.loader.exec_module(operator)

with tempfile.TemporaryDirectory() as tmp, contextlib.redirect_stdout(io.StringIO()):
    operator.CLOUD = Path(tmp)
    conf = Path(tmp) / "rclone.conf"
    key = Path(tmp) / "rclone-config-password"
    conf.write_text("[mailru]\ntype = local\n")
    assert operator.prepare_cloud() is not None  # No password file needed.
    env = os.environ.copy()
    env["RCLONE_CONFIG_PASS"] = "synthetic-test-password"
    key.write_text(env["RCLONE_CONFIG_PASS"] + "\n")
    env["RCLONE_PASSWORD_COMMAND"] = "cat " + str(key)
    subprocess.run(["rclone", "--config", str(conf), "config", "encryption", "set"],
                   env=env, check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    key.unlink()
    encrypted = conf.read_bytes()
    assert b"RCLONE_ENCRYPT_V" in encrypted
    with patch.object(operator, "ask", return_value=False):
        assert operator.prepare_cloud() is None
        assert not key.exists()
    with patch.object(operator, "ask", return_value=True), patch.object(operator, "password", return_value="wrong"):
        assert operator.prepare_cloud() is None
        assert not key.exists()
    with patch.object(operator, "ask", return_value=True), patch.object(operator, "password", return_value=env["RCLONE_CONFIG_PASS"]):
        assert operator.prepare_cloud() is not None
        assert key.stat().st_mode & 0o777 == 0o600
    with patch.object(operator, "password", side_effect=AssertionError("Unexpected prompt")):
        assert operator.prepare_cloud() is not None
    key.write_text("wrong\n")
    assert operator.prepare_cloud() is None
    assert key.read_text() == "wrong\n"  # Never replace an existing secret.
    assert conf.read_bytes() == encrypted
print("Encrypted and plain rclone config tests passed")
