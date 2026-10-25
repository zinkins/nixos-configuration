"""Offline regression tests for safe 2GIS owner-position diagnostics.

Run with the NixOS service's Python environment; no network, account or token needed.
"""
import json
import os
import runpy
import sys

app = runpy.run_path(sys.argv[1], run_name="family_location_test")
diagnose = app["initial_state_diagnostics"]
globals_ = diagnose.__globals__
os.environ["DGIS_ACCESS_TOKEN"] = "opaque_test_access_secret"
os.environ["FAMILY_LOCATION_NAMES"] = "Марина|Ульяна"
globals_["account_uid"] = ""

payload = {
    "serverTime": 1790000000000,
    "profiles": [
        {"id": "friend1", "name": "Марина", "logo": "PRIVATE"},
        {"id": "friend2", "name": "Ульяна", "logo": "PRIVATE"},
    ],
    "states": [
        {"id": "friend1", "location": {"lat": 55.111111, "lon": 82.222222}},
        {"id": "friend2", "location": {"lat": 55.333333, "lon": 82.444444}},
    ],
}
result = diagnose(payload)
assert result["tokenFormat"] == "opaque", result
assert result["profiles"] == 2 and result["states"] == 2, result
assert result["statesWithCoordinates"] == 2, result
assert result["statesWithoutProfileCoordinates"] == 0, result
assert result["namedProfilesOutsideAllowlistWithCoordinates"] == 0, result
assert result["identityClaimDecoded"] is False, result

# An anonymous third state is evidence of another position in the feed, NOT
# evidence that it belongs to the account owner. Never label it automatically.
payload["states"].append({
    "id": "unprofiled_private_id",
    "location": {"lat": 56.555555, "lon": 83.666666},
})
payload["currentUser"] = {"id": "private_account_id", "location": {"lat": 54.7}}
result = diagnose(payload)
assert result["statesWithoutProfile"] == 1, result
assert result["statesWithoutProfileCoordinates"] == 1, result
assert result["identityMatchesState"] is False, result
assert result["selfLikePayloadFields"] == ["currentUser"], result

# Simulate a decoded JWT subject matching a state but not an ordinary profile.
globals_["account_uid"] = "unprofiled_private_id"
result = diagnose(payload)
assert result["identityMatchesState"] is True, result
assert result["identityMatchesProfile"] is False, result
assert result["identityClaimDecoded"] is True, result

# Never disclose raw names, IDs, positions, or credential fragments, even with
# malformed input containing other nested structures.
serialized = json.dumps(result, ensure_ascii=False)
for forbidden in (
    "Марина", "Ульяна", "friend1", "unprofiled_private_id",
    "private_account_id", "55.111111", "83.666666", "access_secret",
):
    assert forbidden not in serialized, forbidden

result = diagnose({"profiles": {}, "states": None, "self": {}})
assert result["profiles"] == 0 and result["states"] == 0, result
assert result["selfLikePayloadFields"] == ["self"], result
print("2GIS location diagnostic tests passed")
