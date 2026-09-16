# Local reverse proxy and DNS

The server provides friendly LAN URLs through Caddy:

- `http://prowlarr.home.arpa`
- `http://qbittorrent.home.arpa`
- `http://jellyfin.home.arpa`

The `.home.arpa` suffix is intended for private home networks. This setup uses plain HTTP on the LAN to avoid local certificate installation on every client and compatibility problems with older devices.

`nixos.home.arpa` is also published in local DNS as the server name, but it is not a Caddy application endpoint.

## How name resolution works

`dnsmasq` runs on the NixOS server and answers the local `*.home.arpa` names with the server's current IPv4 address. The address is not hard-coded: at service start the configuration detects the interface carrying the IPv4 default route and creates DNS records from that interface address.

DNS is exposed on TCP/UDP port 53 only to hosts on directly connected networks (`local-service=net`). Unknown `home.arpa` names are kept local and are not forwarded to public DNS.

The NixOS server itself continues using its existing resolver; enabling this DNS service does not rewrite the server's own DNS configuration.

## One required router/client setting

For other devices to resolve `*.home.arpa`, they need to use the NixOS server as a DNS resolver.

The preferred setup is to configure the router's DHCP settings so that the DNS server handed to LAN clients is the LAN IPv4 address of this NixOS machine. Keep the server on a DHCP reservation/static lease so that clients always know where the DNS server is.

If the router cannot advertise a custom DNS server, configure the NixOS server address as DNS manually on the devices where these names are needed.

You can see the server's current LAN address and default interface with:

```bash
ip -4 route show default
ip -4 addr
```

## Verify DNS

From a LAN client which uses this server for DNS:

```bash
nslookup prowlarr.home.arpa
nslookup qbittorrent.home.arpa
nslookup jellyfin.home.arpa
```

All three should resolve to the NixOS server's LAN address.

From the NixOS server you can query dnsmasq explicitly even if the server itself uses another resolver:

```bash
dig @127.0.0.1 prowlarr.home.arpa
dig @127.0.0.1 qbittorrent.home.arpa
dig @127.0.0.1 jellyfin.home.arpa
```

The configuration installs the DNS utilities package so `dig` and `nslookup` are available after activation.

## Verify Caddy

Check services:

```bash
systemctl status caddy dnsmasq --no-pager
```

Test the virtual hosts directly on the server:

```bash
curl -I -H 'Host: prowlarr.home.arpa' http://127.0.0.1/
curl -I -H 'Host: qbittorrent.home.arpa' http://127.0.0.1/
curl -I -H 'Host: jellyfin.home.arpa' http://127.0.0.1/
```

Caddy listens on TCP port 80.

## Firewall behavior

- Prowlarr port `9696` is no longer opened in the firewall.
- qBittorrent Web UI port `8080` is no longer opened in the firewall.
- qBittorrent peer port `49160` remains open over TCP and UDP.
- Jellyfin keeps its normal firewall opening because DLNA devices need to fetch media from Jellyfin directly.
- DNS port `53` (TCP/UDP) and Caddy HTTP port `80` are open for the LAN.

The applications still listen on their normal local ports, so Caddy can reach them over loopback.

## Troubleshooting

If DNS does not start:

```bash
journalctl -u dnsmasq -b --no-pager
cat /run/dnsmasq-home-arpa.conf
ip -4 route show default
```

The runtime file should look similar to:

```text
interface-name=nixos.home.arpa,wlan0/4
interface-name=prowlarr.home.arpa,wlan0/4
interface-name=qbittorrent.home.arpa,wlan0/4
interface-name=jellyfin.home.arpa,wlan0/4
```

The actual interface name may be different.

If a hostname resolves but the page does not open:

```bash
journalctl -u caddy -b --no-pager
curl -v -H 'Host: prowlarr.home.arpa' http://127.0.0.1/
```
