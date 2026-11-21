# Byparr for Cloudflare-protected Prowlarr indexers

Byparr runs locally on the NixOS host and provides a FlareSolverr-compatible API for indexers such as RuTracker that return a Cloudflare browser challenge to Prowlarr.

The container image is pinned to:

```text
ghcr.io/thephaseless/byparr:3.1.1
```

Important: the upstream Git release is named `v3.1.1`, but the GHCR container tag is `3.1.1` without the leading `v`. Using `:v3.1.1` fails with `manifest unknown`.

## Network paths

RuTracker uses two Prowlarr indexer proxies at the same time:

```text
Prowlarr normal indexer requests
  |
  | SOCKS5 127.0.0.1:1080  [tag: vpn]
  v
media-vpn-proxy
  |
  v
AmneziaWG awg0
  |
  v
RuTracker
```

For Cloudflare challenges Prowlarr additionally calls Byparr:

```text
Prowlarr
  |
  | http://127.0.0.1:8191  [tag: cloudflare]
  v
Byparr / Playwright
  |
  | SOCKS5 127.0.0.1:1080
  v
media-vpn-proxy
  |
  v
AmneziaWG awg0
  |
  v
Cloudflare / RuTracker
```

This is intentional. Prowlarr can select one ordinary indexer proxy and one FlareSolverr-compatible proxy for the same indexer. Keeping both tags makes the ordinary Prowlarr request and the browser challenge use the same VPN egress IP.

Byparr binds its API only to `127.0.0.1:8191`; port 8191 is not exposed to the LAN.

The Byparr browser is configured with:

```text
PROXY_SERVER=socks5://127.0.0.1:1080
```

The SOCKS endpoint is provided by `media-vpn-proxy`, whose outbound connections are bound to the AmneziaWG address. If that SOCKS endpoint is unavailable, the Byparr browser request fails instead of silently switching to the normal host route.

The v3.1.1 browser-launch integration retains a freshly cloned Firefox NSS
profile per request, including the explicit distrust certificate. Incoming
`X-Proxy-Server`, `X-Proxy-Username`, and `X-Proxy-Password` headers are
rejected with HTTP 403 rather than being allowed to override the configured
SOCKS proxy. `BYPARR_REQUIRE_PROXY=1` prevents an unproxied browser launch
if the configured proxy address is missing (the runtime still depends on the
actual SOCKS listener, so verify it and routing through AmneziaWG).

The rootful Podman container runs the application as UID 1000, with all Linux
capabilities dropped, `no-new-privileges`, and a PID limit. It still uses
host networking to reach the existing loopback-only SOCKS listener: that is
**not** a network namespace security boundary. Host network isolation is a
separate migration requiring a scoped SOCKS relay and an integration test.
No LAN or WAN firewall port is added by this update.

The pinned image is still tagged rather than locked to a registry digest,
so this update does not provide digest-level image reproducibility.

qBittorrent is not changed and continues to use the normal host route for peer traffic.

## Verify services

```bash
systemctl status amneziawg media-vpn-proxy podman-byparr prowlarr --no-pager
ss -lntp | grep -E ':(1080|8191)\b'
```

Expected listeners:

```text
127.0.0.1:1080  media-vpn-proxy
127.0.0.1:8191  Byparr
```

Check the Byparr API:

```bash
curl -fsS http://127.0.0.1:8191/health
```

Compare direct and VPN public addresses:

```bash
curl -4 https://api.ipify.org
echo
curl --socks5-hostname 127.0.0.1:1080 https://api.ipify.org
echo
```

The addresses should differ when AmneziaWG is active.

You can also verify that RuTracker itself is reached through the SOCKS proxy:

```bash
curl -I --socks5-hostname 127.0.0.1:1080 https://rutracker.org/forum/login.php
```

A `403` with `cf-mitigated: challenge` proves connectivity through the proxy but also proves that a browser challenge must be solved; that is the case Byparr handles.

## Configure Prowlarr

Open Prowlarr at:

```text
http://prowlarr.home
```

### 1. VPN SOCKS5 proxy

Under `Settings -> Indexers -> Indexer Proxies`, add SOCKS5:

```text
Name: Amnezia VPN
Host: 127.0.0.1
Port: 1080
Tags: vpn
```

### 2. Cloudflare solver

Under the same `Indexer Proxies` section add `FlareSolverr` (Byparr implements the compatible API):

```text
Name: Byparr
Host: http://127.0.0.1:8191
Request Timeout: 60 seconds
Tags: cloudflare
```

### 3. RuTracker tags

Configure RuTracker with both tags:

```text
vpn
cloudflare
```

Do not remove the `vpn` tag when enabling Byparr. The two proxies serve different purposes: SOCKS5 routes Prowlarr's indexer HTTP traffic through AmneziaWG, while Byparr solves Cloudflare challenges and itself also uses the same VPN-backed SOCKS endpoint.

Other torrent indexers that must use AmneziaWG should receive `vpn`. Add `cloudflare` only to indexers that actually need browser challenge solving.

## Logs

```bash
journalctl -u podman-byparr -n 200 --no-pager
journalctl -u media-vpn-proxy -n 100 --no-pager
journalctl -u prowlarr -n 200 --no-pager
```

After deployment, verify that the running image is 3.1.1, `podman-byparr`
is active, and Prowlarr's RuTracker proxy test succeeds. The GitHub Actions
Firefox smoke test checks the real browser and NSS distrust; it cannot
exercise the production VPN path. Test the actual VPN egress from the host.

If RuTracker still returns Cloudflare `403` after both proxies are configured, inspect the Byparr log while pressing **Test** on the indexer. Cloudflare protections change over time, so challenge solving is not guaranteed indefinitely. The container image is pinned to a specific Byparr release so upgrades are deliberate.
