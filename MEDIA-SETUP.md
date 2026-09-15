# Media stack: first-run setup

The NixOS configuration installs:

- Prowlarr for manual torrent/indexer search;
- qBittorrent-nox for downloads to `/myraid1/nas/films`;
- Jellyfin for the media library and DLNA;
- a local SOCKS5 proxy on `127.0.0.1:1080` whose outgoing traffic is forced through AmneziaWG.

The host default route is intentionally left unchanged. qBittorrent peer traffic therefore uses the normal Internet connection unless a proxy is explicitly enabled in qBittorrent.

## 1. Apply the configuration

```bash
sudo nixos-rebuild switch --flake .#nixos
```

Check the services:

```bash
systemctl --no-pager --full status amneziawg media-vpn-proxy prowlarr qbittorrent jellyfin
```

## 2. Verify split VPN routing

Compare the public address of the normal connection and the SOCKS proxy:

```bash
curl -4 https://ifconfig.me
curl -4 --socks5-hostname 127.0.0.1:1080 https://ifconfig.me
```

The two addresses should be different. The second one should be the VPN address.

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
http://SERVER_IP:8080
```

The initial configuration already sets the save path to:

```text
/myraid1/nas/films
```

qBittorrent may generate a temporary Web UI password on first start. If needed, find it with:

```bash
journalctl -u qbittorrent -b --no-pager | grep -i password
```

Then set a permanent Web UI password.

Do not configure a qBittorrent proxy initially. This keeps peer/video traffic on the normal Internet connection.

If tracker announce requests are blocked later, set qBittorrent's proxy to SOCKS5 `127.0.0.1:1080`, but keep **Use proxy for peer connections** disabled. That allows tracker/Web requests to use the VPN without sending the downloaded video payload through it.

## 4. Prowlarr and RuTracker

Open:

```text
http://SERVER_IP:9696
```

In **Settings -> Indexers -> Indexer Proxies**, add a SOCKS5 proxy:

```text
Host: 127.0.0.1
Port: 1080
Tag: vpn
```

Add RuTracker as an indexer, enter the RuTracker username/password in the Prowlarr UI, and give the indexer the `vpn` tag. Credentials must not be committed to this public repository.

In **Settings -> Download Clients**, add qBittorrent:

```text
Host: 127.0.0.1
Port: 8080
```

The local qBittorrent connection is configured to allow localhost without authentication. If you later enable authentication for localhost too, enter the qBittorrent credentials in Prowlarr.

You can then use Prowlarr's manual search, including Cyrillic/Russian queries, and send the selected release directly to qBittorrent.

## 5. Jellyfin and DLNA

Open:

```text
http://SERVER_IP:8096
```

Complete the initial Jellyfin wizard and add a media library using:

```text
/myraid1/nas/films
```

A single mixed directory is supported, but metadata recognition is less reliable than separate movie/TV libraries. This configuration deliberately keeps one directory as requested.

DLNA is an official Jellyfin plugin rather than part of the server core. Install **DLNA** once from:

**Dashboard -> Plugins -> Catalog**

Then restart Jellyfin:

```bash
sudo systemctl restart jellyfin
```

The LG TV should then discover the Jellyfin DLNA server on the local network.

Playback progress is stored by Jellyfin when the DLNA client reports it correctly. Whether resume works reliably therefore also depends on the DLNA implementation in the 2014 LG TV; test it with one file before relying on it.

## 6. Useful addresses

- Prowlarr: `http://SERVER_IP:9696`
- qBittorrent: `http://SERVER_IP:8080`
- Jellyfin: `http://SERVER_IP:8096`
- VPN-only SOCKS5 proxy: `127.0.0.1:1080`
- Downloads: `/myraid1/nas/films`
