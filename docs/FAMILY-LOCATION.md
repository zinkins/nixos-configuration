# Family location for `family.home`

`family-location.service` reads the unofficial 2GIS "Friends on Map" WebSocket feed and exposes only an allow-listed subset to the local dashboard.

The implementation is intentionally split into four pieces:

- `nix/family-location.nix` — NixOS service definition and build-time Python syntax check.
- `nix/family-location.py` — loopback-only 2GIS client, filtered JSON API, and map page.
- `nix/family-location-dashboard.nix` — Homepage iframe group.
- `nix/reverse-proxy.nix` — same-origin Caddy route at `/family-location/`.

Keeping Python in a normal source file is intentional: embedded HTML contains its own indentation and must not affect Nix indented-string processing. Nix compiles the Python source during the system build so syntax errors fail CI/`nixos-rebuild build` before activation.

The 2GIS protocol handling is based on the behavior documented by the MIT-licensed `Marker284/zond2gis` project. It uses an unofficial, undocumented 2GIS API and may require maintenance if 2GIS changes that API.

## Privacy model

- The 2GIS access token and selected display names are **not** stored in Git.
- The service receives the account's 2GIS location feed internally, but `/api/locations` emits only the authenticated account owner (when the token/feed lets it identify that state) and names explicitly listed in `FAMILY_LOCATION_NAMES`.
- The HTTP service listens only on `127.0.0.1:8085`; browser access goes through `family.home` and Caddy.
- The map uses OpenStreetMap raster tiles and loads Leaflet assets from `unpkg.com`. Those requests reveal the viewed map area / client IP to the respective public services.
- `family.home` itself is LAN-facing and has no additional authentication layer, so anyone who can open the dashboard can see the selected locations.

## One-time local secret configuration

Sign in to 2GIS normally (for example through Sber ID) and obtain the value of the `id_access_token` cookie from the authenticated 2GIS session. Do not commit or paste that token into chats or issue trackers.

Create `/var/lib/family-location/credentials.env` on the NixOS host:

```text
DGIS_ACCESS_TOKEN="replace-with-id_access_token-value"
FAMILY_LOCATION_NAMES="Friend One|Friend Two"
```

Use the display names exactly as they appear in the 2GIS friends list. Separate multiple names with `|`.

The secret file should be root-owned and readable only by root:

```bash
sudo chown root:root /var/lib/family-location/credentials.env
sudo chmod 600 /var/lib/family-location/credentials.env
```

`systemd` reads `EnvironmentFile=` before dropping privileges to the `family-location` service account, so the service file itself does not need direct filesystem permission to the secret file.

After changing the token or allow-list, restart the service:

```bash
sudo systemctl restart family-location.service
```

If the access token expires, obtain a fresh `id_access_token` from a newly authenticated 2GIS session and replace `DGIS_ACCESS_TOKEN`.

The owner does not need to be included in `FAMILY_LOCATION_NAMES` when the access token is a JWT whose subject matches a state from the feed. If 2GIS uses an opaque token or does not send the owner's state, friends can still work normally while the own-position marker remains unavailable.

## Diagnostics

Service state and recent logs:

```bash
systemctl status family-location.service
journalctl -u family-location.service -n 100 --no-pager
```

Filtered API as seen locally on the host:

```bash
curl -s http://127.0.0.1:8085/api/locations
```

Browser route through Caddy:

```text
http://family.home/family-location/
```

If the map says that the own position has not arrived, 2GIS is not sending an identifiable owner state. Friends can still work normally; do not synthesize or guess the owner's coordinates.
