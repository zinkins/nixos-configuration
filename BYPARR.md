# Byparr for Cloudflare-protected Prowlarr indexers

Byparr runs locally on the NixOS host and provides a FlareSolverr-compatible API for indexers such as RuTracker that may return a Cloudflare challenge to Prowlarr.

## Network path

```text
Prowlarr
  |
  | http://127.0.0.1:8191
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
Cloudflare / indexer
```

Byparr binds its API only to `127.0.0.1:8191`; the port is not exposed to the LAN.

The Byparr browser is configured with:

```text
PROXY_SERVER=socks5://127.0.0.1:1080
```

The SOCKS proxy is the existing `media-vpn-proxy` service, which binds outbound connections to the AmneziaWG address. If the SOCKS endpoint is unavailable, the browser request fails instead of using the host's normal route.

qBittorrent is not changed and keeps using the normal host route for peer traffic.

## Verify services

```bash
systemctl status amneziawg media-vpn-proxy podman-byparr --no-pager
ss -lntp | grep -E ':(1080|8191)\b'
```

Expected listeners:

```text
127.0.0.1:1080  media-vpn-proxy
127.0.0.1:8191  Byparr
```

Check the API:

```bash
curl -fsS http://127.0.0.1:8191/health
```

Check the VPN SOCKS independently:

```bash
curl -4 https://api.ipify.org
echo
curl --socks5-hostname 127.0.0.1:1080 https://api.ipify.org
echo
```

The two public IP addresses should differ when AmneziaWG is active.

## Configure Prowlarr

In Prowlarr open:

```text
Settings -> Indexers -> Indexer Proxies -> + -> FlareSolverr
```

Use:

```text
Name: Byparr
Host: http://127.0.0.1:8191
Request Timeout: 60 seconds
Tags: cloudflare
```

Add the same `cloudflare` tag to RuTracker (and only to other indexers that actually need the solver).

If RuTracker also has a separate SOCKS5 indexer-proxy tag from the old setup, remove that SOCKS5 proxy tag from RuTracker after Byparr is enabled. Byparr itself already routes the browser through the Amnezia SOCKS proxy; stacking both Prowlarr SOCKS and FlareSolverr proxies can make troubleshooting ambiguous.

## Logs

```bash
journalctl -u podman-byparr -n 200 --no-pager
journalctl -u media-vpn-proxy -n 100 --no-pager
journalctl -u prowlarr -n 200 --no-pager
```

A Cloudflare challenge is not guaranteed to be solvable indefinitely; Cloudflare protections change over time. The service is pinned to a stable Byparr release so upgrades are deliberate.
