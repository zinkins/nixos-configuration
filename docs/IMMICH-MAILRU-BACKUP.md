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

## Backup contents and regenerable media

Restic snapshots contain all managed original photos/videos (including both
`upload/` and `library/`), profile images, sidecars, and database backups,
including the fresh custom-format PostgreSQL dump. The machine-learning
model cache is outside the backup paths. The contents of `thumbs/` and
`encoded-video/` are excluded, **except** their `.immich` storage-integrity
markers; the parent directories and markers remain in the snapshot.
Existing historical database dumps in `backups/` are kept intentionally:
they are historical recovery points, not regenerable media.

After restoring, preserve the restored file ownership and `.immich` markers,
restore the matching database, then use Administration → Job Queues to run
thumbnail generation and video transcoding for **all** assets. Do not
bypass mount-integrity checks. See the official backup and system-integrity
references below. Regeneration takes CPU time and generated files may be
unavailable until jobs finish.

Restic deduplicates content within its own encrypted repository, not against
ordinary files elsewhere in the Mail.ru account. Imported cloud originals
therefore still participate in the self-contained Restic backup. Adding a
photo already in a user's managed library to a shared album does not create
another original file just because of the album membership. Never exclude
managed originals by album, filename, or supposed cloud presence: the database
references their exact paths, and the old cloud folder can change or disappear.

A separately managed **read-only external library** backed by a local copy of
an immutable cloud archive could avoid storing the same historical originals
in Restic. That would require a separate verified recovery procedure for the
external files at the same paths, including version/hash verification and
protection against cloud-side deletion. It is not enabled by this PR. Keep
all managed originals in Restic unless that alternative is explicitly chosen
and tested. The existing Mail.ru photo folders are not modified.

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

## 4. One-time import of the existing Mail.ru photo archive

**Long-term workflow chosen:** use **two personal Immich accounts**, one per
adult, with mobile auto-backup directly into each account via the authenticated
HTTPS address `https://immich.zinkin.me` once explicitly enabled. Both can add
selected items to a shared family album as **Editors**. One existing Mail.ru
account is used for **encrypted backup of the entire Immich server**,
including both users; there is no need for a second cloud account, and no
recurring cloud-to-Immich importer is desired.

The Mail.ru folders are now treated as **historical sources for optional
one-time import**, not the active source of new family photos. The exact
remote folder paths and target account identifiers are not committed to Git:
inspect them with `rclone lsd` after the WebDAV credentials have been
configured.

Recommended initial import:

1. After creating the intended personal accounts and shared family album,
   download a **copy** of the historically curated family cloud folder
   into a private staging directory **outside** the Immich-managed folder.
   Use the Immich CLI and a target user's API key to import the selected
   files, optionally assigning them to the shared album.
2. Consider a **separate** private-only import of any historical phone
   uploads not already on the phone. Import with the same user's API key;
   first test Immich's per-account deduplication and avoid reimporting the
   same file under a second account.
3. Verify photo counts, dates, videos and album membership before removing
   any temporary staging copies. **Do not delete or modify the existing
   Mail.ru cloud folders.** Leave the separate old NAS archive alone.

Use `rclone copy` for non-destructive download, never `rclone sync`,
`rclone move` or cloud deletion. Never copy raw images directly into
`/myraid1/nas/Photos`, which Immich owns and manages.

Continuing to move items between the old Mail.ru folders **does not update**
Immich shared albums. In the new workflow, curated photos are shared
**inside Immich**, directly from each owner's personal timeline, and
the server's daily encrypted Restic backup captures them offsite.

**No import has been performed in this PR.** Credentials, per-user API keys,
private folder contents and upload actions are handled later after Immich
and WebDAV are configured, using explicit user review.

Official references:
- https://help.mail.ru/cloud/desktop/webdav/
- https://rclone.org/webdav/
- https://restic.readthedocs.io/en/stable/030_preparing_a_new_repo.html
- https://docs.immich.app/administration/backup-and-restore/
- https://docs.immich.app/administration/system-integrity/
- https://restic.readthedocs.io/en/stable/040_backup.html#excluding-files
