# Immich: private family photo library

Immich runs natively as a NixOS service (no Docker) at **http://photos.home**.
Caddy proxies it to `127.0.0.1:2283`; the application port is not exposed
directly to the LAN or Internet. Local DNS is provided by AdGuard/dnsmasq.
The same URL is linked from the Homepage dashboard at `http://family.home`.
A separate public domain `https://photos.zinkin.me` is exclusively for
published album links and terminates at Immich Public Proxy, not the full
Immich API. The public proxy uses the Immich Nixpkgs input to pick a version
compatible with Immich 3.x. The separate **https://immich.zinkin.me** endpoint
provides authenticated access to the full Immich API and UI for family phones
and stays disabled until explicitly enabled after local administrator setup.

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
4. Complete the remote-access setup below, then install the official Immich
   app for Android/iOS and sign in to `https://immich.zinkin.me` with each
   person's own ordinary account.
5. On each phone, enable **Backup** and select the camera/device albums to
   upload. Background sync is best-effort and depends on Android/iOS battery
   and scheduling policies. Test uploads before deleting anything from phones.

### Two phones, separate libraries and one curated family album

The intended setup is **two independent Immich accounts** (one per adult),
with **each phone backing up its Camera album into its owner's private library**.
Neither user needs a separate Mail.ru Cloud account. The host's encrypted
Mail.ru backup covers assets uploaded by **both users**, plus database records.

1. Create both accounts in **Administration → Users** and use individual
   credentials in the Android/iOS app. Do not share the administrator login.
2. On each phone enable **Backup**, select the desired on-device photo/video
   albums, and verify that automatic uploads reach the correct personal
   timeline. Mobile backup is best-effort in the background.
3. One adult creates an album such as **Family** and shares it with the other
   adult using the **Editor** permission. Both can then add **selected**
   photos from their separate personal libraries into the same shared album.
   **Viewer** grants read-only access and is insufficient for adding photos.
4. Only after reviewing the shared album create a **public share link**
   for relatives, with suitable password and expiration options. Publish
   the link via the public HTTPS proxy. Do **not** make all personal uploads
   available to relatives automatically.

**Partner Sharing is NOT needed** for this workflow: it can reveal an
entire personal timeline and location metadata, rather than just curated
family photos. Avoid enabling it unless both account owners explicitly
intend that broader access.

**The public proxy is viewing-only for relatives.** Use
`https://immich.zinkin.me` in the official app on each phone, at home and
on mobile data, after completing the remote-access setup below. No manual
VPN connection is required. In Backup settings allow uploads over cellular
data if desired (Wi-Fi-only is the default). Background execution remains
subject to Android/iOS restrictions and cellular data limits.

Immich also supports public album links, optional passwords and expiry
dates. Links to `photos.home` are reachable only inside the LAN/VPN;
public album links should use `https://photos.zinkin.me`.

## Sharing albums outside the home network

The public endpoint is **https://photos.zinkin.me**, served by Caddy with
automatic HTTPS and routed to the native, hardened `immich-public-proxy`
service on local port 3125. The proxy needs no Immich API key and serves only
shares explicitly published from Immich. Its optional visitor-upload service
is **not** enabled. The authenticated Immich UI stays at `http://photos.home`
and is not routed to the public hostname.

### Required external DNS and router setup (one time)

1. At the DNS provider for `zinkin.me`, add an **A** record:
   `photos.zinkin.me → <HOME_PUBLIC_IPV4>` and
   `immich.zinkin.me → <HOME_PUBLIC_IPV4>` (hosts `photos` and `immich`,
   TTL 300). Keep the existing A record for `zinkin.me` pointing to its VPS
   unchanged. Ensure there is no conflicting AAAA/CNAME
   for the new hostname.
2. On the **home router** forward **TCP 443 only** from the public WAN address
   to **TCP 443** of the NixOS server's reserved LAN IPv4 address. Verify the
   router WAN IPv4 actually matches your public home IPv4 and that the ISP permits
   inbound 443. Do **not** forward TCP 80: other Caddy hostnames under `.home`
   are plain-HTTP LAN services and could otherwise be reached using spoofed
   Host headers. Do not forward 2283 or 3125.
3. Caddy can use ACME **TLS-ALPN-01 on TCP 443** to obtain and renew a trusted
   certificate; external port 80 is not required for this challenge.
   Check its journal if certificate issuance fails.
4. In the authenticated Immich UI at `http://photos.home`, set
   **Administration → Settings → Server → External domain**
   to `https://photos.zinkin.me` (no trailing slash), so published album
   links point at IPP. Set the **phone app server URL** to
   `https://immich.zinkin.me` once enabled. `photos.zinkin.me` is deliberately
   not a login endpoint.
5. Create a shared album, enable link sharing with appropriate password and
   expiration, then test from a phone on cellular data (Wi-Fi off). Never
   expose a family-wide library link unless the recipients are trusted.

### Verify after DNS propagation and port forwarding

```bash
systemctl status immich-server immich-public-proxy caddy --no-pager
journalctl -u immich-public-proxy -u caddy -b -n 100 --no-pager
curl -fsS http://127.0.0.1:3125/share/healthcheck
dig +short A photos.zinkin.me
curl -fsS https://photos.zinkin.me/share/healthcheck
```

The public healthcheck should return `ok` once DNS, routing, TLS, IPP and
Immich all work. The localhost healthcheck should work before external setup.
Test a real album share and verify that visiting the public root does **not**
show the Immich login interface. A private or expired link must remain
unavailable.

If the public IP changes, update both DNS records (or add DDNS). AdGuard
and dnsmasq resolve both HTTPS hostnames to the LAN IPv4 for clients using
the home DNS; public DNS resolves them to the WAN IPv4. Clients using their
own DoH or Private DNS may instead need NAT loopback. Test from cellular
data first.

The existing WireGuard tunnel to the VPS is an alternative:
a separate HTTPS reverse proxy on the VPS could reach this host over the
tunnel without any home-router port forwarding. That design would require
changes on the VPS and is **not** part of this deployment.

## Authenticated mobile uploads outside the house

The remote host `https://immich.zinkin.me` proxies the complete Immich UI
and API, including streaming uploads and WebSockets, over trusted HTTPS.
It is **Internet-facing**, not VPN-only or IP-allowlisted. Each user
authenticates with their own Immich account. The separate
`https://photos.zinkin.me` still exposes only published links via IPP.
Never expose port 2283 directly.

### One-time safe activation

1. Create both public DNS A records and forward **only TCP 443** as above.
2. On the LAN, open `http://photos.home` and initialize the first admin
   yourself. Create two ordinary accounts with unique strong passwords.
   Keep the admin account separate and do not use it on the phones.
3. Verify the local instance is running and the HTTPS certificate is valid.
   Until enabled, `https://immich.zinkin.me/` returns HTTP 503.
   The initial-admin registration API is always blocked on the remote host.
4. Explicitly enable remote access from the host terminal:

   ```bash
   sudo install -m 0644 -o root -g root /dev/null /etc/immich-remote/enabled
   ```

   This root-owned marker survives rebuilds. No Caddy reload is required.
   Remove it to close the remote API for new requests (the LAN and public
   share proxy remain available):

   ```bash
   sudo rm -f /etc/immich-remote/enabled
   ```

5. On both phones use `https://immich.zinkin.me`, sign in with each user's
   account, select camera folders and enable cellular uploads in Backup
   settings. On Android allow background data and remove restrictive battery
   optimization; on iOS enable Background App Refresh.
6. Disable Wi-Fi and any VPN on a phone, take a test photo and video, and
   verify they reach the correct private library. Verify home Wi-Fi works
   with the same HTTPS address.

### Security and verification

Fail2ban is configured for failed password logins: ten HTTP 401 login
failures within ten minutes trigger a 30-minute IP ban on TCP 443.
The filter uses the direct TCP peer IP, not a forwarded header. It assumes
the current direct router port-forward topology, not a CDN or VPS proxy.
Carrier NAT can affect other people sharing a banned address.
No Basic Auth, custom headers or client certificate are imposed on the app,
since those mechanisms can interfere with mobile uploads/playback.

```bash
dig @127.0.0.1 +short immich.zinkin.me
dig @9.9.9.9 +short immich.zinkin.me
curl -I https://immich.zinkin.me/
curl -fsS https://immich.zinkin.me/api/server/ping
sudo fail2ban-client status immich-login
sudo fail2ban-regex /var/log/caddy/immich-login.log /etc/fail2ban/filter.d/immich-login.conf
```

The NixOS build adapts the Caddy configuration and tests the Fail2ban filter
against synthetic success/failure logs. Runtime validation is still required.
Run ping after enabling the marker. Verify the filter matches an unsuccessful
login from a test account; do not deliberately trigger a ban on a production
or shared connection. Fail2ban is supplementary protection, not a guarantee
against compromise. Keep Immich current, review security notices and verify
off-host backups. Admin API authorization still depends on Immich's own role
checks; use the LAN interface for administration. For maximum isolation use
a VPN instead of enabling remote access.

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
incremental snapshots. It backs up the originals, profile images and other
non-regenerable data in `/myraid1/nas/Photos` plus a fresh logical PostgreSQL
dump. Generated thumbnails and transcoded videos are excluded, while the
`.immich` integrity markers are preserved. After a restore, regenerate the
thumbnails and transcoded videos. It is **not active until** the private WebDAV
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
