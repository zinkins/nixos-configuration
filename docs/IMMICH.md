# Immich: private family photo library

Immich runs natively as a NixOS service (no Docker) at **http://photos.home**.
Caddy proxies it to `127.0.0.1:2283`; the application port is not exposed
directly to the LAN or Internet. Local DNS is provided by AdGuard/dnsmasq.
The same URL is linked from the Homepage dashboard at `http://family.home`.
A separate public domain `https://photos.zinkin.me` is exclusively for
published album links and terminates at Immich Public Proxy, not the full
Immich API. The public proxy uses the Immich Nixpkgs input to pick a version
compatible with Immich 3.x.

## Version management

The stable NixOS 26.05 package is Immich 2.7.5, flagged insecure because
upstream 2.x is unsupported and has known CVEs. **Do not bypass the insecure
package check.** This service initially uses Immich 3.3.6 from a separately pinned
`immich-nixpkgs` flake input (the initial lock revision is already known and
hash-verified). A separate weekly GitHub workflow checks Immich releases
without touching the host, Codex or Herdr pins. Changes are submitted as
validated PRs; automatic patch merging is disabled by default. Read
`docs/AUTO-UPDATE.md` before enabling it, and always maintain recoverable
database/media backups before upgrading.

## Storage and dependencies

- Original photos, videos and generated media: `/myraid1/nas/Photos` (ZFS).
  This location is **inside** the Samba export at `/myraid1/nas`, but is
  private to the `immich` system user (mode `0700`). Samba users are not
  granted direct filesystem access; use Immich to upload or share photos.
- PostgreSQL metadata and Redis state: managed by the official NixOS Immich
  module, under their normal host service locations (not the ZFS media path).
- The `immich-storage` one-shot unit verifies `/myraid1` is mounted and
  `/myraid1/nas` exists, then prepares the private folder. An empty
  pre-existing `Photos` directory can be adopted; a populated one belonging
  to another user blocks startup **without ownership changes**. Existing
  photos need a planned import through Immich, not silent adoption.
  If the ZFS pool is unavailable, Immich **must fail rather than write media
  to the root filesystem**.
- Face recognition and semantic search are enabled by the NixOS module's
  default machine-learning service. Initial indexing can use significant
  CPU and memory; monitor its impact on the other host services.

Do not manually rearrange or rename files inside Immich's managed directory.
Use Immich's web interface, mobile apps or supported import tools.

## First login and family accounts

1. Once this PR is merged and the normal automatic deployment has completed,
   browse to `http://photos.home` from a client using the home DNS.
2. Complete the initial setup and create the **first administrator** account.
   Do not share the administrator password with family members.
3. In the web UI, use **Administration → Users** to create a separate ordinary
   account for every family member who will upload photos.
4. Install the official Immich app for Android/iOS and sign in to
   `http://photos.home` with each person's own account.
5. On each phone, enable **Backup** and select the camera/device albums to
   upload. Background sync is best-effort and depends on Android/iOS battery
   and scheduling policies. Test uploads before deleting anything from phones.

To maintain one shared family collection without revealing all personal
photos, create an album such as **Family** and share it with the family users
as **Editors** so everyone can add photos. Use **Viewers** for read-only access.
Personal libraries remain separate by default. For two trusted adults who
want to see each other's complete libraries, optionally enable **Partner
Sharing** (access is one-way until both partners enable it).

Immich also supports public album links, optional passwords, expiry dates,
and guest uploads. However, a link containing `photos.home` works **only for
clients that can reach the private home network**.

## Sharing albums outside the home network

The public endpoint is **https://photos.zinkin.me**, served by Caddy with
automatic HTTPS and routed to the native, hardened `immich-public-proxy`
service on local port 3000. The proxy needs no Immich API key and serves only
shares explicitly published from Immich. Its optional visitor-upload service
is **not** enabled. The authenticated Immich UI stays at `http://photos.home`
and is not routed to the public hostname.

### Required external DNS and router setup (one time)

1. At the DNS provider for `zinkin.me`, add an **A** record:
   `photos.zinkin.me → <HOME_PUBLIC_IPV4>` (e.g., host `photos`, TTL 300).
   Keep the existing A record for `zinkin.me` pointing to its VPS
   unchanged. Ensure there is no conflicting AAAA/CNAME
   for the new hostname.
2. On the **home router** forward **TCP 443 only** from the public WAN address
   to **TCP 443** of the NixOS server's reserved LAN IPv4 address. Verify the
   router WAN IPv4 actually matches your public home IPv4 and that the ISP permits
   inbound 443. Do **not** forward TCP 80: other Caddy hostnames under `.home`
   are plain-HTTP LAN services and could otherwise be reached using spoofed
   Host headers. Do not forward 2283 or 3000.
3. Caddy can use ACME **TLS-ALPN-01 on TCP 443** to obtain and renew a trusted
   certificate; external port 80 is not required for this challenge.
   Check its journal if certificate issuance fails.
4. In the authenticated Immich UI at `http://photos.home`, set
   **Administration → Settings → Server → External domain**
   to `https://photos.zinkin.me` (no trailing slash), so published album
   links point at IPP. Keep the **phone app server URL** as `http://photos.home`
   on the LAN/VPN; `photos.zinkin.me` is deliberately **not** a login endpoint.
5. Create a shared album, enable link sharing with appropriate password and
   expiration, then test from a phone on cellular data (Wi-Fi off). Never
   expose a family-wide library link unless the recipients are trusted.

### Verify after DNS propagation and port forwarding

```bash
systemctl status immich-server immich-public-proxy caddy --no-pager
journalctl -u immich-public-proxy -u caddy -b -n 100 --no-pager
curl -fsS http://127.0.0.1:3000/share/healthcheck
dig +short A photos.zinkin.me
curl -fsS https://photos.zinkin.me/share/healthcheck
```

The public healthcheck should return `ok` once DNS, routing, TLS, IPP and
Immich all work. The localhost healthcheck should work before external setup.
Test a real album share and verify that visiting the public root does **not**
show the Immich login interface. A private or expired link must remain
unavailable.

If the public IP changes, update the DNS record (or add DDNS). LAN access to
the public domain may require router NAT loopback or split DNS; test from
cellular data first.

The existing WireGuard tunnel to the VPS is an alternative:
a separate HTTPS reverse proxy on the VPS could reach this host over the
tunnel without any home-router port forwarding. That design would require
changes on the VPS and is **not** part of this deployment.

## Access from outside the house

The authenticated Immich interface remains private at `http://photos.home`.
Public sharing via `https://photos.zinkin.me` is limited to link-based
viewing by Immich Public Proxy, as described above; the home-router DNS and
NAT changes still must be made separately. Never forward TCP 2283 or expose
the `.home` site to the public Internet.

For full remote login, phone uploads, or administration, continue using a
private VPN. A public full-API endpoint would require a separate security
review, trusted HTTPS and additional hardening.

## Health checks

After deployment, run **diagnostics only** on the server:

```bash
systemctl status immich-storage immich-server immich-machine-learning immich-public-proxy caddy dnsmasq --no-pager
journalctl -u immich-storage -u immich-server -u immich-machine-learning -u immich-public-proxy -b -n 100 --no-pager
mountpoint /myraid1
ls -ld /myraid1/nas/Photos
curl -I -H 'Host: photos.home' http://127.0.0.1/
dig @127.0.0.1 photos.home
```

The application and its database are not populated until the initial setup is
completed in the browser. Service health and mobile uploads should be tested
separately after merging; CI validates the NixOS build, not the live server.

## Backups and recovery

**Immich is not itself a backup.** The optional Mail.ru Cloud Restic backup
service in `nix/immich-mailru-backup.nix` is set to run daily with encrypted,
incremental snapshots. It backs up both `/myraid1/nas/Photos` and a fresh
logical PostgreSQL dump. It is **not active until** the private WebDAV
credentials and Restic encryption password are configured on the host.

Setup, restore-test and cloud-folder import instructions are in
[`IMMICH-MAILRU-BACKUP.md`](IMMICH-MAILRU-BACKUP.md). The source folders already
in Mail.ru are never included as Restic destinations or modified by backup.
They may be downloaded for a **one-time** Immich import once their exact
cloud paths and target user accounts are known.

Keep an off-host encrypted copy and periodically test restoring both database
and photos. A ZFS mirror or snapshots on the same pool do not protect against
every hardware, administrative or ransomware failure.

Official documentation:

- https://docs.immich.app/features/sharing/
- https://docs.immich.app/features/mobile-backup/
- https://docs.immich.app/administration/reverse-proxy/
- https://docs.immich.app/guides/remote-access/
- https://wiki.nixos.org/wiki/Immich
