# AdGuard Home DNS filtering

AdGuard Home is the DNS resolver for LAN clients. It listens on TCP/UDP port 53 and blocks unwanted domains before forwarding allowed queries upstream.

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
- EDNS Client Subnet disabled for better privacy;
- a 16 MiB DNS cache;
- seven days of query-log retention and 30 days of statistics.

The `.home` zone never goes to an external resolver. AdGuard Home forwards it to the local dnsmasq instance on `127.0.0.1:5353`.

## Authentication

The admin UI has an AdGuard Home user named:

```text
sergey
```

Only a BCrypt password hash is stored in the public Git repository. Keep the plaintext password outside Git.

If the password ever needs to be changed, generate a new BCrypt hash locally and replace only `services.adguardhome.settings.users[0].password` in `adguard.nix`.

For example on NixOS:

```bash
nix shell nixpkgs#apacheHttpd -c htpasswd -bnBC 12 sergey 'NEW-STRONG-PASSWORD'
```

Copy only the part after `sergey:` into `adguard.nix`.

## Router configuration

The TP-Link Archer AX73 should advertise the NixOS server as DNS to DHCP clients:

```text
Advanced -> Network -> DHCP Server
Primary DNS   = <NixOS server LAN IPv4>
Secondary DNS = empty
```

Reserve the NixOS server's LAN address in the router so the DNS address does not change.

Do not configure a public Secondary DNS, because clients are free to use it and bypass AdGuard filtering.

If IPv6 is enabled, also ensure the router is not advertising an unrelated IPv6 DNS resolver. Either advertise the NixOS DNS service over IPv6 as well or disable IPv6 DNS distribution until that path is configured.

## Verify services

```bash
systemctl status adguardhome dnsmasq caddy --no-pager
ss -lntup | grep -E ':(53|80|3000|5353)\b'
```

Expected layout:

```text
:53                 AdGuard Home, LAN DNS
127.0.0.1:5353      dnsmasq, .home only
127.0.0.1:3000      AdGuard Home Web UI
:80                 Caddy
```

Test local and external DNS separately:

```bash
dig @127.0.0.1 -p 5353 adguard.home
dig @127.0.0.1 adguard.home
dig @127.0.0.1 example.com
```

Open `http://adguard.home` and use Query Log to confirm that LAN devices are sending DNS requests through the server and that blocked requests are being filtered.

## Important limitations

DNS filtering blocks domains, not individual HTTPS resources. It therefore cannot reliably remove advertisements served from the same domains as desired content, such as many YouTube ads.

A client can also bypass network DNS filtering if it uses its own DNS-over-HTTPS, Private DNS, VPN, or another manually configured resolver. Preventing deliberate bypass requires additional router/firewall policy and is separate from AdGuard Home itself.
