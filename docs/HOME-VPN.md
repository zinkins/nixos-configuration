# Home access through the VPS

This document describes the site-to-site tunnel used to reach the home NixOS
server from clients already connected to the VPS through AmneziaWG 2.0.

The home tunnel is deliberately separate from the existing AmneziaWG tunnel on
the NixOS host. It uses standard WireGuard and does not replace the host's normal
default route.

## Architecture

```text
remote client
  |
  | existing AmneziaWG 2.0 profile
  v
AmneziaWG2 container on VPS
  |
  | Docker bridge / NAT
  v
VPS host
  |
  | wg-home (standard WireGuard)
  v
home NixOS server
  |
  +-- Caddy -> family.home / jellyfin.home / qbittorrent.home / ...
```

The intended exposure is narrow: remote Amnezia clients reach the home Caddy
entry point over the WireGuard tunnel instead of receiving a route to the whole
home LAN.

The NixOS side is defined in [`../nix/home-vpn.nix`](../nix/home-vpn.nix).
Keep every private key outside Git.

## Values used below

Determine the real values before applying the examples:

```text
<VPS_PUBLIC_IP>       public IPv4/IPv6 address of the VPS
<WG_PORT>             UDP listen port for wg-home
<VPS_WG_IP>           wg-home address on the VPS
<HOME_WG_IP>          wg-home address on NixOS
<VPS_PUBLIC_KEY>      WireGuard public key of the VPS
<HOME_PUBLIC_KEY>     WireGuard public key of the NixOS host
<AMNEZIA_BRIDGE_IF>   Docker bridge on the VPS, for example amn0
<AMNEZIA_BRIDGE_IP>   VPS-side IP on that bridge
<AWG2_DOCKER_IP>      IP of the active AmneziaWG2 container on that bridge
```

Inspect the Amnezia Docker network on the VPS with:

```bash
sudo docker network inspect amnezia-dns-net
sudo docker ps --format 'table {{.Names}}\t{{.Image}}\t{{.Networks}}'
ip -br addr
```

Inspect the current NixOS tunnel parameters in:

```text
nix/home-vpn.nix
```

## 1. Generate the VPS WireGuard key

On a Debian/Ubuntu VPS:

```bash
sudo apt update
sudo apt install -y wireguard-tools
sudo install -d -m 700 /etc/wireguard

sudo sh -c '
  umask 077
  wg genkey > /etc/wireguard/wg-home.key
  wg pubkey < /etc/wireguard/wg-home.key > /etc/wireguard/wg-home.pub
'
```

Show only the public key when it is needed elsewhere:

```bash
sudo cat /etc/wireguard/wg-home.pub
```

Never commit `/etc/wireguard/wg-home.key`.

## 2. Prepare the NixOS key

The NixOS module uses `/etc/wireguard/wg-home.key` and is configured to create
that file when it does not exist. For a first installation it is also safe to
create the key explicitly before activation:

```bash
sudo install -d -m 700 /etc/wireguard

sudo sh -c '
  umask 077
  nix shell nixpkgs#wireguard-tools -c wg genkey > /etc/wireguard/wg-home.key
  nix shell nixpkgs#wireguard-tools -c wg pubkey \
    < /etc/wireguard/wg-home.key \
    > /etc/wireguard/wg-home.pub
'
```

Show the NixOS public key:

```bash
sudo cat /etc/wireguard/wg-home.pub
```

If the module already generated the key, derive the public key directly:

```bash
sudo sh -c 'wg pubkey < /etc/wireguard/wg-home.key'
```

## 3. Configure WireGuard on the VPS

Create `/etc/wireguard/wg-home.conf`:

```ini
[Interface]
Address = <VPS_WG_IP>/30
ListenPort = <WG_PORT>
PrivateKey = <VPS_PRIVATE_KEY>

[Peer]
PublicKey = <HOME_PUBLIC_KEY>
AllowedIPs = <HOME_WG_IP>/32
```

Protect it:

```bash
sudo chmod 600 /etc/wireguard/wg-home.conf
```

Enable IPv4 forwarding permanently:

```bash
echo 'net.ipv4.ip_forward=1' | sudo tee /etc/sysctl.d/90-home-vpn.conf
sudo sysctl --system
```

Open the WireGuard UDP port with UFW:

```bash
sudo ufw allow <WG_PORT>/udp
```

Start the tunnel:

```bash
sudo systemctl enable --now wg-quick@wg-home
```

Verify:

```bash
sudo wg show wg-home
ip -br addr show wg-home
ip route
```

## 4. Configure the NixOS peer

`nix/home-vpn.nix` is the source of truth for the home side. It must contain:

- the home tunnel address;
- `privateKeyFile = "/etc/wireguard/wg-home.key"`;
- the VPS public key;
- the VPS public endpoint and UDP port;
- the VPS tunnel address in `allowedIPs`;
- the active AmneziaWG2 container address in `allowedIPs` so replies return
  through `wg-home` instead of the normal home default route;
- `persistentKeepalive = 25` because the home server is behind NAT.

Conceptually:

```nix
networking.wg-quick.interfaces.wg-home = {
  autostart = true;
  address = [ "<HOME_WG_IP>/30" ];
  privateKeyFile = "/etc/wireguard/wg-home.key";
  generatePrivateKeyFile = true;

  peers = [
    {
      publicKey = "<VPS_PUBLIC_KEY>";
      endpoint = "<VPS_PUBLIC_IP>:<WG_PORT>";
      allowedIPs = [
        "<VPS_WG_IP>/32"
        "<AWG2_DOCKER_IP>/32"
      ];
      persistentKeepalive = 25;
    }
  ];
};
```

Do not add a default route such as `0.0.0.0/0` to this peer.

Deploy from the repository root:

```bash
sudo nixos-rebuild switch --flake /etc/nixos#nixos
```

Verify:

```bash
sudo systemctl status wg-quick-wg-home --no-pager
sudo wg show wg-home
ip route get <AWG2_DOCKER_IP>
ip route show default
```

The route to `<AWG2_DOCKER_IP>` must use `wg-home`. The normal default route
must still use the ordinary NixOS uplink.

If the home uplink is Wi-Fi, ensure NetworkManager reconnects it after boot:

```bash
nmcli -f NAME,TYPE,AUTOCONNECT connection show
```

Enable autoconnect when necessary:

```bash
sudo nmcli connection modify "<Wi-Fi profile name>" connection.autoconnect yes
```

## 5. Allow AmneziaWG2 traffic to the home Caddy endpoint

The active AmneziaWG2 container already performs NAT when traffic leaves the
container toward the VPS host. Consequently the VPS normally sees remote VPN
clients as the container's Docker address rather than their individual VPN
addresses.

Allow only the browser-facing Caddy port through the VPS forwarding firewall:

```bash
sudo ufw route allow \
  in on <AMNEZIA_BRIDGE_IF> \
  out on wg-home \
  proto tcp \
  from <AWG2_DOCKER_IP> \
  to <HOME_WG_IP> \
  port 80
```

A second MASQUERADE on the VPS is not required when the NixOS peer routes
`<AWG2_DOCKER_IP>/32` back through `wg-home`.

Verify the rule:

```bash
sudo ufw status verbose
```

## 6. Provide remote DNS for the private `.home` zone

LAN DNS on NixOS resolves `.home` names to the LAN address. Remote VPN clients
should instead resolve those same names to `<HOME_WG_IP>`, so the VPS provides
a small split-DNS resolver for Amnezia clients.

Install dnsmasq on the VPS:

```bash
sudo apt install -y dnsmasq dnsutils
```

Before changing it, check listeners on port 53:

```bash
sudo ss -lntup | grep ':53 '
```

Create `/etc/dnsmasq.d/home-vpn.conf`:

```ini
listen-address=<AMNEZIA_BRIDGE_IP>
bind-dynamic

no-resolv
server=9.9.9.9
server=149.112.112.112

address=/.home/<HOME_WG_IP>
cache-size=1000
```

Restart and enable dnsmasq:

```bash
sudo systemctl restart dnsmasq
sudo systemctl enable dnsmasq
```

Allow DNS only from the active AWG2 container:

```bash
sudo ufw allow in on <AMNEZIA_BRIDGE_IF> \
  proto udp \
  from <AWG2_DOCKER_IP> \
  to <AMNEZIA_BRIDGE_IP> \
  port 53

sudo ufw allow in on <AMNEZIA_BRIDGE_IF> \
  proto tcp \
  from <AWG2_DOCKER_IP> \
  to <AMNEZIA_BRIDGE_IP> \
  port 53
```

Verify split DNS:

```bash
dig @<AMNEZIA_BRIDGE_IP> family.home +short
dig @<AMNEZIA_BRIDGE_IP> example.com +short
```

The `.home` name should resolve to `<HOME_WG_IP>` while public names should
resolve through the configured upstream DNS servers.

## 7. Configure Amnezia clients

Do not replace the device-wide Android/iOS/desktop DNS setting. Configure the
DNS server in the existing AmneziaWG 2.0 VPN profile instead:

```text
DNS = <AMNEZIA_BRIDGE_IP>
```

Reconnect the VPN after changing the profile.

With the VPN active:

```text
family.home      -> <HOME_WG_IP>
jellyfin.home    -> <HOME_WG_IP>
qbittorrent.home -> <HOME_WG_IP>
prowlarr.home    -> <HOME_WG_IP>
adguard.home     -> <HOME_WG_IP>
```

Caddy selects the correct service from the HTTP `Host` header.

## 8. End-to-end verification

First verify only the site-to-site tunnel.

From NixOS:

```bash
ping -c 3 <VPS_WG_IP>
sudo wg show wg-home
```

From the VPS:

```bash
ping -c 3 <HOME_WG_IP>
sudo wg show wg-home
```

A recent `latest handshake` must be visible on both sides.

Then verify Caddy directly from the VPS:

```bash
curl -I -H 'Host: family.home' http://<HOME_WG_IP>/
curl -I -H 'Host: jellyfin.home' http://<HOME_WG_IP>/
```

Finally connect a remote device to its existing AmneziaWG profile and open:

```text
http://family.home
http://jellyfin.home
```

## Troubleshooting

### No WireGuard handshake

Check:

```bash
sudo wg show wg-home
sudo systemctl status wg-quick@wg-home --no-pager   # VPS
sudo systemctl status wg-quick-wg-home --no-pager  # NixOS
```

Confirm that the VPS UDP port is open and that the NixOS endpoint points to the
VPS public address. The home router does not need a port forward because the
NixOS peer initiates the connection and uses persistent keepalive.

### Tunnel pings work but Caddy does not

On the VPS:

```bash
sudo ufw status verbose
ip route get <HOME_WG_IP>
```

On NixOS:

```bash
ss -lntp | grep ':80 '
systemctl status caddy --no-pager
ip route get <AWG2_DOCKER_IP>
```

The reply route to the AWG2 Docker address must use `wg-home`.

### `.home` does not resolve remotely

Check the VPS resolver:

```bash
sudo systemctl status dnsmasq --no-pager
sudo ss -lntup | grep ':53 '
dig @<AMNEZIA_BRIDGE_IP> family.home
```

Then confirm that the Amnezia client profile uses `<AMNEZIA_BRIDGE_IP>` as its
VPN DNS server.

### Internet works but only some remote devices can reach home services

Inspect which AmneziaWG2 container/profile the device is actually using. If
multiple legacy/AWG2 containers exist on the VPS, only traffic from the Docker
address allowed by the UFW rules will pass to `wg-home`.

## Security notes

- Keep both WireGuard private keys outside Git.
- Do not route the complete home LAN unless a concrete service requires it.
- Prefer exposing browser UIs through Caddy rather than opening their native
  ports over the tunnel.
- With AWG2 container-side MASQUERADE, the VPS host cannot distinguish remote
  peers by their original VPN address; all such clients may appear as the
  AWG2 container address. If per-device ACLs are required, redesign the NAT/ACL
  boundary so the original client addresses remain visible.
