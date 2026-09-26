# Family location for `family.home`

`family-location.service` reads the unofficial 2GIS "Friends on Map" WebSocket feed and exposes only an allow-listed subset to the local dashboard.

The implementation is intentionally split into three pieces:

- `nix/family-location.nix` — loopback-only 2GIS client, filtered JSON API, and self-contained map page.
- `nix/family-location-dashboard.nix` — Homepage iframe group.
- `nix/reverse-proxy.nix` — same-origin Caddy route at `/family-location/`.

The 2GIS protocol handling is based on the behavior documented by the MIT-licensed `Marker284/zond2gis` project. It uses an unofficial, undocumented 2GIS API and may require maintenance if 2GIS changes that API.

## Privacy model

- Credentials and selected display names are **not** stored in Git.
- The service receives the account's 2GIS location feed internally, but `/api/locations` emits only the authenticated account owner (when 2GIS supplies that state) and names explicitly listed in `FAMILY_LOCATION_NAMES`.
- The HTTP service listens only on `127.0.0.1:8085`; browser access goes through `family.home` and Caddy.
- The map uses OpenStreetMap raster tiles. Tile requests reveal the viewed map area to the OpenStreetMap tile service.
- `family.home` itself is LAN-facing and has no additional authentication layer, so anyone who can open the dashboard can see the selected locations.

## One-time local secret configuration

Create `/var/lib/family-location/credentials.env` on the NixOS host. The file must stay outside Git and should be readable only by root:

```text
DGIS_EMAIL="account@example.com"
DGIS_PASSWORD="replace-with-2gis-password"
FAMILY_LOCATION_NAMES="Friend One|Friend Two"
```

Use the display names exactly as they appear in the 2GIS friends list. Separate multiple names with `|`.

After changing the file, restart the service:

```bash
sudo systemctl restart family-location.service
```

The owner of the authenticated 2GIS account does not need to be added to `FAMILY_LOCATION_NAMES`. The service identifies the owner by the account UID and labels that marker `Я` if the 2GIS feed includes the owner's state.

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

If the map says that the own position has not arrived, 2GIS is not sending a state whose UID matches the authenticated account. Friends can still work normally; do not synthesize or guess the owner's coordinates.
