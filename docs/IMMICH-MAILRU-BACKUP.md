# Mail.ru Cloud: encrypted Immich backup and cloud photo imports

The NixOS module `nix/immich-mailru-backup.nix` configures a daily encrypted
Restic backup over rclone WebDAV to the **dedicated**
`ImmichBackups/restic` directory in Mail.ru Cloud.

This is a **snapshot backup, not two-way synchronization**. Deleting or
modifying photos inside Immich does not automatically delete their previous
Restic backup versions; the backup retention policy keeps 14 daily, 8 weekly
and 12 monthly snapshots. Only Restic data **inside ImmichBackups/restic**
is pruned. Existing personal and shared Mail.ru photo folders remain intact.

The backup is **off by default** on an unconfigured machine: the systemd
service has file-existence conditions and skips until both private secret
files exist. A successful NixOS build does not verify cloud authentication,
capacity, backups, or restorability.

## 1. Create a Mail.ru external-application password

In the Mail account security settings, create a separate **application
password** for WebDAV. Do not use the normal email password. Prefer only the
permissions needed for Cloud/WebDAV access. This is the official WebDAV URL:

```text
https://webdav.cloud.mail.ru
```

Official provider documentation: https://help.mail.ru/cloud/desktop/webdav/

Set up the private rclone configuration **on the NixOS host after deployment**:

```bash
sudo install -d -m 0700 /etc/immich-mailru
sudo rclone config --config /etc/immich-mailru/rclone.conf
```

In the interactive wizard select:
- Remote name: **mailru** (must match the backup repository definition).
- Storage: **WebDAV**, URL: `https://webdav.cloud.mail.ru`
- Vendor: **Other**.
- Username: your Mail.ru login/email.
- Password: the **external application password**.

The rclone wizard stores an obfuscated password, not an independently
encrypted secret; protect the entire file. Also configure the URL
`https://webdav.cloud.mail.ru` rather than the normal web UI URL.

```bash
sudo chmod 0600 /etc/immich-mailru/rclone.conf
sudo rclone --config /etc/immich-mailru/rclone.conf lsd mailru:
```

First confirm that the expected cloud folders are visible. Do not use
`rclone sync`, `delete`, `purge` or `move` on the original cloud folders.

## 2. Create and save a separate Restic encryption password

```bash
sudo sh -c 'umask 077; head -c 48 /dev/urandom | base64 > /etc/immich-mailru/restic-password'
sudo chmod 0600 /etc/immich-mailru/restic-password
```

Store this encryption password **outside the NixOS host**, in an offline or
separately backed-up password manager. **Losing it means losing access to
every encrypted backup**, even if the cloud files remain intact. Neither
this password nor the Mail.ru application password belongs in Git or chat.

## 3. Test the first backup before relying on the timer

The automatic timer runs daily at approximately 03:30-04:00
**Asia/Novosibirsk** (system's local time), persistent after downtime.
It requires mounted ZFS media and a running PostgreSQL service, and creates
a consistent logical `pg_dump` of the Immich database before uploading files.

```bash
sudo systemctl start restic-backups-immich-mailru.service
sudo systemctl status restic-backups-immich-mailru.service --no-pager
sudo journalctl -u restic-backups-immich-mailru.service -n 100 --no-pager
sudo restic-immich-mailru snapshots
```

A backup that completes without errors is not sufficient: regularly
**restore-test** a snapshot to a separate staging directory and verify the
media files and `immich.pgcustom` database dump:

```bash
sudo mkdir -p /var/tmp/immich-restore-test
sudo restic-immich-mailru restore latest --target /var/tmp/immich-restore-test
sudo find /var/tmp/immich-restore-test -name immich.pgcustom -print
```

Do **not** restore on top of a live Immich installation. Review the files,
test PostgreSQL restoration to a disposable database/server, and remove the
temporary restore directory when testing is complete. Full snapshots can
be large; restore only selected paths for quick routine checks.

The DB dump is produced **first**, then the media directory is copied. Since
uploads can continue during backup, the two copies may not be perfectly
atomic. Immich's recommended order is DB first, files second; take an
offline or snapshot-consistent backup for a strict recovery point.

The remote encrypted repository is **not** intended as a browsable photo
gallery. Your existing Mail.ru folders remain browsable; Restic snapshots
are for disaster recovery.

## 4. Import the two existing cloud folders without changing them

**Not automated yet**: the personal-archive and shared-family folder paths,
plus the destination Immich user accounts, have not been specified.

Once known, read-only `rclone copy` can download the two source folders
into separate staging directories on the NAS. Then:

1. Use Immich CLI with the target **personal account's** API key to import
   the private phone archive.
2. Use a **separate** import into the designated family account/library, and
   create an Immich album shared with the appropriate family members. Publish
   **only that album** through Immich Public Proxy.
3. Keep the original Mail.ru folders unchanged and confirm photo counts,
   metadata, and album access before deleting any temporary local copies.
4. Do not put manually imported files directly into
   `/myraid1/nas/Photos`: it is Immich's managed storage, not an ingestion
   directory.
5. Leave any other NAS archive out of Immich until explicitly approved.

For long-term cloud-to-Immich synchronization, a separate import job or an
Immich External Library would be needed. This is **not** currently enabled;
the one-time import must not become a destructive, two-way sync.

Official references:
- https://help.mail.ru/cloud/desktop/webdav/
- https://rclone.org/webdav/
- https://restic.readthedocs.io/en/stable/030_preparing_a_new_repo.html
- https://docs.immich.app/administration/backup-and-restore/
