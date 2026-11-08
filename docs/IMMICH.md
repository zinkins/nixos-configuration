# Immich: private family photo library

Immich runs natively as a NixOS service (no Docker) at **http://photos.home**.
Caddy proxies it to `127.0.0.1:2283`; the application port is not exposed
directly to the LAN or Internet. Local DNS is provided by AdGuard/dnsmasq.
The same URL is linked from the Homepage dashboard at `http://family.home`.

## Version management

The stable NixOS 26.05 package is Immich 2.7.5, flagged insecure because
upstream 2.x is unsupported and has known CVEs. **Do not bypass the insecure
package check.** This service uses Immich 3.3.6 from a separately pinned
`immich-nixpkgs` flake input (the initial lock revision is already known and
hash-verified). Unlike the Codex source, this input is not updated by the
daily Codex/Herdr workflow. Upgrade Immich deliberately, after reviewing
release notes, making a database/media backup and passing CI.

## Storage and dependencies

- Original photos, videos and generated media: `/myraid1/immich` (ZFS).
  This is **outside** the Samba share at `/myraid1/nas` and is owned by
  the `immich` system user with mode `0700`.
- PostgreSQL metadata and Redis state: managed by the official NixOS Immich
  module, under their normal host service locations (not the ZFS media path).
- The `immich-storage` one-shot unit verifies `/myraid1` is a mount point
  and creates the private media directory before `immich-server` starts.
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

## Access from outside the house

This change deliberately does **not** make Immich public. The existing `.home`
zone uses plain HTTP and is not a publicly resolvable domain. Credentials and
photos must not be transmitted over plain HTTP across the public Internet;
never port-forward TCP 2283 or expose this `.home` Caddy host publicly.

Options for a future follow-up:

- **Private full access:** use the existing home VPN for phones/relatives that
  need accounts or automatic uploads. Verify DNS and reachability through
  the VPN first. Prefer trusted HTTPS for client compatibility.
- **Public sharing without accounts:** set up a public HTTPS hostname with a
  trusted certificate pointing to **Immich Public Proxy**, which serves only
  albums explicitly shared by link, not the whole Immich API. It requires a
  domain/DDNS and working inbound HTTPS or a suitable tunnel.
- **Public account access and off-site phone backup:** requires a trusted HTTPS
  endpoint for the *actual Immich server* (not the restricted public-link
  proxy), with proper authentication, updates and secure Internet ingress.

These alternatives are not deployed automatically because neither a public
domain nor its TLS/inbound-access configuration is defined in this repository.

## Health checks

After deployment, run **diagnostics only** on the server:

```bash
systemctl status immich-storage immich-server immich-machine-learning caddy dnsmasq --no-pager
journalctl -u immich-storage -u immich-server -u immich-machine-learning -b -n 100 --no-pager
mountpoint /myraid1
ls -ld /myraid1/immich
curl -I -H 'Host: photos.home' http://127.0.0.1/
dig @127.0.0.1 photos.home
```

The application and its database are not populated until the initial setup is
completed in the browser. Service health and mobile uploads should be tested
separately after merging; CI validates the NixOS build, not the live server.

## Backups and recovery

**Immich is not itself a backup.** Keep independent, regularly tested backups
of both (1) `/myraid1/immich` including original assets and (2) the Immich
PostgreSQL database/metadata. A ZFS mirror or snapshots on the same pool do
not protect against every hardware, administrative or ransomware failure.
Make at least one copy to another device/location before relying on Immich as
the only place where family photos exist.

Official documentation:

- https://docs.immich.app/features/sharing/
- https://docs.immich.app/features/mobile-backup/
- https://docs.immich.app/administration/reverse-proxy/
- https://docs.immich.app/guides/remote-access/
- https://wiki.nixos.org/wiki/Immich
