# Family location for `family.home`

`family-location.service` reads the unofficial 2GIS "Friends on Map" WebSocket feed and exposes only an allow-listed subset to the local dashboard.

The implementation is intentionally split into four pieces:

- `nix/family-location.nix` — NixOS service definition and build-time Python syntax check.
- `nix/family-location.py` — loopback-only 2GIS client, filtered JSON API, and map page.
- `nix/family-location-dashboard.nix` — Homepage iframe group.
- `nix/reverse-proxy.nix` — same-origin Caddy route at `/family-location/`.

Keeping Python in a normal source file is intentional: embedded HTML contains its own indentation and must not affect Nix indented-string processing. Nix compiles the Python source during the system build and checks the embedded MapLibre JavaScript syntax with Node, so syntax errors fail CI/`nixos-rebuild build` before activation.

The 2GIS protocol handling is based on the behavior documented by the MIT-licensed `Marker284/zond2gis` project. It uses an unofficial, undocumented 2GIS API and may require maintenance if 2GIS changes that API.

## Privacy model

- The 2GIS access token and selected display names are **not** stored in Git.
- The service receives the account's 2GIS location feed internally, but `/api/locations` emits only the authenticated account owner (when the token/feed lets it identify that state) and names explicitly listed in `FAMILY_LOCATION_NAMES`.
- The HTTP service listens only on `127.0.0.1:8085`; browser access goes through `family.home` and Caddy.
- The map uses OpenStreetMap raster tiles and a pinned MapLibre GL JS 6.10.0 renderer loaded from `unpkg.com` (no Leaflet and no API key). The map requires WebGL in the browser. Tile and CDN requests reveal the client IP and viewed map area to the respective public services; no 2GIS access token is sent to either.
- `family.home` itself is LAN-facing and has no additional authentication layer, so anyone who can open the dashboard can see the selected locations.

## One-time local secret configuration

Sign in to 2GIS normally (for example through Sber ID) and obtain an access token from an authenticated session. The browser may expose the cookie `dg5_auth_access_token` rather than the older `id_access_token`; the former has been confirmed to authenticate the existing WebSocket feed on this installation. Do not commit or paste either token into chats or issue trackers.

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

If the access token expires, obtain a fresh working access-token cookie from a newly authenticated 2GIS session and replace `DGIS_ACCESS_TOKEN`.

The owner does not need to be included in `FAMILY_LOCATION_NAMES` when the access token is a JWT whose subject matches a state from the feed. If 2GIS uses an opaque token or does not send the owner's state, friends can still work normally while the own-position marker remains unavailable.


## Verify whether the WebSocket sends the account owner's position

The current browser cookie `dg5_auth_access_token` works for friend locations,
but `selfSeen: false` can mean **either** that the token cannot identify its
owner **or** that the WebSocket never supplies a state for the account owner.
Do not assume an extra state belongs to the owner.

To inspect the next `initialState` without leaking private location data,
edit the existing secret file on the **server**, adding just:

```ini
FAMILY_LOCATION_DIAGNOSTICS="1"
```

Then restart and read the one-line summary from the local systemd journal:

```bash
sudo systemctl restart family-location.service
sudo journalctl -u family-location.service -n 80 --no-pager | grep '2GIS initialState diagnostics'
```

The log includes **only** these fields: `tokenFormat` (opaque vs JWT-like),
`identityClaimDecoded`, `identityMatchesProfile`, `identityMatchesState`,
`profiles`, `states`, `statesWithCoordinates`, `statesWithoutProfile`,
`statesWithoutProfileCoordinates`, `namedProfilesOutsideAllowlistWithCoordinates`,
and `selfLikePayloadFields` (a fixed allowlist of protocol field **names**).

There are **no** location coordinates, names, profile IDs, or token values in
this diagnostic summary. This information stays in the server journal and is
not exposed by a public API endpoint.

Interpretation:

- `statesWithoutProfileCoordinates > 0` means the server supplied at least
  one geolocated state without a matching profile. It may be an owner state,
  but is **not evidence** that it belongs to the owner.
- `namedProfilesOutsideAllowlistWithCoordinates > 0` means some additional
  named profiles have locations in the feed. Again, these are not necessarily
  the account owner.
- `identityMatchesState: true` means the decoded token subject matched a
  feed state. A different token format or type of identifier may still prevent
  correct recognition.
- All extra-state counts at zero suggests the feed contains only the selected
  friends, but does not prove the server lacks a separate owner endpoint.

After collecting the summary, remove `FAMILY_LOCATION_DIAGNOSTICS` from the
secret file and restart the service to stop diagnostic logging. Never paste
the raw token or full WebSocket frames into a bug report.

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


## Map renderer

The family map uses MapLibre GL JS 6.10.0 for pan/zoom, DOM markers, and
initial fit-to-bounds. No Leaflet assets or code are loaded.

- Existing source: 2GIS WebSocket -> filtered local `/api/locations` endpoint.
- Basemap: OpenStreetMap raster tiles (subject to the OSM tile usage policy).
- Browser assets: pinned MapLibre JavaScript and CSS from `unpkg.com`.
- New points are plotted at `[longitude, latitude]`; markers update every
  10 seconds without resetting the user's manual pan or zoom.
- The map requires browser WebGL. If disabled, the page displays a warning.

The map still has an external CDN dependency. For fully offline maps or
avoiding third-party requests, additional self-hosted tiles/assets would be
needed and are outside this renderer change.
