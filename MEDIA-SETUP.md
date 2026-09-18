# Media stack: setup and network architecture

The NixOS media stack contains:

- Prowlarr for indexer management and manual search;
- qBittorrent for downloads to `/myraid1/nas/films`;
- Jellyfin for the media library and DLNA;
- `media-vpn-proxy`, a localhost SOCKS5 proxy on `127.0.0.1:1080` whose outbound connections are forced through AmneziaWG;
- Byparr on `127.0.0.1:8191` for Cloudflare-protected indexers.

The host default route is intentionally left unchanged. qBittorrent peer traffic therefore stays on the normal Internet connection. Only traffic explicitly sent to the SOCKS proxy uses AmneziaWG.

## 1. Apply and verify the configuration

```bash
sudo nixos-rebuild switch --flake /etc/nixos#nixos
```

Check the media services:

```bash
systemctl --no-pager --full status \
  amneziawg media-vpn-proxy podman-byparr prowlarr qbittorrent jellyfin
```

The LAN-facing browser URLs are provided by Caddy:

```text
http://prowlarr.home
http://qbittorrent.home
http://jellyfin.home
```

Prowlarr port `9696` and qBittorrent Web UI port `8080` are intentionally not opened directly to the LAN.

## 2. Verify split VPN routing

Compare the normal public address with the SOCKS path:

```bash
curl -4 https://api.ipify.org
echo
curl -4 --socks5-hostname 127.0.0.1:1080 https://api.ipify.org
echo
```

The addresses should differ. The second address should be the Amnezia VPN exit address.

If `media-vpn-proxy` does not start, inspect:

```bash
journalctl -u amneziawg -u media-vpn-proxy -b --no-pager
ip -4 addr show dev awg0
ip -4 rule
ip -4 route show table 51820
```

## 3. qBittorrent

Open:

```text
http://qbittorrent.home
```

The initial configuration sets the save path to:

```text
/myraid1/nas/films
```

qBittorrent may generate a temporary Web UI password on first start. If needed:

```bash
journalctl -u qbittorrent -b --no-pager | grep -i password
```

Do not enable a global qBittorrent proxy unless you specifically want torrent traffic to use the VPN. The intended default is:

```text
qBittorrent peer / DHT / uTP traffic -> normal ISP route
```

The peer listen port remains `49160` over TCP/UDP.

## 4. Prowlarr, Amnezia VPN and RuTracker

Open:

```text
http://prowlarr.home
```

### VPN proxy

In `Settings -> Indexers -> Indexer Proxies`, add SOCKS5:

```text
Name: Amnezia VPN
Host: 127.0.0.1
Port: 1080
Tags: vpn
```

Torrent indexers that should be reached only through AmneziaWG should receive the `vpn` tag.

### Cloudflare solver

For RuTracker and other Cloudflare-protected indexers, also add a `FlareSolverr` indexer proxy pointing to Byparr:

```text
Name: Byparr
Host: http://127.0.0.1:8191
Request Timeout: 60 seconds
Tags: cloudflare
```

RuTracker should have both tags:

```text
vpn
cloudflare
```

This causes Prowlarr's normal RuTracker HTTP traffic to use the SOCKS5 VPN proxy while Cloudflare challenge handling uses Byparr. Byparr itself is also configured to use the same SOCKS5 endpoint, so both paths leave through the same AmneziaWG exit IP.

See `BYPARR.md` for detailed verification and troubleshooting.

Enter the RuTracker username/password only in the Prowlarr UI. Do not commit credentials to this repository.

### qBittorrent download client

In `Settings -> Download Clients`, add qBittorrent using the local connection:

```text
Host: 127.0.0.1
Port: 8080
```

The Prowlarr-to-qBittorrent connection is local and does not involve the VPN.

## 5. Jellyfin and DLNA

Open:

```text
http://jellyfin.home
```

Complete the initial Jellyfin wizard and add a media library using:

```text
/myraid1/nas/films
```

A single mixed directory works, although metadata recognition is usually more reliable with separate movie and TV libraries.

DLNA is an official Jellyfin plugin rather than part of the server core. Install **DLNA** once from:

```text
Dashboard -> Plugins -> Catalog
```

Then restart Jellyfin:

```bash
sudo systemctl restart jellyfin
```

Jellyfin retains its normal firewall openings because DLNA clients such as the LG TV need direct media access; browser access can still use Caddy at `jellyfin.home`.

Playback resume over DLNA depends partly on what the TV reports back to Jellyfin, so an older LG client may not preserve progress reliably.

## 6. Useful local endpoints

```text
Prowlarr LAN URL:       http://prowlarr.home
qBittorrent LAN URL:   http://qbittorrent.home
Jellyfin LAN URL:      http://jellyfin.home
VPN SOCKS5:            127.0.0.1:1080
Byparr API:             127.0.0.1:8191
qBittorrent local API: 127.0.0.1:8080
Downloads:             /myraid1/nas/films
```

Ports `1080`, `8191`, `9696`, and `8080` are not intended as direct LAN-facing service endpoints. Use the `.home` Caddy URLs for browser access.
