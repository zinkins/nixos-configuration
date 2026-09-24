# Local reverse proxy and DNS

The server provides friendly LAN URLs through Caddy:

- `http://family.home` — Homepage dashboard
- `http://prowlarr.home`
- `http://qbittorrent.home`
- `http://jellyfin.home`
- `http://adguard.home`

`nixos.home` is also published in local DNS as the server name.

The electronic diary tile on `family.home` shows a locally saved timetable and homework. Clicking it opens `https://school.nso.ru/journal-app/`. See `SCHOOL-DIARY.md` for one-click updates from Yandex Browser and the data stored on the server.

Use the explicit `http://` scheme. This LAN setup intentionally does not enable HTTPS, avoiding local CA/certificate installation and compatibility problems with older devices.

## DNS architecture

```text
LAN client
   |
   | DNS TCP/UDP 53
   v
AdGuard Home
   |
   +-- *.home --> dnsmasq 127.0.0.1:5353 --> server LAN IPv4
   |
   +-- public DNS --> Quad9 over DNS-over-TLS
```

AdGuard Home is the only DNS endpoint exposed to LAN clients. `dnsmasq` is loopback-only and exists solely for the private `.home` zone.

The `.home` records are generated from the IPv4 interface carrying the server's default route, so the LAN IP is not hard-coded in Git.

Unknown `.home` names remain local and are not sent to public DNS.

See `ADGUARD.md` for filtering, DHCP, browser DoH, IPv6, and client-side VPN troubleshooting.

## Router/client requirement

LAN clients must actually use the NixOS server as their DNS resolver. On the TP-Link Archer AX73 configure DHCP to hand out the server LAN IPv4 as Primary DNS and leave Secondary DNS empty.

Keep the server on a DHCP reservation/static lease.

After changing DHCP DNS, renew the client's lease or reconnect it. Verify the DNS address on the client rather than assuming the router change was applied.

A browser with an explicitly configured Secure DNS/DoH provider can bypass system DNS and fail to resolve `.home` even when `nslookup` works. A client VPN may also block access to the LAN or DNS port 53; see `ADGUARD.md`.

## Verify DNS

From a LAN client:

```text
nslookup prowlarr.home
nslookup qbittorrent.home
nslookup jellyfin.home
nslookup adguard.home
```

All names should resolve to the NixOS server's LAN IPv4.

To bypass DHCP/client resolver selection and query the NixOS server explicitly:

```text
nslookup adguard.home <SERVER_IP>
```

From the NixOS server:

```bash
dig @127.0.0.1 prowlarr.home
dig @127.0.0.1 example.com
dig @127.0.0.1 -p 5353 prowlarr.home
```

## Verify Caddy

```bash
systemctl status caddy adguardhome dnsmasq --no-pager
```

Test the virtual hosts locally:

```bash
curl -I -H 'Host: prowlarr.home' http://127.0.0.1/
curl -I -H 'Host: qbittorrent.home' http://127.0.0.1/
curl -I -H 'Host: jellyfin.home' http://127.0.0.1/
curl -I -H 'Host: adguard.home' http://127.0.0.1/
```

Caddy listens on TCP port 80.

## Firewall / exposure

```text
53 TCP/UDP   AdGuard Home DNS       LAN-facing
80 TCP       Caddy                  LAN-facing
49160 TCP/UDP qBittorrent peers    Internet/LAN as required for torrenting
5353         dnsmasq                loopback only
3000         AdGuard Home UI        loopback only
1080         media VPN SOCKS5       loopback only
8191         Byparr API             loopback only
9696         Prowlarr Web UI        not directly opened to LAN
8080         qBittorrent Web UI     not directly opened to LAN
8084         School diary cache     loopback only
```

Jellyfin keeps its own NixOS firewall openings because DLNA clients need direct service discovery/media access. Browser access should still use `http://jellyfin.home`.

## Media VPN and Byparr

The reverse proxy is independent from outbound media routing.

Our upstream ISP blocks direct connections to `api.open-meteo.com`'s IP (`94.130.142.35`, Hetzner), which the Open-Meteo weather widget needs. Homepage's own HTTP client for that widget is a raw `https.Agent` request with no proxy support at all — not `HTTPS_PROXY`, not `NODE_USE_ENV_PROXY` (that only affects the global `fetch()`, which this widget doesn't use). So routing it through the loopback SOCKS5 VPN proxy has to happen below the application: `networking.firewall.extraCommands` transparently redirects any locally-generated connection to `94.130.142.35:443` into `homepage-redsocks` (a `redsocks` instance), which relays it over the SOCKS5 proxy on `127.0.0.1:1080` — homepage never knows a proxy exists. The redirect is scoped to that one destination IP:port, so nothing else on the host is affected. The "Прогноз на сегодня" customapi card (today's hourly/daily forecast, since the built-in widget only shows current conditions) calls the same host and goes through the same redirect. If weather shows an API error, check `media-vpn-proxy` and `homepage-redsocks` are running, and test the full path with `curl -I --socks5-hostname 127.0.0.1:1080 https://api.open-meteo.com/` on the server. A response from the API, including HTTP 400 for its bare root URL, confirms connectivity.

Prowlarr can send selected indexer requests through the localhost SOCKS5 service `127.0.0.1:1080`, which exits through AmneziaWG. Cloudflare-protected indexers can additionally use Byparr at `127.0.0.1:8191`; Byparr's browser is itself forced through the same SOCKS5 endpoint.

See `MEDIA-SETUP.md` and `BYPARR.md`.

## AI CLI traffic

Codex and Claude Code use a separate fail-closed network namespace whose only Internet egress is AmneziaWG `awg0`. This is independent of Caddy, AdGuard and the media SOCKS proxy. See `AI-VPN.md`.

## Troubleshooting

If local DNS does not start:

```bash
journalctl -u adguardhome -u dnsmasq -b --no-pager
cat /run/dnsmasq-home.conf
ip -4 route show default
```

The runtime file should look similar to:

```text
interface-name=nixos.home,<LAN_INTERFACE>/4
interface-name=prowlarr.home,<LAN_INTERFACE>/4
interface-name=qbittorrent.home,<LAN_INTERFACE>/4
interface-name=jellyfin.home,<LAN_INTERFACE>/4
interface-name=adguard.home,<LAN_INTERFACE>/4
```

If a hostname resolves but the page does not open, test TCP 80 and Caddy separately:

```bash
journalctl -u caddy -b --no-pager
curl -v -H 'Host: prowlarr.home' http://127.0.0.1/
```

From Windows:

```powershell
Test-NetConnection <SERVER_IP> -Port 80
```
