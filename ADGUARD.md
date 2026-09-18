# AdGuard Home DNS filtering

AdGuard Home is the DNS resolver for LAN clients. It listens on TCP/UDP port 53, applies network-wide filtering, and forwards allowed public queries to encrypted upstream DNS.

Admin UI:

```text
http://adguard.home
```

The underlying AdGuard Home HTTP port `3000` listens only on `127.0.0.1`; Caddy is the LAN-facing entry point.

## Protection enabled by default

The NixOS configuration enables:

- DNS filtering and protection;
- AdGuard Safe Browsing;
- AdGuard Parental Control;
- Safe Search for Google, Bing, DuckDuckGo, Yandex, YouTube and Pixabay;
- HaGeZi Multi PRO for ads, trackers and telemetry;
- HaGeZi TIF Mini for malware, phishing and other threat-intelligence domains;
- HaGeZi NSFW for adult domains;
- Quad9 over DNS-over-TLS as the external upstream resolver;
- EDNS Client Subnet disabled;
- a 16 MiB DNS cache;
- seven days of query-log retention and 30 days of statistics.

The `.home` zone never goes to a public resolver. AdGuard Home forwards it to the local dnsmasq instance on `127.0.0.1:5353`.

## Authentication

The admin UI user is:

```text
sergey
```

Only the BCrypt password hash is stored in Git. Keep the plaintext password outside the repository.

To change it, generate a new BCrypt hash and replace `services.adguardhome.settings.users[0].password` in `adguard.nix`:

```bash
nix shell nixpkgs#apacheHttpd -c htpasswd -bnBC 12 sergey 'NEW-STRONG-PASSWORD'
```

Copy only the part after `sergey:`.

## Router configuration

The TP-Link Archer AX73 should advertise the NixOS server as DNS through DHCP:

```text
Advanced -> Network -> DHCP Server
Primary DNS   = <NixOS server LAN IPv4>
Secondary DNS = empty
```

Reserve the server's LAN address in the router so it does not change.

Do not configure a public Secondary DNS. Clients may use it instead of AdGuard and then `.home` names and filtering become unreliable.

After changing DHCP DNS, renew the client's lease or reconnect it to the network.

On Windows verify the active adapter:

```powershell
ipconfig /all
nslookup adguard.home
```

The DNS server shown by Windows should be the NixOS server.

## Browser Secure DNS / DoH

Browsers can bypass the operating-system DNS configuration. If Chrome, Edge, Firefox, or another browser is configured to use Cloudflare, OpenDNS, Google, or another explicit DNS-over-HTTPS provider, public names may work while `*.home` fails in the browser.

For LAN names and AdGuard filtering to work consistently, disable the browser's explicit Secure DNS provider or configure it to use the system/current provider.

The same applies to operating-system features such as Android Private DNS and manually configured DoH on Windows.

## Clients running a VPN

A client-side VPN can also prevent access to the LAN DNS server even when DHCP is correct. The VPN must allow the local LAN subnet and the NixOS DNS address outside the tunnel.

For the current home network this means allowing the LAN route, for example:

```text
192.168.1.0/24
```

If the VPN has a DNS kill switch, add the NixOS DNS server address as a DNS exception as well. Use the server's actual reserved LAN address rather than a public DNS server.

A useful Windows test while the VPN is enabled is:

```powershell
Test-NetConnection <SERVER_IP> -Port 53
nslookup adguard.home <SERVER_IP>
```

If those fail with the VPN enabled but work when it is disabled, the problem is client-side VPN routing/kill-switch policy rather than AdGuard Home.

## IPv6

If IPv6 is enabled, ensure the router is not advertising an unrelated IPv6 DNS resolver that bypasses AdGuard. Either distribute the NixOS resolver over IPv6 as well or stop advertising another IPv6 DNS service until that path is intentionally configured.

## Verify services on the server

```bash
systemctl status adguardhome dnsmasq caddy --no-pager
ss -lntup | grep -E ':(53|80|3000|5353)\b'
```

Expected layout:

```text
0.0.0.0:53          AdGuard Home, LAN DNS
127.0.0.1:5353      dnsmasq, authoritative .home helper
127.0.0.1:3000      AdGuard Home Web UI
0.0.0.0:80          Caddy LAN HTTP entry point
```

Test local and public DNS separately:

```bash
dig @127.0.0.1 -p 5353 adguard.home
dig @127.0.0.1 adguard.home
dig @127.0.0.1 example.com
```

From another LAN client, explicitly query the server to separate DNS-server reachability from DHCP configuration:

```text
nslookup adguard.home <SERVER_IP>
```

Open `http://adguard.home` and use **Query Log** to confirm that LAN clients are actually sending their DNS traffic through AdGuard Home.

## Important limitations

DNS filtering blocks domains, not individual HTTPS resources. It cannot reliably remove advertisements served from the same domains as desired content, such as many YouTube ads.

Any client that deliberately uses its own DoH/Private DNS/VPN resolver can bypass network DNS filtering unless router/firewall policy explicitly prevents that bypass.
