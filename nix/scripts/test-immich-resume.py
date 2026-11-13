"""Regression tests for resuming setup without credentials or mutations."""
import importlib.util
from pathlib import Path
import tempfile
from unittest.mock import patch

spec = importlib.util.spec_from_file_location("operator", Path(__file__).with_name("immich-operator.py"))
op = importlib.util.module_from_spec(spec)
spec.loader.exec_module(op)

data = {
    "users": [
        {"id": "admin", "name": "Administrator", "email": "admin@example.invalid", "isAdmin": True},
        {"id": "one", "name": "One", "email": "one@example.invalid", "isAdmin": False},
        {"id": "two", "name": "Two", "email": "two@example.invalid", "isAdmin": False},
    ],
    "albums": [{"id": "family", "name": "Family", "members": {"one": "owner", "two": "editor"}}],
}

def ready_api(path, *args, **kwargs):
    if path == "/server/config" and not args:
        return {"externalDomain": op.SHARE}
    if path == "/server/statistics" and not args and kwargs.get("key") == "synthetic":
        return {}
    raise AssertionError("Unexpected API operation: " + path)

with tempfile.TemporaryDirectory() as tmp:
    op.STATE = Path(tmp)
    op.KEY = op.STATE / "statistics-key"
    op.KEY.write_text("synthetic\n")
    with patch.object(op, "inventory", return_value=data), \
         patch.object(op, "api", side_effect=ready_api), \
         patch("builtins.input", side_effect=AssertionError("Unexpected prompt")), \
         patch.object(op, "password", side_effect=AssertionError("Unexpected password")):
        op.configure_accounts(True)  # Migration from previous wizard.
        assert op.read_selection() == {"album": "family", "owner": "one", "editor": "two", "admin": "admin"}
        op.configure_accounts(True)  # Repeated run.
        assert (op.STATE / "family-selection.json").stat().st_mode & 0o777 == 0o600
    # Only an unfinished external domain requires an admin login, never
    # the ordinary account passwords, and the album must not be modified.
    calls = []
    def repair_api(path, *args, **kwargs):
        calls.append((path, args))
        if path == "/server/config":
            return {"externalDomain": ""}
        if path == "/server/statistics":
            return {}
        if path == "/auth/login":
            assert args[1]["email"] == "admin@example.invalid"
            return {"accessToken": "synthetic-session", "isAdmin": True, "userId": "admin"}
        if path == "/system-config":
            if args:
                assert args[0] == "PUT" and args[1]["server"]["externalDomain"] == op.SHARE
                return {}
            return {"server": {"externalDomain": ""}}
        if path == "/auth/logout":
            return {}
        raise AssertionError(path)
    with patch.object(op, "inventory", return_value=data), \
         patch.object(op, "api", side_effect=repair_api), \
         patch("builtins.input", side_effect=AssertionError("Unexpected input")), \
         patch.object(op, "password", return_value="synthetic-password") as pw:
        op.configure_accounts(True)
        pw.assert_called_once()
        assert not any(path.startswith("/albums") for path, args in calls)
    with patch.object(op, "api", side_effect=op.SetupError("GET /server/statistics: HTTP 503")):
        try:
            op.stats_key_valid()
        except op.SetupError:
            pass
        else:
            raise AssertionError("Transient API errors must not rotate keys")
    assert op.existing_family(data, {"album": "deleted", "owner": "one", "editor": "two"}) is None
    assert op.existing_family({**data, "albums": []}, {}) is None
    assert op.existing_family({**data, "users": data["users"] + [
        {"id": "extra", "isAdmin": False}]}, {}) is None
print("Immich resume tests passed")
