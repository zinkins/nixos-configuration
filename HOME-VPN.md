# Home access through the VPS

`home-vpn.nix` defines a separate WireGuard client tunnel, `wg-home`, for
traffic exchanged with the VPS and its AWG2 container. `wg-quick` routes
the peer's `allowedIPs` through this tunnel. The normal default route and
the existing AmneziaWG traffic paths stay unchanged.

## First deployment

On first start, NixOS creates `/etc/wireguard/wg-home.key` if it does not
already exist; an existing key is preserved. The directory is root-only and
the generated key has mode `0600`. Keep the private key out of Git.

After deploying, get the NixOS public key on the host with:

```bash
sudo sh -c 'wg pubkey < /etc/wireguard/wg-home.key'
```

Add that public key to the VPS WireGuard peer configuration. The VPS must
route traffic to and from the AWG2 container before end-to-end access works.

## Verify on the NixOS host

Check that the Wi-Fi connection used for the uplink reconnects after boot:

```bash
nmcli -f NAME,TYPE,AUTOCONNECT connection show
```

For the Wi-Fi profile used by this host, `AUTOCONNECT` should be `yes`. If it
is `no`, enable it for that profile:

```bash
sudo nmcli connection modify "<Wi-Fi profile name>" connection.autoconnect yes
```

After deploying and starting the tunnel, verify the peer handshake and the
route for replies to the container:

```bash
sudo systemctl status wg-quick-wg-home --no-pager
sudo wg show wg-home
ip route get 172.29.172.2
ip route show default
```

The route to the container should use `wg-home`; the default route should
still use the normal uplink. This repository cannot verify the Wi-Fi profile,
VPS peer configuration, or a live handshake without access to the NixOS host.
