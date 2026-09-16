# Local reverse proxy and DNS

The server provides friendly LAN URLs through Caddy:

- `http://prowlarr.home`
- `http://qbittorrent.home`
- `http://jellyfin.home`
- `http://adguard.home`

`nixos.home` is also published in local DNS as the server name.

This setup uses plain HTTP on the LAN to avoid local certificate installation on every client and compatibility problems with older devices.

## DNS architecture

AdGuard Home is the DNS endpoint exposed to LAN clients on TCP/UDP port 53. It performs network-wide filtering and forwards the private `.home` zone to dnsmasq on `127.0.0.1:5353`.

`dnsmasq` answers the local names with the server's current IPv4 address. The address is not hard-coded: at service start the configuration detects the interface carrying the IPv4 default route and creates DNS records from that interface address.

Unknown `.home` names are kept local and are not forwarded to public DNS. Normal Internet DNS requests are handled by AdGuard Home and sent to encrypted upstream DNS.

See `ADGUARD.md` for filtering details and router setup.

## One required router/client setting

For other devices to resolve `*.home` and use network-wide filtering, they need to use the NixOS server as their DNS resolver.

The preferred setup is to configure the router's DHCP settings so that the Primary DNS handed to LAN clients is the LAN IPv4 address of this NixOS machine. Keep the server on a DHCP reservation/static lease. Leave Secondary DNS empty so clients do not bypass AdGuard Home.

You can see the server's current LAN address and default interface with:

```bash
ip -4 route show default
ip -4 addr
```

## Verify DNS

From a LAN client which uses this server for DNS:

```bash
nslookup prowlarr.home
nslookup qbittorrent.home
nslookup jellyfin.home
nslookup adguard.home
```

All names should resolve to the NixOS server's LAN address.

From the NixOS server:

```bash
dig @127.0.0.1 prowlarr.home
dig @127.0.0.1 google.com
```

To query the local dnsmasq zone directly:

```bash
dig @127.0.0.1 -p 5353 prowlarr.home
```

## Verify Caddy

Check services:

```bash
systemctl status caddy adguardhome dnsmasq --no-pager
```

Test the virtual hosts directly on the server:

```bash
curl -I -H 'Host: prowlarr.home' http://127.0.0.1/
curl -I -H 'Host: qbittorrent.home' http://127.0.0.1/
curl -I -H 'Host: jellyfin.home' http://127.0.0.1/
curl -I -H 'Host: adguard.home' http://127.0.0.1/
```

Caddy listens on TCP port 80.

## Firewall behavior

- Prowlarr port `9696` is not opened directly in the firewall.
- qBittorrent Web UI port `8080` is not opened directly in the firewall.
- AdGuard Home Web UI port `3000` is bound to loopback only.
- qBittorrent peer port `49160` remains open over TCP and UDP.
- Jellyfin keeps its normal firewall opening because DLNA devices need to fetch media from Jellyfin directly.
- AdGuard Home DNS port `53` is open over TCP/UDP.
- Caddy HTTP port `80` is open for the LAN.
- dnsmasq port `5353` is loopback-only and is not exposed to the LAN.

## AI CLI traffic

Codex and Claude Code use a separate fail-closed network namespace whose only Internet egress is the AmneziaWG `awg0` tunnel. This is independent from the LAN reverse-proxy/DNS setup. See `AI-VPN.md` for details and verification commands.

## Troubleshooting

If local DNS does not start:

```bash
journalctl -u adguardhome -u dnsmasq -b --no-pager
cat /run/dnsmasq-home.conf
ip -4 route show default
```

The runtime file should look similar to:

```text
interface-name=nixos.home,wlan0/4
interface-name=prowlarr.home,wlan0/4
interface-name=qbittorrent.home,wlan0/4
interface-name=jellyfin.home,wlan0/4
interface-name=adguard.home,wlan0/4
```

The actual interface name may be different.

If a hostname resolves but the page does not open:

```bash
journalctl -u caddy -b --no-pager
curl -v -H 'Host: prowlarr.home' http://127.0.0.1/
```
