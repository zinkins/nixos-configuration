# Local reverse proxy and DNS

The server provides friendly LAN URLs through Caddy:

- `http://prowlarr.home`
- `http://qbittorrent.home`
- `http://jellyfin.home`
- `http://adguard.home`

`nixos.home` is also published in local DNS as the server name, but it is not a Caddy application endpoint.

This setup uses plain HTTP on the LAN to avoid local certificate installation on every client and compatibility problems with older devices.

## DNS architecture

AdGuard Home is the only DNS server exposed to LAN clients on TCP/UDP port 53. It provides filtering, logging and upstream DNS.

The `.home` zone stays local:

```text
LAN client
   |
   | DNS :53
   v
AdGuard Home
   |-- *.home --------> dnsmasq 127.0.0.1:5353
   |                     |-- nixos.home
   |                     |-- prowlarr.home
   |                     |-- qbittorrent.home
   |                     |-- jellyfin.home
   |                     `-- adguard.home
   |
   `-- other domains --> encrypted Quad9 DNS-over-TLS
```

The LAN IPv4 address is not hard-coded in Git. At service start, dnsmasq detects the interface carrying the IPv4 default route and uses that interface address for the local names.

## Router/client setting

For other devices to use filtering and resolve `*.home`, configure the router's DHCP server to hand out the NixOS server's LAN IPv4 address as the DNS server.

Keep the NixOS server on a DHCP reservation/static lease so its address remains stable.

On TP-Link Archer AX73 this is configured under:

```text
Advanced -> Network -> DHCP Server
Primary DNS   = <NixOS server LAN IPv4>
Secondary DNS = leave empty
```

Do not set a public resolver such as `8.8.8.8` or `1.1.1.1` as Secondary DNS, because clients may bypass AdGuard Home.

If IPv6 is enabled on the router, make sure it does not advertise a different public IPv6 DNS resolver to clients; otherwise some devices can bypass the IPv4 AdGuard DNS path.

## Verify DNS

On the NixOS server:

```bash
dig @127.0.0.1 -p 5353 prowlarr.home
dig @127.0.0.1 prowlarr.home
dig @127.0.0.1 example.com
```

The first command tests local dnsmasq directly. The second goes through AdGuard Home and should return the same LAN address. The third verifies normal upstream DNS.

From a LAN client after it receives the NixOS server as DNS:

```bash
nslookup prowlarr.home
nslookup qbittorrent.home
nslookup jellyfin.home
nslookup adguard.home
```

All should resolve to the NixOS server's LAN address.

## Verify Caddy

```bash
systemctl status caddy adguardhome dnsmasq --no-pager
```

Test virtual hosts directly on the server:

```bash
curl -I -H 'Host: prowlarr.home' http://127.0.0.1/
curl -I -H 'Host: qbittorrent.home' http://127.0.0.1/
curl -I -H 'Host: jellyfin.home' http://127.0.0.1/
curl -I -H 'Host: adguard.home' http://127.0.0.1/
```

## Firewall behavior

- Caddy: TCP `80` open to LAN.
- AdGuard Home DNS: TCP/UDP `53` open to LAN.
- AdGuard Home Web UI: `127.0.0.1:3000` only, reached through Caddy.
- dnsmasq: `127.0.0.1:5353` only, used by AdGuard Home for `.home`.
- Prowlarr `9696`: no direct firewall opening.
- qBittorrent Web UI `8080`: no direct firewall opening.
- qBittorrent peer port `49160`: remains open over TCP/UDP.
- Jellyfin keeps its normal direct access required by DLNA clients.

## Troubleshooting

```bash
journalctl -u adguardhome -b --no-pager
journalctl -u dnsmasq -b --no-pager
journalctl -u caddy -b --no-pager
cat /run/dnsmasq-home.conf
ss -lntup | grep -E ':(53|80|3000|5353)\b'
```

The generated local DNS file should look similar to:

```text
interface-name=nixos.home,wlan0/4
interface-name=prowlarr.home,wlan0/4
interface-name=qbittorrent.home,wlan0/4
interface-name=jellyfin.home,wlan0/4
interface-name=adguard.home,wlan0/4
```

The actual interface name may be different.
